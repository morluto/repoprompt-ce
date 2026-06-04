import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class StoreBackedWorkspaceSearchContentFetchAdmissionCoordinatorTests: XCTestCase {
        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            super.tearDown()
        }

        func testProductionPolicyUsesFairShareBurstGlobalGuardAndBoundedQueues() {
            let configuration = StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.Configuration.production
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            XCTAssertEqual(configuration.fairSharePerStore, 2)
            XCTAssertEqual(configuration.maxBurstPerStore, 4)
            XCTAssertEqual(configuration.globalCapacity, max(12, min(32, processorCount * 2)))
            XCTAssertEqual(configuration.maxQueuedPerStore, max(32, min(128, processorCount * 4)))
            XCTAssertEqual(configuration.maxQueuedGlobally, max(128, min(512, processorCount * 16)))
            XCTAssertEqual(configuration.maxQueueWait, .seconds(8))
            XCTAssertEqual(configuration.retryAfterMilliseconds, 1000)
        }

        func testSameStoreQueuedFetchesRotateAcrossSearchIDs() async throws {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 1,
                globalCapacity: 1,
                maxQueuedPerStore: 8,
                maxQueuedGlobally: 8,
                maxQueueWait: .seconds(8)
            ))
            let store = WorkspaceFileContextStore()
            let searchA = UUID()
            let searchB = UUID()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let firstA = permitTask(coordinator: coordinator, store: store, searchID: searchA, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let secondA = permitTask(coordinator: coordinator, store: store, searchID: searchA, value: 2)
            let thirdA = permitTask(coordinator: coordinator, store: store, searchID: searchA, value: 3)
            let firstB = permitTask(coordinator: coordinator, store: store, searchID: searchB, value: 4)
            let secondB = permitTask(coordinator: coordinator, store: store, searchID: searchB, value: 5)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 4 })

            for expectedCount in 2 ... 5 {
                await gate.releaseFirst()
                await assertTrue(gate.waitUntilStartedCount(expectedCount))
            }
            await gate.releaseAll()

            try await assertEqual(firstA.value, 1)
            try await assertEqual(secondA.value, 2)
            try await assertEqual(thirdA.value, 3)
            try await assertEqual(firstB.value, 4)
            try await assertEqual(secondB.value, 5)
            await assertEqual(gate.startedSearchIDs(), [searchA, searchA, searchB, searchA, searchB])
            await assertEqual(coordinator.snapshot(), .init(activePermitCount: 0, waiterCount: 0, laneCount: 0))
        }

        func testIdleStoreBorrowsGlobalCapacityUpToBurstCap() async throws {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 3,
                globalCapacity: 3,
                maxQueuedPerStore: 4,
                maxQueuedGlobally: 4,
                maxQueueWait: .seconds(8)
            ))
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)
            let searchID = UUID()

            let first = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 1)
            let second = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 2)
            let third = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 3)
            await assertTrue(gate.waitUntilStartedCount(3))
            let queued = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 4)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            await assertEqual(coordinator.snapshot(for: store).activePermitCount, 3)

            await gate.releaseAll()
            try await assertEqual(first.value, 1)
            try await assertEqual(second.value, 2)
            try await assertEqual(third.value, 3)
            try await assertEqual(queued.value, 4)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testWaitingSecondStoreGetsFairShareBeforeHotStoreBorrowsAgain() async throws {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 3,
                globalCapacity: 3,
                maxQueuedPerStore: 4,
                maxQueuedGlobally: 4,
                maxQueueWait: .seconds(8)
            ))
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)
            let searchA = UUID()
            let searchB = UUID()

            let firstA = permitTask(coordinator: coordinator, store: storeA, searchID: searchA, value: 1)
            let secondA = permitTask(coordinator: coordinator, store: storeA, searchID: searchA, value: 2)
            let thirdA = permitTask(coordinator: coordinator, store: storeA, searchID: searchA, value: 3)
            await assertTrue(gate.waitUntilStartedCount(3))
            let queuedA = permitTask(coordinator: coordinator, store: storeA, searchID: searchA, value: 4)
            let firstB = permitTask(coordinator: coordinator, store: storeB, searchID: searchB, value: 5)
            await assertTrue(waitForGlobalSnapshot(coordinator: coordinator) { $0.waiterCount == 2 })

            await gate.releaseFirst()
            await assertTrue(gate.waitUntilStartedCount(4))
            await assertEqual(gate.startedStores().prefix(4).map(\.self), [
                ObjectIdentifier(storeA),
                ObjectIdentifier(storeA),
                ObjectIdentifier(storeA),
                ObjectIdentifier(storeB)
            ])

            await gate.releaseAll()
            try await assertEqual(firstA.value, 1)
            try await assertEqual(secondA.value, 2)
            try await assertEqual(thirdA.value, 3)
            try await assertEqual(queuedA.value, 4)
            try await assertEqual(firstB.value, 5)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testPerStoreQueueBoundRejectsPromptlyRetryablyAndCleansUp() async throws {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 1,
                globalCapacity: 1,
                maxQueuedPerStore: 1,
                maxQueuedGlobally: 4,
                maxQueueWait: .seconds(8)
            ))
            let store = WorkspaceFileContextStore()
            let searchID = UUID()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            let rejected = permitTask(coordinator: coordinator, store: store, searchID: searchID, value: 3)
            await assertQueueFull(rejected, scope: .perStore)

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            try await assertEqual(queued.value, 2)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testGlobalQueueBoundRejectsPromptlyRetryablyAndCleansUp() async throws {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 1,
                globalCapacity: 1,
                maxQueuedPerStore: 2,
                maxQueuedGlobally: 1,
                maxQueueWait: .seconds(8)
            ))
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            let storeC = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: storeA, searchID: UUID(), value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(coordinator: coordinator, store: storeB, searchID: UUID(), value: 2)
            await assertTrue(waitForGlobalSnapshot(coordinator: coordinator) { $0.waiterCount == 1 })
            let rejected = permitTask(coordinator: coordinator, store: storeC, searchID: UUID(), value: 3)
            await assertQueueFull(rejected, scope: .global)

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            try await assertEqual(queued.value, 2)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testQueuedWaiterExpiresAtInjectedDeadline() async throws {
            let manualClock = ManualAdmissionClock()
            let coordinator = makeCoordinator(
                configuration: .init(
                    fairSharePerStore: 1,
                    maxBurstPerStore: 1,
                    globalCapacity: 1,
                    maxQueuedPerStore: 1,
                    maxQueuedGlobally: 1,
                    maxQueueWait: .seconds(8)
                ),
                clock: manualClock.makeClock()
            )
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, searchID: UUID(), value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let expired = permitTask(coordinator: coordinator, store: store, searchID: UUID(), value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            manualClock.advance(by: .seconds(7))
            await assertEqual(coordinator.snapshot(for: store).waiterCount, 1)
            manualClock.advance(by: .seconds(1))
            await assertWaitExpired(expired)
            await assertEqual(coordinator.snapshot(for: store).waiterCount, 0)

            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            await assertEqual(coordinator.snapshot().laneCount, 0)
        }

        func testQueuedCancellationAndCancellationAfterAcquisitionReleaseCapacity() async {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 1,
                globalCapacity: 1,
                maxQueuedPerStore: 2,
                maxQueuedGlobally: 2,
                maxQueueWait: .seconds(8)
            ))
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = permitTask(coordinator: coordinator, store: store, searchID: UUID(), value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(coordinator: coordinator, store: store, searchID: UUID(), value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            queued.cancel()
            await assertCancellation(queued)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 0 })

            held.cancel()
            await gate.releaseFirst()
            await assertCancellation(held)
            await assertEqual(coordinator.snapshot(), .init(activePermitCount: 0, waiterCount: 0, laneCount: 0))
        }

        func testTelemetryAndAggregateSnapshotRemainPrivacySafeAndIdleOnlyConfigurationWorks() async throws {
            _ = startedCapture(label: "content-fetch-admission", maxSamples: 200)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 1,
                maxBurstPerStore: 1,
                globalCapacity: 1,
                maxQueuedPerStore: 1,
                maxQueuedGlobally: 1,
                maxQueueWait: .seconds(8)
            ))
            let store = WorkspaceFileContextStore()
            let gate = PermitGate()
            await installGate(gate, on: coordinator)

            let held = correlatedPermitTask(coordinator: coordinator, store: store, searchID: UUID(), correlation: correlation, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = correlatedPermitTask(coordinator: coordinator, store: store, searchID: UUID(), correlation: correlation, value: 2)
            await assertTrue(waitForSnapshot(store: store, coordinator: coordinator) { $0.waiterCount == 1 })
            let overloaded = correlatedPermitTask(coordinator: coordinator, store: store, searchID: UUID(), correlation: correlation, value: 3)
            await assertQueueFull(overloaded, scope: .perStore)

            let pressured = await coordinator.snapshotForDebug()
            XCTAssertEqual(pressured.laneLoads, [.init(activeCount: 1, queuedCount: 1, queuedSearchCount: 1)])
            switch await coordinator.configureForDebug(.production) {
            case .applied:
                XCTFail("Busy coordinator must reject reconfiguration")
            case let .busy(snapshot):
                XCTAssertEqual(snapshot.configuration.fairSharePerStore, 1)
            }

            queued.cancel()
            await assertCancellation(queued)
            await gate.releaseAll()
            try await assertEqual(held.value, 1)
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let eventNames = Set(capture.lifecycleEvents.map(\.eventName))
            XCTAssertTrue(eventNames.contains("Search.ContentFetchPermitAcquired"))
            XCTAssertTrue(eventNames.contains("Search.ContentFetchWaitBegan"))
            XCTAssertTrue(eventNames.contains("Search.ContentFetchOverloaded"))
            XCTAssertTrue(eventNames.contains("Search.ContentFetchPermitCancelled"))
            XCTAssertTrue(eventNames.contains("Search.ContentFetchPermitReleased"))
            XCTAssertTrue(capture.lifecycleEvents.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("workspace") &&
                    !$0.sanitizedDimensions.contains("ObjectIdentifier")
            })

            switch await coordinator.configureForDebug(.production) {
            case let .applied(snapshot):
                XCTAssertTrue(snapshot.isIdle)
                XCTAssertEqual(snapshot.laneLoads, [])
            case .busy:
                XCTFail("Idle coordinator should accept reconfiguration")
            }
        }

        func testHundredsOfCallersRemainBoundedAndCleanupRetainsOnlyAggregateCounters() async throws {
            let coordinator = makeCoordinator(configuration: .init(
                fairSharePerStore: 2,
                maxBurstPerStore: 2,
                globalCapacity: 2,
                maxQueuedPerStore: 4,
                maxQueuedGlobally: 4,
                maxQueueWait: .seconds(8)
            ))
            let store = WorkspaceFileContextStore()
            let searchIDs = [UUID(), UUID()]
            let gate = PermitGate()
            await installGate(gate, on: coordinator)
            let callerCount = 300
            let tasks = (0 ..< callerCount).map { value in
                permitTask(coordinator: coordinator, store: store, searchID: searchIDs[value % searchIDs.count], value: value)
            }

            await assertTrue(gate.waitUntilStartedCount(2))
            await assertTrue(waitForGlobalSnapshot(coordinator: coordinator) { $0.activePermitCount == 2 && $0.waiterCount == 4 })
            await assertTrue(waitForDebugSnapshot(coordinator: coordinator) { $0.overloadCount == callerCount - 6 })
            let pressured = await coordinator.snapshotForDebug()
            XCTAssertEqual(pressured.globalActiveCount, 2)
            XCTAssertEqual(pressured.globalQueuedCount, 4)
            XCTAssertEqual(pressured.laneCount, 1)
            XCTAssertEqual(pressured.laneLoads, [.init(activeCount: 2, queuedCount: 4, queuedSearchCount: 2)])
            XCTAssertEqual(pressured.overloadCount, callerCount - 6)

            await gate.releaseAll()
            var admittedCount = 0
            var overloadedCount = 0
            for task in tasks {
                do {
                    _ = try await task.value
                    admittedCount += 1
                } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                    guard case let .contentFetchQueueFull(scope, retryAfterMilliseconds) = error else {
                        XCTFail("Expected retryable content-fetch overload, got \(error)")
                        continue
                    }
                    XCTAssertTrue(scope == .perStore || scope == .global)
                    XCTAssertEqual(retryAfterMilliseconds, 1000)
                    overloadedCount += 1
                }
            }
            XCTAssertEqual(admittedCount, 6)
            XCTAssertEqual(overloadedCount, callerCount - 6)
            let cleaned = await coordinator.snapshotForDebug()
            XCTAssertTrue(cleaned.isIdle)
            XCTAssertEqual(cleaned.globalActiveCount, 0)
            XCTAssertEqual(cleaned.globalQueuedCount, 0)
            XCTAssertEqual(cleaned.laneCount, 0)
            XCTAssertEqual(cleaned.laneLoads, [])
            XCTAssertEqual(cleaned.overloadCount, callerCount - 6)
        }

        private func makeCoordinator(
            configuration: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.Configuration = .production,
            clock: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.AdmissionClock = .continuous()
        ) -> StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator {
            StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator(configuration: configuration, clock: clock)
        }

        private func installGate(
            _ gate: PermitGate,
            on coordinator: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator
        ) async {
            await coordinator.setPermitAcquiredHandlerForTesting { store, searchID in
                await gate.hold(store: store, searchID: searchID)
            }
        }

        private func permitTask(
            coordinator: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator,
            store: WorkspaceFileContextStore,
            searchID: UUID,
            value: Int
        ) -> Task<Int, Error> {
            Task {
                try await coordinator.withContentFetchPermit(for: store, searchID: searchID) { value }
            }
        }

        private func correlatedPermitTask(
            coordinator: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator,
            store: WorkspaceFileContextStore,
            searchID: UUID,
            correlation: EditFlowPerf.LifecycleCorrelation,
            value: Int
        ) -> Task<Int, Error> {
            Task {
                try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                    try await coordinator.withContentFetchPermit(for: store, searchID: searchID) { value }
                }
            }
        }

        private func assertQueueFull(
            _ task: Task<Int, Error>,
            scope: StoreBackedWorkspaceSearchAdmissionError.QueueScope,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected bounded content-fetch queue rejection", file: file, line: line)
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .contentFetchQueueFull(scope: scope, retryAfterMilliseconds: 1000), file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        private func assertWaitExpired(
            _ task: Task<Int, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected bounded content-fetch wait expiry", file: file, line: line)
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .contentFetchWaitExpired(retryAfterMilliseconds: 1000), file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        private func assertCancellation(
            _ task: Task<Int, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected cancellation", file: file, line: line)
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        private func assertTrue(
            _ value: Bool,
            _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(value, message(), file: file, line: line)
        }

        private func assertEqual<T: Equatable>(
            _ actual: T,
            _ expected: T,
            _ message: @autoclosure () -> String = "",
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(actual, expected, message(), file: file, line: line)
        }

        private func waitForSnapshot(
            store: WorkspaceFileContextStore,
            coordinator: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator,
            predicate: (StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.Snapshot) -> Bool
        ) async -> Bool {
            for _ in 0 ..< 10000 {
                if await predicate(coordinator.snapshot(for: store)) { return true }
                await Task.yield()
            }
            return await predicate(coordinator.snapshot(for: store))
        }

        private func waitForGlobalSnapshot(
            coordinator: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator,
            predicate: (StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.GlobalSnapshot) -> Bool
        ) async -> Bool {
            for _ in 0 ..< 10000 {
                if await predicate(coordinator.snapshot()) { return true }
                await Task.yield()
            }
            return await predicate(coordinator.snapshot())
        }

        private func waitForDebugSnapshot(
            coordinator: StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator,
            predicate: (StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.DebugSnapshot) -> Bool
        ) async -> Bool {
            for _ in 0 ..< 10000 {
                if await predicate(coordinator.snapshotForDebug()) { return true }
                await Task.yield()
            }
            return await predicate(coordinator.snapshotForDebug())
        }

        private func startedCapture(label: String, maxSamples: Int) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Capture should start")
                fatalError("Capture should start")
            }
        }

        private actor PermitGate {
            private var started: [(store: ObjectIdentifier, searchID: UUID)] = []
            private var waiters: [CheckedContinuation<Void, Never>] = []
            private var isOpen = false

            func hold(store: WorkspaceFileContextStore, searchID: UUID) async {
                started.append((ObjectIdentifier(store), searchID))
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            func waitUntilStartedCount(_ expectedCount: Int) async -> Bool {
                for _ in 0 ..< 10000 {
                    if started.count >= expectedCount { return true }
                    await Task.yield()
                }
                return started.count >= expectedCount
            }

            func startedStores() -> [ObjectIdentifier] {
                started.map(\.store)
            }

            func startedSearchIDs() -> [UUID] {
                started.map(\.searchID)
            }

            func releaseFirst() {
                guard !waiters.isEmpty else { return }
                waiters.removeFirst().resume()
            }

            func releaseAll() {
                isOpen = true
                let activeWaiters = waiters
                waiters.removeAll()
                activeWaiters.forEach { $0.resume() }
            }
        }

        private final class ManualAdmissionClock: @unchecked Sendable {
            private enum SleepRegistration {
                case suspend
                case resume
                case cancel
            }

            private struct Sleeper {
                let deadline: Duration
                let continuation: CheckedContinuation<Void, Error>
            }

            private let lock = NSLock()
            private var current: Duration = .zero
            private var sleepers: [UUID: Sleeper] = [:]

            func makeClock() -> StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.AdmissionClock {
                StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.AdmissionClock(
                    now: { self.now() },
                    sleepUntil: { deadline in try await self.sleep(until: deadline) }
                )
            }

            func now() -> Duration {
                lock.withLock { current }
            }

            func advance(by duration: Duration) {
                let ready: [Sleeper] = lock.withLock {
                    current += duration
                    let readyIDs = sleepers.compactMap { id, sleeper in
                        sleeper.deadline <= current ? id : nil
                    }
                    return readyIDs.compactMap { sleepers.removeValue(forKey: $0) }
                }
                ready.forEach { $0.continuation.resume() }
            }

            func sleep(until deadline: Duration) async throws {
                try Task.checkCancellation()
                let id = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let registration: SleepRegistration = lock.withLock {
                            if Task.isCancelled { return .cancel }
                            if deadline <= current { return .resume }
                            sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                            return .suspend
                        }
                        switch registration {
                        case .suspend:
                            break
                        case .resume:
                            continuation.resume()
                        case .cancel:
                            continuation.resume(throwing: CancellationError())
                        }
                    }
                } onCancel: {
                    self.cancelSleep(id: id)
                }
            }

            private func cancelSleep(id: UUID) {
                let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
                sleeper?.continuation.resume(throwing: CancellationError())
            }
        }
    }
#endif
