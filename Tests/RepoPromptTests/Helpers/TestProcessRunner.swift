import Foundation
#if os(macOS)
import Darwin
#endif

struct TestProcessResult {
    let terminationStatus: Int32
    let output: Data

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }
}

struct TestProcessTimeoutError: Error, LocalizedError, CustomStringConvertible {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let timeout: TimeInterval
    let output: Data

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }

    var errorDescription: String? {
        description
    }

    var description: String {
        var parts = [
            "Process timed out after \(String(format: "%.3f", timeout))s:",
            ([executableURL.path] + arguments).joined(separator: " ")
        ]
        if let currentDirectoryURL {
            parts.append("cwd: \(currentDirectoryURL.path)")
        }
        if !output.isEmpty {
            parts.append("captured output:\n\(outputText)")
        }
        return parts.joined(separator: "\n")
    }
}

enum TestProcessRunner {
    static let defaultTimeout: TimeInterval = 30
    private static let terminationGraceInterval: TimeInterval = 1
    private static let outputDrainGraceInterval: TimeInterval = 1

    static func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> TestProcessResult {
        precondition(timeout > 0, "TestProcessRunner timeout must be positive")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let capturedOutput = LockedOutput()
        let readerGroup = DispatchGroup()
        let outputReader = output.fileHandleForReading
        readerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readerGroup.leave() }
            while true {
                guard let chunk = try? outputReader.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                capturedOutput.append(chunk)
            }
        }

        let terminationGroup = DispatchGroup()
        terminationGroup.enter()
        process.terminationHandler = { _ in
            terminationGroup.leave()
        }

        do {
            try process.run()
        } catch {
            close(output.fileHandleForReading)
            close(output.fileHandleForWriting)
            readerGroup.wait()
            throw error
        }

        close(output.fileHandleForWriting)

        if terminationGroup.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process)
            if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                forceTerminate(process)
                _ = terminationGroup.wait(timeout: .now() + terminationGraceInterval)
            }

            finishReadingAfterTimeout(output.fileHandleForReading, readerGroup: readerGroup)
            throw TestProcessTimeoutError(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                timeout: timeout,
                output: capturedOutput.data()
            )
        }

        finishReadingAfterSuccess(output.fileHandleForReading, readerGroup: readerGroup)

        return TestProcessResult(
            terminationStatus: process.terminationStatus,
            output: capturedOutput.data()
        )
    }

    private static func terminate(_ process: Process) {
        #if os(macOS)
        signal(process, SIGTERM)
        #endif
        if process.isRunning {
            process.terminate()
        }
    }

    private static func forceTerminate(_ process: Process) {
        #if os(macOS)
        signal(process, SIGKILL)
        #endif
    }

    private static func close(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            handle.closeFile()
        }
    }

    private static func finishReadingAfterSuccess(_ handle: FileHandle, readerGroup: DispatchGroup) {
        readerGroup.wait()
        close(handle)
    }

    private static func finishReadingAfterTimeout(_ handle: FileHandle, readerGroup: DispatchGroup) {
        if readerGroup.wait(timeout: .now() + outputDrainGraceInterval) == .timedOut {
            close(handle)
            _ = readerGroup.wait(timeout: .now() + outputDrainGraceInterval)
        } else {
            close(handle)
        }
    }

    #if os(macOS)
    private static func signal(_ process: Process, _ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        signalProcessTree(rootPID: pid, signal)
    }

    private static func signalProcessTree(rootPID: pid_t, _ signal: Int32) {
        for childPID in childPIDs(of: rootPID) {
            signalProcessTree(rootPID: childPID, signal)
        }
        _ = Darwin.kill(rootPID, signal)
    }

    private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(parentPID)"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            close(output.fileHandleForReading)
            close(output.fileHandleForWriting)
            return []
        }
        close(output.fileHandleForWriting)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        close(output.fileHandleForReading)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    #endif
}

private final class LockedOutput {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
