import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceSaveCoordinatorTests: XCTestCase {
    override func tearDown() async throws {
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        try await super.tearDown()
    }

    func testRapidRequestsCoalesceBeforeRepresentativeWorkspacePreparation() async throws {
        let storageRoot = try makeTestDirectory(named: "RapidRequests")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        let workspace = representativeWorkspace(storageRoot: storageRoot)
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.markWorkspaceDirty()

        for _ in 0 ..< 100 {
            manager.test_scheduleWorkspaceSave(source: "test.rapid")
        }
        await drainMainActorTasks()
        let outcome = await manager.test_flushWorkspaceSave(source: "test.rapid.flush")

        XCTAssertEqual(outcome, .committed(version: 1))
        XCTAssertEqual(manager.test_workspaceSavePreparationCount(workspaceID: workspace.id), 1)
        let summary = try XCTUnwrap(manager.test_workspaceSavePerformanceSummary(workspaceID: workspace.id))
        XCTAssertEqual(summary.composeTabCount, 25)
        XCTAssertGreaterThanOrEqual(summary.payloadByteCount, 100_000)
        XCTAssertEqual(summary.selectedPathCount, 180)
        XCTAssertEqual(summary.sliceFileCount, 130)
        XCTAssertEqual(summary.sliceRangeCount, 260)
        XCTAssertGreaterThanOrEqual(summary.coalescedRequestCount, 100)
        XCTAssertEqual(summary.atomicWriteCount, 1)
    }

    func testMutationDuringPreparationProducesOneFollowUpAndFlushCommitsNewestState() async throws {
        let storageRoot = try makeTestDirectory(named: "MutationDuringPreparation")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        var workspace = representativeWorkspace(storageRoot: storageRoot)
        workspace.currentPromptText = "before"
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.markWorkspaceDirty()
        let gate = WorkspaceSavePreparationGate()
        manager.test_setWorkspaceSavePreparationGate { _, _ in
            await gate.pauseFirstPreparation()
        }

        manager.test_scheduleWorkspaceSave(source: "test.blockedPreparation")
        await gate.waitUntilPaused()
        manager.workspaces[0].currentPromptText = "after"
        manager.workspaces[0].dateModified = Date()
        for _ in 0 ..< 20 {
            manager.test_scheduleWorkspaceSave(source: "test.newerWhileBlocked")
        }
        await drainMainActorTasks()
        await gate.release()
        let outcome = await manager.test_flushWorkspaceSave(source: "test.boundaryFlush")
        manager.test_setWorkspaceSavePreparationGate(nil)

        XCTAssertEqual(outcome, .committed(version: 1))
        XCTAssertEqual(manager.test_workspaceSavePreparationCount(workspaceID: workspace.id), 2)
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        let decoded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
        XCTAssertEqual(decoded.currentPromptText, "after")
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), 1)
    }

    func testFailedAtomicWriteIsObservableAndDoesNotAdvanceSavedVersion() async throws {
        let storageRoot = try makeTestDirectory(named: "FailedWrite")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        let workspace = representativeWorkspace(storageRoot: storageRoot)
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.markWorkspaceDirty()
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        let gate = WorkspaceSavePreparationGate()
        manager.test_setWorkspaceSavePreparationGate { _, _ in
            await gate.pauseFirstPreparation()
        }
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        await writer.setFailAtomicWriteForTesting(url: fileURL, afterAdditionalAttempts: 2)

        manager.test_scheduleWorkspaceSave(source: "test.firstSnapshot")
        await gate.waitUntilPaused()
        manager.workspaces[0].currentPromptText = "newer same-version state"
        manager.workspaces[0].dateModified = Date()
        manager.test_scheduleWorkspaceSave(source: "test.newerSnapshot")
        await drainMainActorTasks()
        await gate.release()

        let failed = await manager.test_flushWorkspaceSave(source: "test.injectedFailure")
        manager.test_setWorkspaceSavePreparationGate(nil)

        XCTAssertEqual(failed, .failed)
        XCTAssertNil(manager.test_lastSavedVersion(workspaceID: workspace.id))

        await writer.setFailAtomicWriteForTesting(url: fileURL, afterAdditionalAttempts: nil)
        let retried = await manager.test_flushWorkspaceSave(source: "test.retryAfterFailure")
        XCTAssertEqual(retried, .committed(version: 1))
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), 1)
        let decoded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
        XCTAssertEqual(decoded.currentPromptText, "newer same-version state")
    }

    private func makeManager(storageRoot: URL) -> WorkspaceManagerViewModel {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        let defaults = UserDefaults.standard
        let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defaults.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
        defer {
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            if let previousStoragePath {
                defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                defaults.removeObject(forKey: "GlobalCustomStorageURL")
            }
        }
        return WindowStateCompositionFactory.make(
            windowID: -940 - Int.random(in: 1 ... 40),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        ).workspaceManager
    }

    private func representativeWorkspace(storageRoot: URL) -> WorkspaceModel {
        let selectedPaths = (0 ..< 180).map { "/synthetic/root/File\($0).swift" }
        let slices = Dictionary(uniqueKeysWithValues: (0 ..< 130).map { index in
            (
                "/synthetic/root/Slice\(index).swift",
                [
                    LineRange(start: 1, end: 5),
                    LineRange(start: 20, end: 30)
                ]
            )
        })
        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            slices: slices,
            codemapAutoEnabled: false
        )
        let tabs = (0 ..< 25).map { index in
            ComposeTabState(
                name: "T\(index + 1)",
                selection: index == 0 ? selection : .init(),
                promptText: String(repeating: "p", count: 4000)
            )
        }
        return WorkspaceModel(
            name: "Synthetic Save Fixture",
            repoPaths: ["/synthetic/root"],
            customStoragePath: storageRoot.appendingPathComponent("workspace", isDirectory: true),
            composeTabs: tabs,
            activeComposeTabID: tabs[0].id
        )
    }

    private func makeTestDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSaveCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func drainMainActorTasks() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
    }
}

private actor WorkspaceSavePreparationGate {
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstPreparation() async {
        guard !didPause else { return }
        didPause = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async {
        if didPause {
            return
        }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
