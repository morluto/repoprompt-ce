import MCP
@testable import RepoPrompt
import XCTest

final class MCPMutationRetryableFailureTests: XCTestCase {
    func testFailClosedLookupContextProducesRetryableWorktreeFailure() {
        let failure = MCPMutationRetryableFailure.worktreeScopeUnavailable(missingPhysicalRootPaths: [])

        XCTAssertEqual(failure.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(failure.retryable, true)
        XCTAssertEqual(failure.retryAfterMilliseconds, 1000)
        XCTAssertTrue(failure.errorMessage.contains("stopped before path translation"), failure.errorMessage)
        XCTAssertTrue(failure.errorMessage.contains("canonical checkout"), failure.errorMessage)
    }

    func testFileActionRetryableFailureDTOAndFormatterExposeCode() throws {
        let failure = MCPMutationRetryableFailure.worktreeScopeUnavailable(missingPhysicalRootPaths: [])
        let dto = ToolResultDTOs.FileActionReply.retryableFailure(
            action: "create",
            path: "Sources/New.swift",
            newPath: nil,
            failure: failure
        )
        let value = try Value(dto)

        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.FileActionReply.self))
        XCTAssertEqual(decoded.status, "failed")
        XCTAssertEqual(decoded.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(decoded.retryable, true)
        XCTAssertEqual(decoded.retryAfterMilliseconds, 1000)

        let text = try Self.onlyText(ToolOutputFormatter.formatFileAction(value: value))
        XCTAssertTrue(text.contains("## File Action ❌"), text)
        XCTAssertTrue(text.contains("**Code**: worktree_scope_unavailable"), text)
        XCTAssertTrue(text.contains("Retryable: yes"), text)
        XCTAssertTrue(text.contains("Retry after: 1000 ms"), text)
    }

    func testApplyEditsFailureSummaryFormattingExposesRetryableCode() throws {
        let failure = MCPMutationRetryableFailure.worktreeScopeUnavailable(missingPhysicalRootPaths: [])
        let dto = ToolResultDTOs.EditSummary(
            status: "failed",
            editsRequested: 1,
            editsApplied: 0,
            addedLines: nil,
            deletedLines: nil,
            totalLinesChanged: nil,
            totalChunks: nil,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            errorMessage: failure.errorMessage,
            errorCode: failure.errorCode,
            retryable: failure.retryable,
            retryAfterMilliseconds: failure.retryAfterMilliseconds,
            suggestion: failure.suggestion
        )
        let value = try Value(dto)

        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.EditSummary.self))
        XCTAssertEqual(decoded.status, "failed")
        XCTAssertEqual(decoded.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(decoded.retryable, true)

        let text = try Self.onlyText(ToolOutputFormatter.formatApplyEdits(value: value, emitResources: false))
        XCTAssertTrue(text.contains("### Error"), text)
        XCTAssertFalse(text.contains("### Notes"), text)
        XCTAssertEqual(text.components(separatedBy: failure.errorMessage).count - 1, 1, text)
        XCTAssertTrue(text.contains("**Code**: worktree_scope_unavailable"), text)
        XCTAssertTrue(text.contains("Retryable: yes"), text)
        XCTAssertTrue(text.contains("Retry after: 1000 ms"), text)
    }

    func testApplyEditsFailedWithoutErrorMetadataOmitsEmptyErrorHeading() throws {
        let dto = ToolResultDTOs.EditSummary(
            status: "failed",
            editsRequested: 1,
            editsApplied: 0,
            addedLines: nil,
            deletedLines: nil,
            totalLinesChanged: nil,
            totalChunks: nil,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            errorMessage: nil,
            errorCode: nil,
            retryable: nil,
            retryAfterMilliseconds: nil,
            suggestion: nil
        )
        let value = try Value(dto)

        let text = try Self.onlyText(ToolOutputFormatter.formatApplyEdits(value: value, emitResources: false))
        XCTAssertFalse(text.contains("### Error"), text)
    }

    private static func onlyText(_ content: [MCP.Tool.Content]) throws -> String {
        guard content.count == 1 else {
            XCTFail("Expected one content block, got \(content.count)")
            return ""
        }
        guard case let .text(text, _, _) = content[0] else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
