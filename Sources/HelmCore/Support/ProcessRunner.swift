import Darwin
import Foundation
import os

public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let timedOut: Bool

    public var stdout: String {
        String(data: stdoutData, encoding: .utf8) ?? ""
    }

    public var stderr: String {
        String(data: stderrData, encoding: .utf8) ?? ""
    }
}

public enum ProcessRunnerError: Error, Sendable, LocalizedError {
    case launchFailed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "Failed to launch process: \(msg)"
        case .timedOut(let seconds): return "Process timed out after \(seconds)s"
        }
    }
}

public enum ProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeoutSeconds: TimeInterval = 60
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            #if canImport(Darwin)
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            #endif
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let timedOutFlag = OSAllocatedUnfairLock(initialState: false)
        let stdoutCollector = PipeCollector(pipe: stdoutPipe)
        let stderrCollector = PipeCollector(pipe: stderrPipe)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = OSAllocatedUnfairLock(initialState: false)

                process.terminationHandler = { proc in
                    stdoutCollector.finish()
                    stderrCollector.finish()
                    let already = completed.withLock { done -> Bool in
                        if done { return true }
                        done = true
                        return false
                    }
                    guard !already else { return }
                    let didTimeout = timedOutFlag.withLock { $0 }
                    if didTimeout {
                        continuation.resume(throwing: ProcessRunnerError.timedOut(timeoutSeconds))
                    } else {
                        continuation.resume(returning: ProcessOutput(
                            exitCode: proc.terminationStatus,
                            stdoutData: stdoutCollector.data(),
                            stderrData: stderrCollector.data(),
                            timedOut: false
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    stdoutCollector.finish()
                    stderrCollector.finish()
                    let already = completed.withLock { done -> Bool in
                        if done { return true }
                        done = true
                        return false
                    }
                    if !already {
                        continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    }
                    return
                }

                let pid = process.processIdentifier
                if pid > 0 {
                    _ = setpgid(pid, pid)
                }

                if let stdinPipe, let stdinData {
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }

                if timeoutSeconds > 0 {
                    let deadline = DispatchTime.now() + timeoutSeconds
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                        guard process.isRunning else { return }
                        timedOutFlag.withLock { $0 = true }
                        terminateProcessTree(process)
                    }
                }
            }
        } onCancel: {
            terminateProcessTree(process)
        }
    }

    private static func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            if process.isRunning {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
        }
    }
}

private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let buffer = OSAllocatedUnfairLock(initialState: Data())
    private let eofSemaphore = DispatchSemaphore(value: 0)
    private let didSignal = OSAllocatedUnfairLock(initialState: false)

    init(pipe: Pipe) {
        self.handle = pipe.fileHandleForReading
        self.handle.readabilityHandler = { [buffer, eofSemaphore, didSignal] fileHandle in
            let chunk = fileHandle.availableData
            if !chunk.isEmpty {
                buffer.withLock { $0.append(chunk) }
            } else {
                fileHandle.readabilityHandler = nil
                let shouldSignal = didSignal.withLock { signaled -> Bool in
                    if signaled { return false }
                    signaled = true
                    return true
                }
                if shouldSignal {
                    eofSemaphore.signal()
                }
            }
        }
    }

    func finish() {
        _ = eofSemaphore.wait(timeout: .now() + 0.15)
        handle.readabilityHandler = nil
        let shouldSignal = didSignal.withLock { signaled -> Bool in
            if signaled { return false }
            signaled = true
            return true
        }
        if shouldSignal {
            eofSemaphore.signal()
        }
    }

    func data() -> Data {
        buffer.withLock { $0 }
    }
}
