import Foundation
import RepoPromptShared

// MARK: - Scanner Protocol

/// Protocol for cross-workspace session metadata scanning.
/// Used for dependency injection in the MCP tool service (WI-3).
protocol HistorySessionScanning: Sendable {
    /// Discover all workspace directories and read their session metadata indexes.
    /// Returns one result per workspace that has an AgentSessions directory.
    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult]

    /// Filter metadata records across all workspaces.
    /// Calls ``scanAllWorkspaces()`` internally, then applies the given filters.
    func sessionsMatchingFilters(
        _ records: [HistoryWorkspaceScanResult],
        workspace: String?,
        agentKind: String?,
        model: String?,
        filePath: String?,
        from: Date?,
        to: Date?
    ) -> [HistoryFilteredSessionRecord]

    /// Lazily load a full transcript for a specific session.
    /// Used by the ``search`` operation to walk turns for text matching.
    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> AgentTranscript
}

// MARK: - Scan Results

/// Result of scanning a single workspace's session metadata.
struct HistoryWorkspaceScanResult: Equatable {
    /// The workspace directory URL (e.g. `.../Workspaces/Workspace-MyProject-UUID/`).
    let workspaceDir: URL
    /// Human-readable workspace name resolved from directory structure or workspace.json.
    let workspaceName: String
    /// The workspace UUID extracted from the directory name, if parseable.
    let workspaceID: UUID?
    /// Session metadata records from this workspace's index.
    let records: [AgentSessionMetadataRecord]
    /// Whether the index file was missing or unreadable (records will be empty).
    let indexReadFailed: Bool
    /// Non-nil when the index decoded successfully but its schema version doesn't match
    /// ``AgentSessionMetadataIndex/currentSchemaVersion``. Records are empty in this case.
    let indexSchemaVersion: Int?
}

/// A metadata record paired with its workspace context, ready for filtering.
struct HistoryFilteredSessionRecord: Equatable {
    let record: AgentSessionMetadataRecord
    let workspaceName: String
    let workspaceDir: URL

    var sessionID: UUID {
        record.id
    }
}

// MARK: - Scanner Errors

enum HistorySessionScannerError: Error, Equatable, LocalizedError {
    case workspaceDirectoryNotFound(URL)
    case indexDecodingFailed(workspaceDir: URL, underlying: String)
    case sessionFileNotFound(sessionID: UUID, workspaceDir: URL)
    case transcriptDecodingFailed(sessionID: UUID, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .workspaceDirectoryNotFound(url):
            "Workspace directory not found: \(url.path)"
        case let .indexDecodingFailed(workspaceDir, underlying):
            "Failed to decode index in \(workspaceDir.lastPathComponent): \(underlying)"
        case let .sessionFileNotFound(sessionID, workspaceDir):
            "Session file not found for \(sessionID) in \(workspaceDir.lastPathComponent)"
        case let .transcriptDecodingFailed(sessionID, underlying):
            "Failed to decode transcript for session \(sessionID): \(underlying)"
        }
    }
}

// MARK: - Scanner Actor

