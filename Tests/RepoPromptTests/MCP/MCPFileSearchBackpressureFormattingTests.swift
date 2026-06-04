import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPFileSearchBackpressureFormattingTests: XCTestCase {
    func testProviderCatchesAdmissionBackpressureBeforePatternErrors() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift"),
            encoding: .utf8
        )
        let admissionCatch = try XCTUnwrap(source.range(of: "} catch let error as StoreBackedWorkspaceSearchAdmissionError {"))
        let mapping = try XCTUnwrap(source.range(of: "let reply = Self.searchBackpressureDTO(for: error, worktreeScope: worktreeScope)"))
        let patternCatch = try XCTUnwrap(source.range(of: "} catch let error as SearchPatternError {"))
        XCTAssertLessThan(admissionCatch.lowerBound, mapping.lowerBound)
        XCTAssertLessThan(mapping.lowerBound, patternCatch.lowerBound)
    }

    func testQueueFullMapsToMachineReadableRetryableDTO() throws {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .queueFull(scope: .global, retryAfterMilliseconds: 1250)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 1250)
        XCTAssertTrue(dto.errorMessage?.contains("temporarily busy") == true)
        XCTAssertTrue(dto.suggestion?.contains("filter.paths") == true)

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        XCTAssertEqual(object["error_code"]?.stringValue, "search_backpressure")
        XCTAssertEqual(object["retryable"]?.boolValue, true)
        XCTAssertEqual(object["retry_after_ms"]?.intValue, 1250)
    }

    func testWaitExpiredUsesTheSameRetryableBackpressureClassification() {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .waitExpired(retryAfterMilliseconds: 2000)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 2000)
        XCTAssertTrue(dto.errorMessage?.contains("wait expired") == true)
    }

    func testContentFetchQueueFullMapsToMachineReadableRetryableDTO() {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .contentFetchQueueFull(scope: .perStore, retryAfterMilliseconds: 750)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 750)
        XCTAssertTrue(dto.errorMessage?.contains("Content-search fetch capacity") == true)
    }

    func testContentFetchWaitExpiredUsesRetryableBackpressureClassification() {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .contentFetchWaitExpired(retryAfterMilliseconds: 1500)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 1500)
        XCTAssertTrue(dto.errorMessage?.contains("wait expired") == true)
    }

    func testRetryableBackpressureFormatsAsTemporaryBusyInsteadOfZeroMatches() throws {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .queueFull(scope: .perStore, retryAfterMilliseconds: 1000)
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Search Results ⚠️"), text)
        XCTAssertTrue(text.contains("**Status**: Temporarily busy"), text)
        XCTAssertTrue(text.contains("**Retryable**: yes"), text)
        XCTAssertTrue(text.contains("**Retry after**: 1000 ms"), text)
        XCTAssertTrue(text.contains("filter.paths"), text)
        XCTAssertFalse(text.contains("Total matches"), text)
        XCTAssertFalse(text.contains("Complete (limit not reached)"), text)
    }

    func testPatternFailureFormattingRemainsNonRetryable() throws {
        let dto = Self.errorDTO(
            errorMessage: "Invalid regular expression.",
            suggestion: "Use regex=false for literal matching."
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Search Results ❌"), text)
        XCTAssertTrue(text.contains("Invalid regular expression."), text)
        XCTAssertTrue(text.contains("Use regex=false"), text)
        XCTAssertFalse(text.contains("Temporarily busy"), text)
        XCTAssertFalse(text.contains("Retryable"), text)
    }

    func testNormalSearchDTOOmitsOptionalBackpressureFields() throws {
        let dto = ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: []
        )

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        XCTAssertNil(object["error_code"])
        XCTAssertNil(object["retryable"])
        XCTAssertNil(object["retry_after_ms"])
        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))
        XCTAssertTrue(text.contains("Complete (limit not reached)"), text)
        XCTAssertFalse(text.contains("Temporarily busy"), text)
    }

    private static func errorDTO(
        errorMessage: String,
        suggestion: String
    ) -> ToolResultDTOs.SearchResultDTO {
        ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: [],
            errorMessage: errorMessage,
            suggestion: suggestion
        )
    }

    private static func value(_ value: some Encodable) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
