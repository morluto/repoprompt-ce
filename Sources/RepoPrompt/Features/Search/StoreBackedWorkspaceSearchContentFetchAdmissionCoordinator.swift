import Foundation

/// Bounds store-backed content-search descriptor work before freshness validation and
/// root content reads enter store/filesystem actors. Exact reads intentionally bypass
/// this search-only ingress.
actor StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator {
    struct Configuration: Equatable {
        static var production: Configuration {
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            return Configuration(
                fairSharePerStore: 2,
                maxBurstPerStore: 4,
                globalCapacity: max(12, min(32, processorCount * 2)),
                maxQueuedPerStore: max(32, min(128, processorCount * 4)),
                maxQueuedGlobally: max(128, min(512, processorCount * 16)),
                maxQueueWait: .seconds(8),
                retryAfterMilliseconds: 1000
            )
        }

        let fairSharePerStore: Int
        let maxBurstPerStore: Int
        let globalCapacity: Int
        let maxQueuedPerStore: Int
        let maxQueuedGlobally: Int
        let maxQueueWait: Duration
        let retryAfterMilliseconds: Int

        var maxQueueWaitMilliseconds: Int {
            let components = maxQueueWait.components
            let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
            return Int(clamping: milliseconds)
        }

        init(
            fairSharePerStore: Int,
            maxBurstPerStore: Int,
            globalCapacity: Int,
            maxQueuedPerStore: Int,
            maxQueuedGlobally: Int,
            maxQueueWait: Duration,
            retryAfterMilliseconds: Int = 1000
        ) {
            precondition(fairSharePerStore > 0)
            precondition(maxBurstPerStore >= fairSharePerStore)
            precondition(globalCapacity > 0)
            precondition(maxQueuedPerStore >= 0)
            precondition(maxQueuedGlobally >= 0)
            precondition(maxQueueWait > .zero)
            precondition(retryAfterMilliseconds >= 0)
            self.fairSharePerStore = fairSharePerStore
            self.maxBurstPerStore = maxBurstPerStore
            self.globalCapacity = globalCapacity
            self.maxQueuedPerStore = maxQueuedPerStore
            self.maxQueuedGlobally = maxQueuedGlobally
            self.maxQueueWait = maxQueueWait
            self.retryAfterMilliseconds = retryAfterMilliseconds
        }
    }

    struct AdmissionClock {
        static func continuous() -> AdmissionClock {
            let clock = ContinuousClock()
            let origin = clock.now
            return AdmissionClock(
                now: { origin.duration(to: clock.now) },
                sleepUntil: { deadline in
                    try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
                }
            )
        }

        let now: @Sendable () -> Duration
        let sleepUntil: @Sendable (_ deadline: Duration) async throws -> Void
    }

    static let shared = StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator()

    #if DEBUG
        /// Aggregate-only snapshots intentionally omit store and search identifiers.
        struct Snapshot: Equatable {
            let activePermitCount: Int
            let waiterCount: Int
        }

        struct GlobalSnapshot: Equatable {
            let activePermitCount: Int
            let waiterCount: Int
            let laneCount: Int
        }

        struct DebugSnapshot: Equatable {
            struct LaneLoad: Equatable {
                let activeCount: Int
                let queuedCount: Int
                let queuedSearchCount: Int
            }

            let configuration: Configuration
            let laneCount: Int
            let globalActiveCount: Int
            let globalQueuedCount: Int
            let overloadCount: Int
            let waitExpiryCount: Int
            let queuedCancellationCount: Int
            let laneLoads: [LaneLoad]

            var isIdle: Bool {
                globalActiveCount == 0 && globalQueuedCount == 0 && laneCount == 0
            }
        }

        enum DebugConfigurationUpdateResult: Equatable {
            case applied(DebugSnapshot)
            case busy(DebugSnapshot)
        }
    #endif

    private struct AdmissionMetrics {
        let storeActiveCount: Int
        let globalActiveCount: Int
        let storeQueueDepth: Int
        let globalQueueDepth: Int
    }

    private struct PermitAcquisition {
        let leaseID: UUID
        let storeKey: ObjectIdentifier
        let searchID: UUID
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let waited: Bool
        let queueAgeBucket: String
        let metrics: AdmissionMetrics
    }

    private struct WaiterState {
        let continuation: CheckedContinuation<PermitAcquisition, Error>
        let searchID: UUID
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let enqueueOrdinal: UInt64
        let enqueuedAtUptimeNanoseconds: UInt64
        let deadline: Duration
        var timeoutTask: Task<Void, Never>?
    }

    private struct Lane {
        var activeLeaseIDs = Set<UUID>()
        var waiterSearchOrder: [UUID] = []
        var waiterIDsBySearch: [UUID: [UUID]] = [:]
        var waiterStates: [UUID: WaiterState] = [:]
        var lastGrantOrdinal: UInt64?
    }

    private struct EligibleLane {
        let key: ObjectIdentifier
        let lastGrant: UInt64?
        let enqueueOrdinal: UInt64
    }

    private var configuration: Configuration
    private let clock: AdmissionClock
    private var lanes: [ObjectIdentifier: Lane] = [:]
    private var globalActiveCount = 0
    private var globalQueuedCount = 0
    private var nextEnqueueOrdinal: UInt64 = 0
    private var nextGrantOrdinal: UInt64 = 0
    private var overloadCount = 0
    private var waitExpiryCount = 0
    private var queuedCancellationCount = 0
    #if DEBUG
        private var permitAcquiredHandlerForTesting: (@Sendable (WorkspaceFileContextStore, UUID) async -> Void)?
    #endif

    init(
        configuration: Configuration = .production,
        clock: AdmissionClock = .continuous()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    func withContentFetchPermit<T>(
        for store: WorkspaceFileContextStore,
        searchID: UUID,
        operation: () async throws -> T
    ) async throws -> T {
        let storeKey = ObjectIdentifier(store)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        let waitState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.contentFetchAdmissionWait,
            admissionDimensions(metrics: metrics(for: storeKey), queueAgeBucket: "immediate")
        )

        let acquisition: PermitAcquisition
        do {
            acquisition = try await acquire(for: storeKey, searchID: searchID, lifecycleCorrelation: lifecycleCorrelation)
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFetchAdmissionWait,
                waitState,
                admissionDimensions(
                    outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                    metrics: acquisition.metrics,
                    queueAgeBucket: acquisition.queueAgeBucket
                )
            )
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFetchAdmissionWait,
                waitState,
                admissionDimensions(
                    outcome: Self.waitOutcome(for: error),
                    metrics: metrics(for: storeKey),
                    queueAgeBucket: queueAgeBucket(for: error)
                )
            )
            throw error
        }

        let leaseHoldState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.contentFetchLeaseHold,
            admissionDimensions(metrics: acquisition.metrics, queueAgeBucket: acquisition.queueAgeBucket)
        )
        var leaseHoldOutcome = "completed"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFetchLeaseHold,
                leaseHoldState,
                admissionDimensions(
                    outcome: leaseHoldOutcome,
                    metrics: metrics(for: storeKey),
                    queueAgeBucket: acquisition.queueAgeBucket
                )
            )
            release(acquisition)
        }
        do {
            try Task.checkCancellation()
            #if DEBUG
                if let permitAcquiredHandlerForTesting {
                    await permitAcquiredHandlerForTesting(store, searchID)
                }
            #endif
            try Task.checkCancellation()
            return try await operation()
        } catch {
            leaseHoldOutcome = error is CancellationError ? "cancelled" : "failed"
            throw error
        }
    }

    private static func waitOutcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? StoreBackedWorkspaceSearchAdmissionError else { return "error" }
        switch error {
        case .contentFetchQueueFull:
            return "queueFull"
        case .contentFetchWaitExpired:
            return "waitExpired"
        case .queueFull, .waitExpired:
            return "error"
        }
    }

    private func queueAgeBucket(for error: Error) -> String {
        guard let error = error as? StoreBackedWorkspaceSearchAdmissionError else { return "immediate" }
        switch error {
        case .contentFetchQueueFull, .queueFull:
            return "immediate"
        case .contentFetchWaitExpired, .waitExpired:
            return Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
        }
    }

    private static func queueAgeBucket(since enqueuedAtUptimeNanoseconds: UInt64?) -> String {
        guard let enqueuedAtUptimeNanoseconds else { return "immediate" }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= enqueuedAtUptimeNanoseconds ? now - enqueuedAtUptimeNanoseconds : 0
        return queueAgeBucket(milliseconds: Int(clamping: elapsed / 1_000_000))
    }

    private static func queueAgeBucket(milliseconds: Int) -> String {
        switch milliseconds {
        case ..<100:
            "lt100ms"
        case ..<500:
            "lt500ms"
        case ..<1000:
            "lt1s"
        case ..<2000:
            "lt2s"
        case ..<5000:
            "lt5s"
        case ..<8000:
            "lt8s"
        default:
            "gte8s"
        }
    }

    private func acquire(
        for storeKey: ObjectIdentifier,
        searchID: UUID,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async throws -> PermitAcquisition {
        try Task.checkCancellation()
        scheduleAvailablePermits()
        var lane = lanes[storeKey] ?? Lane()
        if canGrantImmediatePermit(for: storeKey, in: lane) {
            let acquisition = allocatePermit(
                for: storeKey,
                lane: &lane,
                searchID: searchID,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false
            )
            lanes[storeKey] = lane
            recordPermitAcquired(acquisition)
            return acquisition
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWaiter(
                    id: waiterID,
                    for: storeKey,
                    searchID: searchID,
                    continuation: continuation,
                    lifecycleCorrelation: lifecycleCorrelation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: storeKey) }
        }
    }

    private func enqueueWaiter(
        id: UUID,
        for storeKey: ObjectIdentifier,
        searchID: UUID,
        continuation: CheckedContinuation<PermitAcquisition, Error>,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let enqueuedAt = clock.now()
        scheduleAvailablePermits()
        var lane = lanes[storeKey] ?? Lane()
        if canGrantImmediatePermit(for: storeKey, in: lane) {
            let acquisition = allocatePermit(
                for: storeKey,
                lane: &lane,
                searchID: searchID,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false
            )
            lanes[storeKey] = lane
            recordPermitAcquired(acquisition)
            continuation.resume(returning: acquisition)
            return
        }

        if lane.waiterStates.count >= configuration.maxQueuedPerStore {
            recordOverload(scope: .perStore, storeKey: storeKey, lifecycleCorrelation: lifecycleCorrelation)
            continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.contentFetchQueueFull(
                scope: .perStore,
                retryAfterMilliseconds: configuration.retryAfterMilliseconds
            ))
            return
        }
        if globalQueuedCount >= configuration.maxQueuedGlobally {
            recordOverload(scope: .global, storeKey: storeKey, lifecycleCorrelation: lifecycleCorrelation)
            continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.contentFetchQueueFull(
                scope: .global,
                retryAfterMilliseconds: configuration.retryAfterMilliseconds
            ))
            return
        }

        nextEnqueueOrdinal &+= 1
        let deadline = enqueuedAt + configuration.maxQueueWait
        lane.waiterStates[id] = WaiterState(
            continuation: continuation,
            searchID: searchID,
            lifecycleCorrelation: lifecycleCorrelation,
            enqueueOrdinal: nextEnqueueOrdinal,
            enqueuedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            deadline: deadline,
            timeoutTask: nil
        )
        if lane.waiterIDsBySearch[searchID]?.isEmpty != false {
            lane.waiterSearchOrder.append(searchID)
        }
        lane.waiterIDsBySearch[searchID, default: []].append(id)
        globalQueuedCount += 1
        lanes[storeKey] = lane
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFetchWaitBegan,
            correlation: lifecycleCorrelation,
            admissionDimensions(metrics: metrics(for: storeKey), queueAgeBucket: "lt100ms")
        )

        let timeoutTask = Task { [clock] in
            do {
                try await clock.sleepUntil(deadline)
                self.expireWaiter(id: id, for: storeKey)
            } catch {
                // Grant and cancellation paths cancel the sleeper after removing the waiter.
            }
        }
        if var currentLane = lanes[storeKey], var waiter = currentLane.waiterStates[id] {
            waiter.timeoutTask = timeoutTask
            currentLane.waiterStates[id] = waiter
            lanes[storeKey] = currentLane
        } else {
            timeoutTask.cancel()
        }
        scheduleAvailablePermits()
    }

    private func cancelWaiter(id: UUID, for storeKey: ObjectIdentifier) {
        guard var lane = lanes[storeKey],
              let state = removeWaiter(id: id, from: &lane)
        else { return }
        state.timeoutTask?.cancel()
        globalQueuedCount = max(0, globalQueuedCount - 1)
        storeOrRemoveLane(lane, for: storeKey)
        queuedCancellationCount &+= 1
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFetchPermitCancelled,
            correlation: state.lifecycleCorrelation,
            admissionDimensions(
                outcome: "cancelled",
                metrics: metrics(for: storeKey),
                queueAgeBucket: Self.queueAgeBucket(since: state.enqueuedAtUptimeNanoseconds)
            )
        )
        state.continuation.resume(throwing: CancellationError())
        scheduleAvailablePermits()
    }

    private func expireWaiter(id: UUID, for storeKey: ObjectIdentifier) {
        guard var lane = lanes[storeKey],
              let state = removeWaiter(id: id, from: &lane)
        else { return }
        globalQueuedCount = max(0, globalQueuedCount - 1)
        storeOrRemoveLane(lane, for: storeKey)
        waitExpiryCount &+= 1
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFetchWaitExpired,
            correlation: state.lifecycleCorrelation,
            admissionDimensions(
                outcome: "waitExpired",
                metrics: metrics(for: storeKey),
                queueAgeBucket: Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
            )
        )
        state.continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.contentFetchWaitExpired(
            retryAfterMilliseconds: configuration.retryAfterMilliseconds
        ))
        scheduleAvailablePermits()
    }

    private func release(_ acquisition: PermitAcquisition) {
        guard var lane = lanes[acquisition.storeKey],
              lane.activeLeaseIDs.remove(acquisition.leaseID) != nil
        else { return }
        globalActiveCount = max(0, globalActiveCount - 1)
        storeOrRemoveLane(lane, for: acquisition.storeKey)
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFetchPermitReleased,
            correlation: acquisition.lifecycleCorrelation,
            admissionDimensions(
                outcome: "released",
                metrics: metrics(for: acquisition.storeKey),
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
        scheduleAvailablePermits()
    }

    private func scheduleAvailablePermits() {
        while globalActiveCount < configuration.globalCapacity {
            let storeKey = nextEligibleStoreKey(requiringFairShare: true) ?? nextEligibleStoreKey(requiringFairShare: false)
            guard let storeKey else { return }
            guard grantNextQueuedPermit(for: storeKey) else { continue }
        }
    }

    private func nextEligibleStoreKey(requiringFairShare: Bool) -> ObjectIdentifier? {
        var candidates: [EligibleLane] = []
        for (key, lane) in lanes {
            let activeLimit = requiringFairShare ? configuration.fairSharePerStore : configuration.maxBurstPerStore
            guard lane.activeLeaseIDs.count < activeLimit,
                  let enqueueOrdinal = firstEnqueueOrdinal(in: lane)
            else { continue }
            candidates.append(EligibleLane(key: key, lastGrant: lane.lastGrantOrdinal, enqueueOrdinal: enqueueOrdinal))
        }
        return candidates.min { lhs, rhs in
            switch (lhs.lastGrant, rhs.lastGrant) {
            case (nil, nil):
                return lhs.enqueueOrdinal < rhs.enqueueOrdinal
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (lhsGrant?, rhsGrant?):
                if lhsGrant != rhsGrant { return lhsGrant < rhsGrant }
                return lhs.enqueueOrdinal < rhs.enqueueOrdinal
            }
        }?.key
    }

    private func firstEnqueueOrdinal(in lane: Lane) -> UInt64? {
        lane.waiterSearchOrder
            .compactMap { lane.waiterIDsBySearch[$0]?.first }
            .compactMap { lane.waiterStates[$0]?.enqueueOrdinal }
            .min()
    }

    private func grantNextQueuedPermit(for storeKey: ObjectIdentifier) -> Bool {
        guard var lane = lanes[storeKey] else { return false }
        while !lane.waiterSearchOrder.isEmpty {
            let searchID = lane.waiterSearchOrder.removeFirst()
            guard var waiterIDs = lane.waiterIDsBySearch.removeValue(forKey: searchID),
                  !waiterIDs.isEmpty
            else { continue }
            let waiterID = waiterIDs.removeFirst()
            if !waiterIDs.isEmpty {
                lane.waiterIDsBySearch[searchID] = waiterIDs
                lane.waiterSearchOrder.append(searchID)
            }
            guard let state = lane.waiterStates.removeValue(forKey: waiterID) else { continue }
            state.timeoutTask?.cancel()
            globalQueuedCount = max(0, globalQueuedCount - 1)
            let acquisition = allocatePermit(
                for: storeKey,
                lane: &lane,
                searchID: state.searchID,
                lifecycleCorrelation: state.lifecycleCorrelation,
                waited: true,
                queueAgeBucket: Self.queueAgeBucket(since: state.enqueuedAtUptimeNanoseconds)
            )
            lanes[storeKey] = lane
            recordPermitAcquired(acquisition)
            state.continuation.resume(returning: acquisition)
            return true
        }
        storeOrRemoveLane(lane, for: storeKey)
        return false
    }

    private func removeWaiter(id: UUID, from lane: inout Lane) -> WaiterState? {
        guard let state = lane.waiterStates.removeValue(forKey: id) else { return nil }
        guard var waiterIDs = lane.waiterIDsBySearch[state.searchID] else { return state }
        waiterIDs.removeAll { $0 == id }
        if waiterIDs.isEmpty {
            lane.waiterIDsBySearch.removeValue(forKey: state.searchID)
            lane.waiterSearchOrder.removeAll { $0 == state.searchID }
        } else {
            lane.waiterIDsBySearch[state.searchID] = waiterIDs
        }
        return state
    }

    private func allocatePermit(
        for storeKey: ObjectIdentifier,
        lane: inout Lane,
        searchID: UUID,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
        waited: Bool,
        queueAgeBucket: String = "immediate"
    ) -> PermitAcquisition {
        let leaseID = UUID()
        lane.activeLeaseIDs.insert(leaseID)
        globalActiveCount += 1
        nextGrantOrdinal &+= 1
        lane.lastGrantOrdinal = nextGrantOrdinal
        return PermitAcquisition(
            leaseID: leaseID,
            storeKey: storeKey,
            searchID: searchID,
            lifecycleCorrelation: lifecycleCorrelation,
            waited: waited,
            queueAgeBucket: queueAgeBucket,
            metrics: metrics(for: storeKey, lane: lane)
        )
    }

    private func canGrantImmediatePermit(for storeKey: ObjectIdentifier, in lane: Lane) -> Bool {
        guard globalActiveCount < configuration.globalCapacity,
              lane.waiterStates.isEmpty,
              lane.activeLeaseIDs.count < configuration.maxBurstPerStore
        else { return false }
        if lane.activeLeaseIDs.count < configuration.fairSharePerStore {
            return true
        }
        return !hasCompetingFairShareWaiter(excluding: storeKey)
    }

    private func hasCompetingFairShareWaiter(excluding storeKey: ObjectIdentifier) -> Bool {
        lanes.contains { key, lane in
            key != storeKey &&
                !lane.waiterStates.isEmpty &&
                lane.activeLeaseIDs.count < configuration.fairSharePerStore
        }
    }

    private func storeOrRemoveLane(_ lane: Lane, for storeKey: ObjectIdentifier) {
        if lane.activeLeaseIDs.isEmpty, lane.waiterStates.isEmpty {
            lanes.removeValue(forKey: storeKey)
        } else {
            lanes[storeKey] = lane
        }
    }

    private func recordPermitAcquired(_ acquisition: PermitAcquisition) {
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFetchPermitAcquired,
            correlation: acquisition.lifecycleCorrelation,
            admissionDimensions(
                outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                metrics: acquisition.metrics,
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
    }

    private func recordOverload(
        scope: StoreBackedWorkspaceSearchAdmissionError.QueueScope,
        storeKey: ObjectIdentifier,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) {
        overloadCount &+= 1
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFetchOverloaded,
            correlation: lifecycleCorrelation,
            admissionDimensions(
                outcome: scope.rawValue,
                metrics: metrics(for: storeKey),
                queueAgeBucket: "immediate"
            )
        )
    }

    private func admissionDimensions(
        outcome: String? = nil,
        metrics: AdmissionMetrics,
        queueAgeBucket: String
    ) -> EditFlowPerf.Dimensions {
        EditFlowPerf.Dimensions(
            outcome: outcome,
            storeCapacity: configuration.maxBurstPerStore,
            globalCapacity: configuration.globalCapacity,
            storeActiveCount: metrics.storeActiveCount,
            globalActiveCount: metrics.globalActiveCount,
            storeQueueDepth: metrics.storeQueueDepth,
            globalQueueDepth: metrics.globalQueueDepth,
            admissionClass: "contentFetch",
            queueAgeBucket: queueAgeBucket,
            queueDepth: metrics.storeQueueDepth,
            waiterCount: metrics.storeQueueDepth
        )
    }

    private func metrics(for storeKey: ObjectIdentifier) -> AdmissionMetrics {
        metrics(for: storeKey, lane: lanes[storeKey])
    }

    private func metrics(for _: ObjectIdentifier, lane: Lane?) -> AdmissionMetrics {
        AdmissionMetrics(
            storeActiveCount: lane?.activeLeaseIDs.count ?? 0,
            globalActiveCount: globalActiveCount,
            storeQueueDepth: lane?.waiterStates.count ?? 0,
            globalQueueDepth: globalQueuedCount
        )
    }

    #if DEBUG
        func snapshot(for store: WorkspaceFileContextStore) -> Snapshot {
            let lane = lanes[ObjectIdentifier(store)]
            return Snapshot(
                activePermitCount: lane?.activeLeaseIDs.count ?? 0,
                waiterCount: lane?.waiterStates.count ?? 0
            )
        }

        func snapshot() -> GlobalSnapshot {
            GlobalSnapshot(
                activePermitCount: globalActiveCount,
                waiterCount: globalQueuedCount,
                laneCount: lanes.count
            )
        }

        func snapshotForDebug() -> DebugSnapshot {
            let laneLoads = lanes.values
                .map {
                    DebugSnapshot.LaneLoad(
                        activeCount: $0.activeLeaseIDs.count,
                        queuedCount: $0.waiterStates.count,
                        queuedSearchCount: $0.waiterIDsBySearch.count
                    )
                }
                .sorted {
                    if $0.activeCount != $1.activeCount { return $0.activeCount < $1.activeCount }
                    if $0.queuedCount != $1.queuedCount { return $0.queuedCount < $1.queuedCount }
                    return $0.queuedSearchCount < $1.queuedSearchCount
                }

            return DebugSnapshot(
                configuration: configuration,
                laneCount: lanes.count,
                globalActiveCount: globalActiveCount,
                globalQueuedCount: globalQueuedCount,
                overloadCount: overloadCount,
                waitExpiryCount: waitExpiryCount,
                queuedCancellationCount: queuedCancellationCount,
                laneLoads: laneLoads
            )
        }

        func configureForDebug(_ newConfiguration: Configuration) -> DebugConfigurationUpdateResult {
            guard globalActiveCount == 0,
                  globalQueuedCount == 0,
                  lanes.isEmpty
            else {
                return .busy(snapshotForDebug())
            }
            configuration = newConfiguration
            overloadCount = 0
            waitExpiryCount = 0
            queuedCancellationCount = 0
            return .applied(snapshotForDebug())
        }

        func resetDebugConfiguration() -> DebugConfigurationUpdateResult {
            configureForDebug(.production)
        }

        func setPermitAcquiredHandlerForTesting(
            _ handler: (@Sendable (WorkspaceFileContextStore, UUID) async -> Void)?
        ) {
            permitAcquiredHandlerForTesting = handler
        }
    #endif
}
