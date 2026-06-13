import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class ContextBuilderModelStartupSelectionTests: XCTestCase {
    func testValidPersistedSelectionSurvivesStoreReloadAndStartupResolution() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexLow.rawValue,
            markUserDefined: true
        )

        let reloadedStore = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)
        let persisted = reloadedStore.persistedGlobalContextBuilderAgentSelection()
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: persisted.agentRaw,
            persistedModelRaw: persisted.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    func testUnavailablePersistedSelectionFallsBackToRecommendedAvailableProvider() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.claudeCode.rawValue,
            persistedModelRaw: AgentModel.claudeOpus.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: true
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    func testUnconfiguredClaudeCodeCannotBecomeEffectiveStartupSelection() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertNotEqual(resolved.agent, .claudeCode)
        XCTAssertNotEqual(resolved.modelRaw, AgentModel.claudeOpus.rawValue)
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: resolved.modelRaw,
            for: resolved.agent,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))
    }

    private func makeStoreFixture() throws -> (
        store: GlobalSettingsStore,
        defaults: UserDefaults,
        fileStore: GlobalSettingsFileStore
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderModelStartupSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "ContextBuilderModelStartupSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileStore = GlobalSettingsFileStore(
            fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
        )
        return (GlobalSettingsStore(defaults: defaults, fileStore: fileStore), defaults, fileStore)
    }
}
