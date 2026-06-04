import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

extension FileSystemService {
    // MARK: - File and folder manipulation utilities

    private func mutationTarget(
        forRelativePath rawRelativePath: String,
        rejectExistingLeafSymlink: Bool = true
    ) throws -> (relativePath: String, url: URL) {
        guard !rawRelativePath.hasPrefix("/"), !StandardizedPath.containsNUL(rawRelativePath) else {
            throw FileSystemError.invalidRelativePath
        }
        let relativePath = StandardizedPath.relative(rawRelativePath)
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            throw FileSystemError.invalidRelativePath
        }

        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path != standardizedRootPath,
              StandardizedPath.isDescendant(url.path, of: standardizedRootPath)
        else {
            throw FileSystemError.invalidRelativePath
        }

        var current = rootURL
        for component in relativePath.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            guard !pathIsSymbolicLink(current.path) else { throw FileSystemError.invalidRelativePath }
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: current.path, isDirectory: &isDirectory) else { break }
            guard isDirectory.boolValue else { throw FileSystemError.invalidRelativePath }
        }

        let canonicalParentPath = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalParentPath == canonicalRootPath || StandardizedPath.isDescendant(canonicalParentPath, of: canonicalRootPath) else {
            throw FileSystemError.invalidRelativePath
        }
        if rejectExistingLeafSymlink, pathIsSymbolicLink(url.path) {
            throw FileSystemError.invalidRelativePath
        }
        return (relativePath, url)
    }

    private func pathIsSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFLNK
    }

    private func requireRegularMutationSource(relativePath: String) async throws {
        switch await catalogRegularFileEligibility(relativePath: relativePath) {
        case .eligible, .ineligible(.ignored):
            return
        case .ineligible(.missingOrDirectory):
            throw FileSystemError.fileNotFound
        case .ineligible:
            throw FileSystemError.invalidRelativePath
        }
    }

    /// Atomically move/rename a **file** inside the same root.
    func moveFile(
        atRelativePath oldRelPath: String,
        toRelativePath newRelPath: String
    ) async throws {
        let fm = fm // Cache for multiple calls in this method

        // --- prepare -----------------------------------------------------
        // ── 0. Validate that both paths stay inside the loaded root ─────────────
        let oldTarget = try mutationTarget(forRelativePath: oldRelPath)
        let newTarget = try mutationTarget(forRelativePath: newRelPath)
        let oldFull = oldTarget.url.path
        let newFull = newTarget.url.path
        try await requireRegularMutationSource(relativePath: oldTarget.relativePath)

        // 1) Source must exist
        guard fm.fileExists(atPath: oldFull, isDirectory: nil) else {
            throw FileSystemError.fileNotFound
        }

        // 2) Destination must not exist
        guard !fm.fileExists(atPath: newFull, isDirectory: nil) else {
            throw FileSystemError.fileAlreadyExists
        }

        // 3) Ensure parent folder exists (this is fast, keep it in-actor)
        let destDir = (newFull as NSString).deletingLastPathComponent
        try fm.createDirectory(
            atPath: destDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        _ = try mutationTarget(forRelativePath: newTarget.relativePath)

        // --- 1. do I/O off-actor ----------------------------------------
        // 4) Perform the move on disk
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.moveItem(atPath: oldFull, toPath: newFull)
            }.value // bubbles error
        } catch {
            throw FileSystemError.failedToCreateFile(error)
        }

        let destinationEligibility = await catalogRegularFileEligibility(relativePath: newTarget.relativePath)
        switch destinationEligibility {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            try? FileManager.default.moveItem(atPath: newFull, toPath: oldFull)
            throw FileSystemError.invalidRelativePath
        }

        // --- 2. in-memory bookkeeping (still inside actor) --------------
        // 5) Immediate in‑memory bookkeeping (fixes race window) ───────────────
        let stdOld = oldTarget.relativePath
        let stdNew = newTarget.relativePath

        if let wasDir = visitedItems.removeValue(forKey: stdOld) {
            visitedItems[stdNew] = wasDir // will be 'false' for files
        }
        visitedPaths.remove(stdOld)
        visitedPaths.insert(stdNew)

        // Transfer encoding if we have it
        if let encoding = encodingMap[stdOld] {
            encodingMap.removeValue(forKey: stdOld)
            encodingMap[stdNew] = encoding
        }

        // 6) Emit synthetic deltas so the UI updates before FSEvents arrive
        publishFileSystemDeltas([.fileRemoved(stdOld), .fileAdded(stdNew)], source: .syntheticMutation)
    }

    func createFile(atRelativePath relativePath: String, content: String) async throws {
        let fm = fm // Cache for multiple calls in this method
        // --- prepare -----------------------------------------------------
        let target = try mutationTarget(forRelativePath: relativePath)
        let fullPath = target.url.path
        let fullURL = target.url

        // Ensure directory exists (this is fast, keep it in-actor)
        let directoryURL = fullURL.deletingLastPathComponent()
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        _ = try mutationTarget(forRelativePath: target.relativePath)

        // Check if file already exists
        if fm.fileExists(atPath: fullPath, isDirectory: nil) {
            throw FileSystemError.fileAlreadyExists
        }

        // Prepare data with UTF-8 encoding
        guard let data = content.data(using: .utf8) else {
            throw FileSystemError.failedToCreateFile(
                NSError(
                    domain: "encoding",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as UTF-8"]
                )
            )
        }

        // --- 1. do I/O off-actor ----------------------------------------
        do {
            try await Task.detached(priority: .utility) {
                try FileSystemService.writeFileRobust(to: fullURL, data: data)
            }.value // bubbles error
            fileSystemDebugLog("File created at \(fullURL.path)")
        } catch {
            throw FileSystemError.failedToCreateFile(error)
        }

        switch await catalogRegularFileEligibility(relativePath: target.relativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            try? fm.removeItem(at: fullURL)
            forgetTrackedPath(target.relativePath)
            throw FileSystemError.invalidRelativePath
        }

        // --- 2. in-memory bookkeeping (still inside actor) --------------
        // update encoding cache (new files default to UTF-8)
        encodingMap[target.relativePath] = .utf8

        // update visited* sets
        if !visitedPaths.contains(target.relativePath) {
            visitedPaths.insert(target.relativePath)
            visitedItems[target.relativePath] = false
        }

        // emit a *synthetic* delta so the UI updates immediately
        publishFileSystemDeltas([.fileAdded(target.relativePath)], source: .syntheticMutation)
    }

    func deleteFile(atRelativePath relativePath: String) async throws {
        let target = try mutationTarget(forRelativePath: relativePath)
        try await requireRegularMutationSource(relativePath: target.relativePath)
        let url = target.url
        do {
            try fm.removeItem(at: url)
            fileSystemDebugLog("File deleted at \(url.path)")
        } catch {
            throw FileSystemError.failedToDeleteFile(error)
        }
        forgetTrackedPath(target.relativePath)
        publishFileSystemDeltas([.fileRemoved(target.relativePath)], source: .syntheticMutation)
    }

    func moveItemToTrash(atRelativePath relativePath: String) async throws {
        let target = try mutationTarget(forRelativePath: relativePath)
        let normalizedRelativePath = target.relativePath
        let url = target.url
        let fullPath = url.path

        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
            throw FileSystemError.fileNotFound
        }

        do {
            _ = try moveURLToTrash(url)
            fileSystemDebugLog("File moved to Trash at \(url.path)")
        } catch {
            throw FileSystemError.failedToDeleteFile(error)
        }

        let keysToForget = encodingMap.keys.filter {
            $0 == normalizedRelativePath || $0.hasPrefix(normalizedRelativePath + "/")
        }
        for key in keysToForget {
            encodingMap.removeValue(forKey: key)
        }

        var deltas = removeSubtree(for: normalizedRelativePath)
        if deltas.isEmpty {
            deltas = [isDirectory.boolValue ? .folderRemoved(normalizedRelativePath) : .fileRemoved(normalizedRelativePath)]
        }
        if !deltas.isEmpty {
            publishFileSystemDeltas(deltas, source: .syntheticMutation)
        }
    }

    private func forgetTrackedPath(_ relativePath: String) {
        encodingMap.removeValue(forKey: relativePath)
        visitedPaths.remove(relativePath)
        visitedItems.removeValue(forKey: relativePath)
    }

    private func moveURLToTrash(_ url: URL) throws -> URL? {
        #if DEBUG
            return try fm.moveItemToTrash(at: url)
        #else
            var resultingItemURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resultingItemURL)
            return resultingItemURL as URL?
        #endif
    }

    /// Re-written non-blocking version
    func editFile(atRelativePath relativePath: String, newContent: String) async throws {
        // --- prepare -----------------------------------------------------
        let target = try mutationTarget(forRelativePath: relativePath)
        let fullPath = target.url.path
        let fullURL = target.url
        guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
            throw FileSystemError.fileNotFound
        }
        switch await catalogRegularFileEligibility(relativePath: target.relativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible(.missingOrDirectory):
            throw FileSystemError.fileNotFound
        case .ineligible:
            throw FileSystemError.invalidRelativePath
        }
        let enc = encodingMap[target.relativePath] ?? .utf8
        guard let data = newContent.data(using: enc) else {
            throw FileSystemError.failedToEditFile(
                NSError(
                    domain: "encoding",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as \(enc)"]
                )
            )
        }

        // --- 1. do I/O off-actor ----------------------------------------
        do {
            try await Task.detached(priority: .utility) {
                try FileSystemService.writeFileRobust(to: fullURL, data: data)
            }.value // bubbles error
        } catch {
            throw FileSystemError.failedToEditFile(error)
        }

        switch await catalogRegularFileEligibility(relativePath: target.relativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            throw FileSystemError.invalidRelativePath
        }

        // --- 2. in-memory bookkeeping (still inside actor) --------------
        // refresh encoding cache
        encodingMap[target.relativePath] = enc

        // update visited* sets so later FSEvents don't look "new"
        if !visitedPaths.contains(target.relativePath) {
            visitedPaths.insert(target.relativePath)
            visitedItems[target.relativePath] = false
        }

        // emit a *synthetic* delta so the UI updates immediately, with mtime if available
        let mdate = try? await getFileModificationDate(atRelativePath: target.relativePath)
        publishFileSystemDeltas([.fileModified(target.relativePath, mdate)], source: .syntheticMutation)
    }

    func checkFilePermissions(atRelativePath relativePath: String) -> Bool {
        let fullPath = fullPath(forRelativePath: relativePath)
        return fm.isWritableFile(atPath: fullPath)
    }

    func getFileModificationDate(atRelativePath relativePath: String) async throws -> Date {
        let lookupState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentModificationDateLookup,
            EditFlowPerf.Dimensions(rootToken: diagnosticRootToken.uuidString)
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentModificationDateLookup, lookupState) }
        let fullPath = fullPath(forRelativePath: relativePath)
        let attributes = try fm.attributesOfItem(atPath: fullPath)
        return attributes[.modificationDate] as? Date ?? Date()
    }

    func getItemModificationDateIfAvailable(atRelativePath relativePath: String) async -> Date? {
        let fullPath = fullPath(forRelativePath: relativePath)
        guard let attributes = try? fm.attributesOfItem(atPath: fullPath) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func writeFile(
        to url: URL,
        data: Data
    ) throws {
        try data.write(to: url, options: .atomic) // blocking write
    }

    /// Robust write that works across external/network volumes:
    /// 1) try atomic write
    /// 2) write to temp in the same directory then move into place (delete destination if needed)
    /// 3) POSIX open(O_CREAT|O_TRUNC)+write+fsync fallback
    private static func writeFileRobust(
        to url: URL,
        data: Data
    ) throws {
        // Fast path: try Foundation's atomic write first.
        do {
            try data.write(to: url, options: [.atomic])
            return
        } catch {
            // fall through to robust fallbacks
        }

        let fm = FileManager.default
        let dirURL = url.deletingLastPathComponent()
        let tmpURL = dirURL.appendingPathComponent(".repoprompt.tmp.\(UUID().uuidString)")

        // Fallback #1: write to temp in the same directory then move/replace.
        do {
            try data.write(to: tmpURL, options: [])
            if fm.fileExists(atPath: url.path) {
                // Removing the destination first avoids exchange/rename restrictions on some filesystems
                // (exFAT/SMB may reject replace semantics).
                try? fm.removeItem(at: url)
            }
            try fm.moveItem(at: tmpURL, to: url)
            return
        } catch {
            // Clean up temp if it remains
            try? fm.removeItem(at: tmpURL)
        }

        // Fallback #2: POSIX open/write/fsync.
        try writeFilePOSIX(to: url, data: data)
    }

    /// Low-level write that avoids Foundation's atomic/replace semantics entirely.
    private static func writeFilePOSIX(
        to url: URL,
        data: Data
    ) throws {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd == -1 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "open() failed for \(path) (\(code))"]
            )
        }

        var writeError: Int32 = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard var base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = data.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n < 0 {
                    writeError = errno
                    break
                }
                remaining -= n
                base = base.advanced(by: n)
            }
        }

        if writeError == 0 {
            if fsync(fd) != 0 {
                writeError = errno
            }
        }

        // Always attempt to close; prefer first error if any.
        let closeResult = close(fd)
        if writeError != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(writeError),
                userInfo: [NSLocalizedDescriptionKey: "write/fsync failed for \(path) (\(writeError))"]
            )
        }
        if closeResult != 0 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "close() failed for \(path) (\(code))"]
            )
        }
    }
}
