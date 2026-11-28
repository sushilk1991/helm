import Darwin
import Foundation
import HelmCore
import os

public actor SeatbeltSandboxRunner: SandboxExecutor {
    private let activePidsLock = OSAllocatedUnfairLock<[UUID: Set<pid_t>]>(initialState: [:])

    public init() {}

    internal func activePidCount(for projectID: UUID) -> Int {
        activePidsLock.withLock { $0[projectID]?.count ?? 0 }
    }

    public func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        let trimmedCmd = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCmd.isEmpty else {
            throw HelmIsolationError.emptyCommand
        }

        let canonicalWorkspace = try Self.resolveCanonicalWorkspace(request.workspacePath)
        let profile = Self.buildSBPLProfile(canonicalWorkspacePath: canonicalWorkspace)
        let env = Self.buildSanitizedEnvironment(
            canonicalWorkspacePath: canonicalWorkspace,
            callerEnvironment: request.environment
        )
        let timeoutSeconds = max(0.05, request.timeoutSeconds)
        let maxOutputBytes = max(0, request.maxOutputBytes)

        let startNs = DispatchTime.now().uptimeNanoseconds

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/zsh", "-f", "-o", "nobgnice", "-c", request.command]
        process.currentDirectoryURL = URL(fileURLWithPath: canonicalWorkspace, isDirectory: true)
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outputState = OSAllocatedUnfairLock(initialState: BoundedOutputState(limit: maxOutputBytes))
        let stdoutCollector = BoundedPipeCollector(pipe: stdoutPipe, isStdout: true, state: outputState)
        let stderrCollector = BoundedPipeCollector(pipe: stderrPipe, isStdout: false, state: outputState)
        let timedOutFlag = OSAllocatedUnfairLock(initialState: false)
        struct PidLifecycleState: Sendable {
            var pid: pid_t = 0
            var didTerminate = false
        }
        let pidState = OSAllocatedUnfairLock(initialState: PidLifecycleState())

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = OSAllocatedUnfairLock(initialState: false)

                process.terminationHandler = { [activePidsLock] proc in
                    let pidToReap = pidState.withLock { st -> pid_t in
                        st.didTerminate = true
                        let p = st.pid
                        if p > 0 {
                            activePidsLock.withLock { map in
                                map[request.projectID]?.remove(p)
                                if map[request.projectID]?.isEmpty == true {
                                    map.removeValue(forKey: request.projectID)
                                }
                            }
                        }
                        return p
                    }
                    if pidToReap > 0 {
                        Self.reapProcessGroup(pid: pidToReap)
                    }
                    stdoutCollector.finish()
                    stderrCollector.finish()

                    let already = completed.withLock { done -> Bool in
                        if done { return true }
                        done = true
                        return false
                    }
                    guard !already else { return }

                    let endNs = DispatchTime.now().uptimeNanoseconds
                    let durationMs = Double(endNs &- startNs) / 1_000_000.0
                    let didTimeout = timedOutFlag.withLock { $0 }
                    let snapshot = outputState.withLock { $0 }

                    let (stdoutStr, outPostTruncated) = Self.decodeUTF8Bounded(snapshot.stdout, maxUTF8Bytes: maxOutputBytes)
                    let remainingErrBudget = max(0, maxOutputBytes - stdoutStr.utf8.count)
                    let (stderrStr, errPostTruncated) = Self.decodeUTF8Bounded(snapshot.stderr, maxUTF8Bytes: remainingErrBudget)
                    let didTruncate = snapshot.truncated || outPostTruncated || errPostTruncated

                    continuation.resume(returning: ExecutionResult(
                        requestID: request.id,
                        modeUsed: .seatbeltSandbox,
                        exitCode: proc.terminationStatus,
                        stdout: stdoutStr,
                        stderr: stderrStr,
                        timedOut: didTimeout,
                        truncatedOutput: didTruncate,
                        durationMs: durationMs
                    ))
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
                        continuation.resume(throwing: HelmIsolationError.seatbeltFailed(error.localizedDescription))
                    }
                    return
                }

                let pid = process.processIdentifier
                if pid > 0 {
                    _ = setpgid(pid, pid)
                    let alreadyTerminated = pidState.withLock { st -> Bool in
                        st.pid = pid
                        if st.didTerminate {
                            return true
                        }
                        activePidsLock.withLock { map in
                            _ = map[request.projectID, default: []].insert(pid)
                        }
                        return false
                    }
                    if alreadyTerminated {
                        Self.reapProcessGroup(pid: pid)
                    }
                }

                let deadline = DispatchTime.now() + timeoutSeconds
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                    guard process.isRunning else { return }
                    timedOutFlag.withLock { $0 = true }
                    Self.terminateProcessTree(process, pid: pid)
                }
            }
        } onCancel: {
            let pid = pidState.withLock { $0.pid }
            Self.terminateProcessTree(process, pid: pid)
        }
    }

    public func shutdownWorkspace(_ projectID: UUID) async {
        let pids = activePidsLock.withLock { map in
            map.removeValue(forKey: projectID) ?? []
        }
        for pid in pids where pid > 0 {
            Self.reapProcessGroup(pid: pid)
        }
    }

    public func shutdownAll() async {
        let allPIDs: [pid_t] = activePidsLock.withLock { map in
            let list = map.values.flatMap { $0 }
            map.removeAll()
            return list
        }
        for pid in allPIDs where pid > 0 {
            Self.reapProcessGroup(pid: pid)
        }
    }

    // MARK: - Canonical Path & SBPL

    public static func resolveCanonicalWorkspace(_ url: URL) throws -> String {
        guard url.isFileURL else {
            throw HelmIsolationError.invalidWorkspace("Workspace URL must be a file URL: \(url.absoluteString)")
        }
        let rawPath = url.path
        guard !rawPath.isEmpty, !rawPath.contains("\0") else {
            throw HelmIsolationError.invalidWorkspace("Workspace path is empty or invalid.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDir), isDir.boolValue else {
            throw HelmIsolationError.invalidWorkspace("Workspace directory does not exist: \(rawPath)")
        }

        guard let resolvedCString = Darwin.realpath(rawPath, nil) else {
            let err = String(cString: strerror(errno))
            throw HelmIsolationError.invalidWorkspace("Unable to canonicalize '\(rawPath)': \(err)")
        }
        defer { Darwin.free(resolvedCString) }
        let canonical = String(cString: resolvedCString)

        var canonicalIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &canonicalIsDir),
              canonicalIsDir.boolValue else {
            throw HelmIsolationError.invalidWorkspace("Resolved workspace is not a directory: \(canonical)")
        }
        return canonical
    }

    public static func buildSBPLProfile(canonicalWorkspacePath: String) -> String {
        let ws = escapeSBPLString(canonicalWorkspacePath)
        let home = NSHomeDirectory()
        let canonicalHome: String
        if let ptr = Darwin.realpath(home, nil) {
            canonicalHome = String(cString: ptr)
            Darwin.free(ptr)
        } else {
            canonicalHome = home
        }

        var denySubpaths: [String] = []
        for h in Set([home, canonicalHome]) {
            for rel in [".ssh", ".aws", ".gnupg", "Library/Keychains"] {
                denySubpaths.append(escapeSBPLString((h as NSString).appendingPathComponent(rel)))
            }
        }
        let denyClause = denySubpaths
            .sorted()
            .map { "(subpath \"\($0)\")" }
            .joined(separator: " ")

        return """
        (version 1)
        (deny default)
        (allow process-exec process-fork)
        (allow sysctl-read)
        (allow mach-lookup)
        (allow signal (target self))
        (allow signal (target children))
        (allow file-read-metadata)
        (allow file-read*
            (literal "/")
            (subpath "/bin")
            (subpath "/usr/bin")
            (subpath "/usr/lib")
            (subpath "/usr/share")
            (subpath "/System")
            (subpath "/Library/Preferences")
            (subpath "/private/var/db/dyld")
            (subpath "/dev")
            (subpath "\(ws)"))
        (deny file-read* \(denyClause))
        (allow file-write*
            (subpath "\(ws)")
            (literal "/dev/null")
            (literal "/dev/zero")
            (literal "/dev/dtracehelper"))
        """
    }

    private static func escapeSBPLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func buildSanitizedEnvironment(
        canonicalWorkspacePath: String,
        callerEnvironment: [String: String]
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/bin:/usr/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": canonicalWorkspacePath,
            "LANG": "en_US.UTF-8",
        ]
        for (k, v) in callerEnvironment {
            env[k] = v
        }
        return env
    }

    // MARK: - Process Tree Reaping & UTF-8 Decoding

    private static func terminateProcessTree(_ process: Process, pid: pid_t) {
        let effectivePid = pid > 0 ? pid : process.processIdentifier
        guard effectivePid > 0 else { return }
        _ = kill(-effectivePid, SIGTERM)
        _ = kill(effectivePid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
            if process.isRunning || kill(-effectivePid, 0) == 0 {
                _ = kill(-effectivePid, SIGKILL)
                _ = kill(effectivePid, SIGKILL)
            }
        }
    }

    private static func reapProcessGroup(pid: pid_t) {
        guard pid > 0 else { return }
        // Fast path: if no processes exist in pgid, nothing to reap.
        if kill(-pid, 0) != 0 && errno == ESRCH {
            return
        }
        _ = kill(-pid, SIGTERM)
        for _ in 0..<5 {
            if kill(-pid, 0) != 0 && errno == ESRCH {
                return
            }
            usleep(10_000)
        }
        _ = kill(-pid, SIGKILL)
    }

    public static func decodeUTF8Safely(_ data: Data, maxUTF8Bytes: Int? = nil) -> String {
        if let maxUTF8Bytes {
            return decodeUTF8Bounded(data, maxUTF8Bytes: maxUTF8Bytes).text
        }
        return decodeUTF8Unbounded(data)
    }

    public static func decodeUTF8Bounded(_ data: Data, maxUTF8Bytes: Int) -> (text: String, truncated: Bool) {
        let limit = max(0, maxUTF8Bytes)
        let decoded = decodeUTF8Unbounded(data)
        if decoded.utf8.count <= limit {
            return (decoded, false)
        }
        guard limit > 0 else {
            return ("", !decoded.isEmpty)
        }
        var bounded = ""
        bounded.unicodeScalars.reserveCapacity(min(decoded.unicodeScalars.count, limit))
        var usedBytes = 0
        for scalar in decoded.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            if usedBytes + scalarBytes > limit {
                break
            }
            bounded.unicodeScalars.append(scalar)
            usedBytes += scalarBytes
        }
        return (bounded, true)
    }

    private static func decodeUTF8Unbounded(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let exact = String(data: data, encoding: .utf8) {
            return exact
        }
        // Trim up to 3 trailing bytes if a multi-byte UTF-8 character was cut at maxOutputBytes.
        let maxTrim = min(3, data.count)
        for trim in 1...maxTrim {
            let prefix = data.prefix(data.count - trim)
            if let valid = String(data: prefix, encoding: .utf8) {
                return valid
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct BoundedOutputState: Sendable {
    var stdout = Data()
    var stderr = Data()
    var totalBytes = 0
    var truncated = false
    let limit: Int
}

private final class BoundedPipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let eofSemaphore = DispatchSemaphore(value: 0)
    private let didSignal = OSAllocatedUnfairLock(initialState: false)

    init(pipe: Pipe, isStdout: Bool, state: OSAllocatedUnfairLock<BoundedOutputState>) {
        self.handle = pipe.fileHandleForReading
        self.handle.readabilityHandler = { [eofSemaphore, didSignal] fileHandle in
            let chunk = fileHandle.availableData
            if !chunk.isEmpty {
                state.withLock { buf in
                    let remaining = max(0, buf.limit - buf.totalBytes)
                    if chunk.count <= remaining {
                        if isStdout {
                            buf.stdout.append(chunk)
                        } else {
                            buf.stderr.append(chunk)
                        }
                        buf.totalBytes += chunk.count
                    } else {
                        if remaining > 0 {
                            let slice = chunk.prefix(remaining)
                            if isStdout {
                                buf.stdout.append(slice)
                            } else {
                                buf.stderr.append(slice)
                            }
                            buf.totalBytes += remaining
                        }
                        buf.truncated = true
                    }
                }
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
}