/// Scans all workspace directories on disk, reads their ``AgentSessionMetadataIndex`` files,
/// and returns unified metadata across workspaces. Provides lazy transcript loading for the
/// ``search`` operation.
///
/// Uses ``MCPFilesystemIdentity.applicationSupportRootURL()`` for the base path and discovers
/// workspaces under `Workspaces/*/`. Each workspace directory is expected to contain an
/// `AgentSessions/AgentSessionIndex.json` file.
actor HistorySessionScanner: HistorySessionScanning {
    private static let defaultScanCacheTTL: TimeInterval = 10 * 60

    private let fileManager: FileManager
    private let decoder: JSONDecoder

    /// Base URL for application support. Defaults to ``MCPFilesystemIdentity.applicationSupportRootURL()``.
    /// Injectable for testing.
    private let applicationSupportRoot: URL
    private let scanCacheTTL: TimeInterval
    private var cachedScanResults: [HistoryWorkspaceScanResult]?
    private var cachedScanResultsAt: Date?

    init(
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder(),
        applicationSupportRoot: URL? = nil,
        scanCacheTTL: TimeInterval = HistorySessionScanner.defaultScanCacheTTL
    ) {
        self.fileManager = fileManager
        self.decoder = decoder
        self.applicationSupportRoot = applicationSupportRoot
            ?? MCPFilesystemConstants.identity.applicationSupportRootURL(fileManager: fileManager)
        self.scanCacheTTL = scanCacheTTL
    }

    // MARK: - Workspace Discovery

    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
        let now = Date()
        // History queries are usually iterative model investigations, not live tailing.
        // Keep the expensive cross-workspace inventory warm for several minutes so
        // list/search/time calls in the same reasoning loop do not repeatedly reopen
        // thousands of tiny stale index files.
        if let cachedScanResults,
           let cachedScanResultsAt,
           now.timeIntervalSince(cachedScanResultsAt) < scanCacheTTL
        {
            return cachedScanResults
        }

        let workspacesRoot = applicationSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)

        guard fileManager.fileExists(atPath: workspacesRoot.path) else {
            cachedScanResults = []
            cachedScanResultsAt = now
            return []
        }

        let workspaceDirs: [URL]
        do {
            workspaceDirs = try fileManager.contentsOfDirectory(
                at: workspacesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        } catch {
            return []
        }

        let results = workspaceDirs.map { workspaceDir in
            scanWorkspace(workspaceDir)
        }
        cachedScanResults = results
        cachedScanResultsAt = Date()
        return results
    }

    // MARK: - Filtering

    nonisolated func sessionsMatchingFilters(
        _ scanResults: [HistoryWorkspaceScanResult],
        workspace: String?,
        agentKind: String?,
        model: String?,
        filePath: String?,
        from: Date?,
        to: Date?
    ) -> [HistoryFilteredSessionRecord] {
        var results: [HistoryFilteredSessionRecord] = []

        for scan in scanResults {
            // Skip workspaces whose index schema doesn't match the current version.
            if scan.indexSchemaVersion != nil { continue }

            // Workspace name filter: match against workspace name or workspace ID string
            if let workspace {
                let nameMatch = scan.workspaceName.localizedCaseInsensitiveContains(workspace)
                let idMatch = scan.workspaceID?.uuidString.caseInsensitiveCompare(workspace) == .orderedSame
                let dirNameMatch = scan.workspaceDir.lastPathComponent.localizedCaseInsensitiveContains(workspace)
                guard nameMatch || idMatch || dirNameMatch else { continue }
            }

            for record in scan.records {
                // Agent kind filter
                if let agentKind {
                    guard record.agentKindRaw?.localizedCaseInsensitiveContains(agentKind) == true else { continue }
                }

                // Model filter
                if let model {
                    guard record.agentModelRaw?.localizedCaseInsensitiveContains(model) == true else { continue }
                }

                // File path filter: match against keyPaths using basename/suffix-aware
                // semantics so callers can provide a basename, repo-relative path, or
                // absolute/worktree path without silently missing an indexed session.
                if let filePath {
                    let matchesFile = record.keyPaths.contains { keyPath in
                        HistoryMCPToolService.historyPath(keyPath, matches: filePath)
                    }
                    guard matchesFile else { continue }
                }

                // Date range filter — OVERLAP semantics: a session is included if ANY of its
                // activity falls within [from, to]. A session started before the range but still
                // active during it counts (e.g. a chat resumed days later).
                if let from {
                    guard (record.lastActivityAt ?? record.savedAt) >= from else { continue }
                }
                if let to {
                    guard (record.firstActivityAt ?? record.activityDate) <= to else { continue }
                }

                results.append(HistoryFilteredSessionRecord(
                    record: record,
                    workspaceName: scan.workspaceName,
                    workspaceDir: scan.workspaceDir
                ))
            }
        }

        return results
    }

    // MARK: - Transcript Loading

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> AgentTranscript {
        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        let filename = "AgentSession-\(sessionID.uuidString).json"
        let sessionFile = agentSessionsDir.appendingPathComponent(filename)

        guard fileManager.fileExists(atPath: sessionFile.path) else {
            throw HistorySessionScannerError.sessionFileNotFound(
                sessionID: sessionID,
                workspaceDir: workspaceDir
            )
        }

        do {
            let data = try Data(contentsOf: sessionFile, options: .mappedIfSafe)

            // Decode the session and extract the transcript.
            // We decode as a full AgentSession to get the transcript field.
            let session = try decoder.decode(AgentSession.self, from: data)
            guard let transcript = session.transcript else {
                return .empty
            }
            return transcript
        } catch let error as DecodingError {
            throw HistorySessionScannerError.transcriptDecodingFailed(
                sessionID: sessionID,
                underlying: decodingErrorDescription(error)
            )
        } catch {
            throw HistorySessionScannerError.transcriptDecodingFailed(
                sessionID: sessionID,
                underlying: error.localizedDescription
            )
        }
    }

    // MARK: - Private Helpers

    private func scanWorkspace(_ workspaceDir: URL) -> HistoryWorkspaceScanResult {
        let dirName = workspaceDir.lastPathComponent
        let fallbackIdentity = WorkspaceDirectoryName.parse(dirName)

        func result(
            records: [AgentSessionMetadataRecord] = [],
            indexReadFailed: Bool = false,
            indexSchemaVersion: Int? = nil,
            identity: (name: String, id: UUID?) = fallbackIdentity
        ) -> HistoryWorkspaceScanResult {
            HistoryWorkspaceScanResult(
                workspaceDir: workspaceDir,
                workspaceName: identity.name,
                workspaceID: identity.id,
                records: records,
                indexReadFailed: indexReadFailed,
                indexSchemaVersion: indexSchemaVersion
            )
        }

        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        guard fileManager.fileExists(atPath: agentSessionsDir.path) else {
            // No AgentSessions directory — this workspace has no sessions. Avoid reading
            // workspace.json on the cold scan path; the directory name is sufficient.
            return result()
        }

        let indexFile = agentSessionsDir.appendingPathComponent("AgentSessionIndex.json")
        guard fileManager.fileExists(atPath: indexFile.path) else {
            // No index file — return empty records (no failure flag; index may not exist yet).
            return result()
        }

        do {
            let data = try Data(contentsOf: indexFile, options: .mappedIfSafe)
            guard let schemaVersion = schemaVersionSniff(from: data) else {
                return result(indexReadFailed: true)
            }

            // Reject stale indexes before full metadata decode. Most user installs carry many
            // tiny stale indexes; fully decoding them dominates cold history scans even though
            // the records will be discarded immediately afterward.
            guard schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                return result(indexSchemaVersion: schemaVersion)
            }

            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            let identity = resolveWorkspaceNameAndID(from: workspaceDir, dirName: dirName, fileManager: fileManager)
            return result(records: index.entries, identity: identity)
        } catch {
            return result(indexReadFailed: true)
        }
    }

    private nonisolated func schemaVersionSniff(from data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: "\"schemaVersion\"")
        else { return nil }
        guard let colon = text[keyRange.upperBound...].firstIndex(of: ":") else { return nil }
        var index = text.index(after: colon)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        let start = index
        while index < text.endIndex, text[index].isNumber || text[index] == "-" {
            index = text.index(after: index)
        }
        guard start < index else { return nil }
        return Int(text[start ..< index])
    }

    /// Resolve workspace name and ID from the directory.
    /// Tries workspace.json first, then parses the `Workspace-{name}-{uuid}` directory name
    /// via the shared ``WorkspaceDirectoryName`` parser.
    private nonisolated func resolveWorkspaceNameAndID(
        from workspaceDir: URL,
        dirName: String,
        fileManager: FileManager
    ) -> (name: String, id: UUID?) {
        // Try reading workspace.json for the canonical name.
        let workspaceJSON = workspaceDir.appendingPathComponent("workspace.json")
        if fileManager.fileExists(atPath: workspaceJSON.path) {
            if let data = try? Data(contentsOf: workspaceJSON, options: .mappedIfSafe),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String
            {
                let id = (json["id"] as? String).flatMap { UUID(uuidString: $0) }
                return (name: name, id: id)
            }
        }

        // Parse directory name: "Workspace-{name}-{uuid}" or fall back to directory name.
        return WorkspaceDirectoryName.parse(dirName)
    }

    /// Produce a human-readable description from a DecodingError for error reporting.
    private nonisolated func decodingErrorDescription(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(type, context):
            "Type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case let .valueNotFound(type, context):
            "Value not found for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case let .keyNotFound(key, context):
            "Key not found '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case let .dataCorrupted(context):
            "Data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            error.localizedDescription
        }
    }
}
