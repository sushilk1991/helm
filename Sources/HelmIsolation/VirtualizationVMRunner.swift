import Darwin
import Foundation
import HelmCore
import Virtualization
import os

public actor VirtualizationVMRunner: SandboxExecutor {
    private let imageCache: AlpineImageCache
    private var boxes: [UUID: VMProjectEntry] = [:]
    private var inFlightBoots: [UUID: InFlightBoot] = [:]
    private var shutdownEpochs: [UUID: UInt64] = [:]

    public init(imageCache: AlpineImageCache = AlpineImageCache()) {
        self.imageCache = imageCache
    }

    public func hasLocalAssets() async -> Bool {
        await imageCache.hasLocalAssets()
    }

    public func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        let trimmedCmd = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCmd.isEmpty else {
            throw HelmIsolationError.emptyCommand
        }

        guard EntitlementChecker.isVirtualizationSupported() else {
            throw HelmIsolationError.virtualizationUnsupported
        }
        guard EntitlementChecker.hasVirtualizationEntitlement() else {
            throw HelmIsolationError.missingEntitlement
        }

        let initialEpoch = shutdownEpochs[request.projectID, default: 0]

        let canonicalWorkspace = try SeatbeltSandboxRunner.resolveCanonicalWorkspace(request.workspacePath)
        let workspaceURL = URL(fileURLWithPath: canonicalWorkspace, isDirectory: true)

        let initData = Data(Self.helmInitScript.utf8)
        let assets = try await imageCache.ensureAssets(initScriptData: initData, allowDownload: true)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            if shutdownEpochs[request.projectID, default: 0] != initialEpoch {
                throw HelmIsolationError.vmStoppedUnexpectedly("Workspace VM was shut down.")
            }

            let box = try await acquireOrBootBox(
                projectID: request.projectID,
                workspaceURL: workspaceURL,
                assets: assets
            )

            let locked = await box.lockRPCIfAlive()
            if !locked {
                try Task.checkCancellation()
                if shutdownEpochs[request.projectID, default: 0] != initialEpoch {
                    throw HelmIsolationError.vmStoppedUnexpectedly("Workspace VM was shut down.")
                }
                await evictBox(projectID: request.projectID, box: box)
                attempt += 1
                if attempt <= 1 {
                    continue
                }
                throw HelmIsolationError.vmStoppedUnexpectedly("VM stopped before RPC lock could be acquired.")
            }

            do {
                let result = try await runRPCCommand(box: box, request: request)
                await box.unlockRPC(markDead: false)
                return result
            } catch {
                let shouldEvict: Bool
                switch error {
                case HelmIsolationError.rpcTimeout,
                     HelmIsolationError.vmStoppedUnexpectedly,
                     HelmIsolationError.rpcProtocolError,
                     is CancellationError:
                    shouldEvict = true
                default:
                    shouldEvict = false
                }
                await box.unlockRPC(markDead: shouldEvict)
                if shouldEvict {
                    await evictBox(projectID: request.projectID, box: box)
                }
                throw error
            }
        }
    }

    public func shutdownWorkspace(_ projectID: UUID) async {
        shutdownEpochs[projectID, default: 0] &+= 1
        let entry = boxes.removeValue(forKey: projectID)
        let boot = inFlightBoots.removeValue(forKey: projectID)
        boot?.task.cancel()
        if let entry {
            await entry.box.shutdownGracefully()
        }
        if let boot {
            if let box = try? await boot.task.value {
                await box.shutdownGracefully()
            }
        }
    }

    public func shutdownAll() async {
        let projectIDs = Set(boxes.keys).union(inFlightBoots.keys)
        guard !projectIDs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in projectIDs {
                group.addTask {
                    await self.shutdownWorkspace(id)
                }
            }
        }
    }

    // MARK: - VM Lifecycle

    private func acquireOrBootBox(
        projectID: UUID,
        workspaceURL: URL,
        assets: ResolvedVMAssets
    ) async throws -> VMBox {
        while true {
            try Task.checkCancellation()

            if let existing = boxes[projectID] {
                if existing.workspacePath == workspaceURL.path && existing.box.isAlive {
                    return existing.box
                }
                boxes.removeValue(forKey: projectID)
                await existing.box.shutdownGracefully()
                continue
            }

            if let inFlight = inFlightBoots[projectID] {
                if inFlight.workspacePath == workspaceURL.path {
                    return try await inFlight.task.value
                } else {
                    inFlightBoots.removeValue(forKey: projectID)
                    inFlight.task.cancel()
                    if let oldBox = try? await inFlight.task.value {
                        await oldBox.shutdownGracefully()
                    }
                    continue
                }
            }

            let bootID = UUID()
            let task = Task<VMBox, Error> {
                let box = try VMBox(
                    projectID: projectID,
                    workspaceURL: workspaceURL,
                    assets: assets
                )
                do {
                    try Task.checkCancellation()
                    try await withTaskCancellationHandler {
                        try await box.startAndAwaitReady(timeoutSeconds: 20.0)
                    } onCancel: {
                        Task { await box.forceStop() }
                    }
                    try Task.checkCancellation()
                    return try self.commitBootedBox(
                        bootID: bootID,
                        projectID: projectID,
                        workspacePath: workspaceURL.path,
                        box: box
                    )
                } catch {
                    self.failBoot(bootID: bootID, projectID: projectID)
                    await box.forceStop()
                    throw error
                }
            }
            inFlightBoots[projectID] = InFlightBoot(id: bootID, workspacePath: workspaceURL.path, task: task)
            return try await task.value
        }
    }

    private func commitBootedBox(
        bootID: UUID,
        projectID: UUID,
        workspacePath: String,
        box: VMBox
    ) throws -> VMBox {
        guard inFlightBoots[projectID]?.id == bootID else {
            throw HelmIsolationError.vmStoppedUnexpectedly("Workspace VM was shut down or superseded during boot.")
        }
        inFlightBoots.removeValue(forKey: projectID)
        guard box.isAlive else {
            throw HelmIsolationError.vmStoppedUnexpectedly("VM stopped during boot.")
        }
        boxes[projectID] = VMProjectEntry(workspacePath: workspacePath, box: box)
        return box
    }

    private func failBoot(bootID: UUID, projectID: UUID) {
        if inFlightBoots[projectID]?.id == bootID {
            inFlightBoots.removeValue(forKey: projectID)
        }
    }

    private func evictBox(projectID: UUID, box: VMBox) async {
        if boxes[projectID]?.box === box {
            boxes.removeValue(forKey: projectID)
        }
        await box.forceStop()
    }

    private func runRPCCommand(box: VMBox, request: ExecutionRequest) async throws -> ExecutionResult {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let timeoutSec = max(0.1, request.timeoutSeconds)
        let maxBytes = max(0, request.maxOutputBytes)

        let envScript = Self.buildGuestEnvScript(callerEnvironment: request.environment)
        let envB64 = envScript.isEmpty ? "-" : Data(envScript.utf8).base64EncodedString()
        let cmdB64 = Data(request.command.utf8).base64EncodedString()
        let timeoutStr = String(format: "%.3f", timeoutSec)
        let reqID = request.id.uuidString

        let frame = "EXEC \(reqID) \(timeoutStr) \(maxBytes) \(envB64) \(cmdB64)\n"
        let responseLine = try await box.sendCommandAndAwaitResponse(
            frame: frame,
            expectedRequestID: reqID,
            safetyTimeoutSeconds: timeoutSec + 5.0
        )

        let endNs = DispatchTime.now().uptimeNanoseconds
        let durationMs = Double(endNs &- startNs) / 1_000_000.0

        // Format: RES <id> <ec> <timed_out> <trunc> <stdout_b64> <stderr_b64>
        let parts = responseLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 7, parts[0] == "RES", parts[1] == reqID else {
            throw HelmIsolationError.rpcProtocolError("Malformed guest response: \(responseLine)")
        }

        let exitCode = Int32(parts[2]) ?? -1
        let timedOut = parts[3] == "1"
        let truncated = parts[4] == "1"

        let stdoutData = parts[5] == "-" ? Data() : (Data(base64Encoded: parts[5]) ?? Data())
        let stderrData = parts[6] == "-" ? Data() : (Data(base64Encoded: parts[6]) ?? Data())

        let (stdoutStr, outPostTruncated) = SeatbeltSandboxRunner.decodeUTF8Bounded(stdoutData, maxUTF8Bytes: maxBytes)
        let remainingErrBudget = max(0, maxBytes - stdoutStr.utf8.count)
        let (stderrStr, errPostTruncated) = SeatbeltSandboxRunner.decodeUTF8Bounded(stderrData, maxUTF8Bytes: remainingErrBudget)
        let finalTruncated = truncated || outPostTruncated || errPostTruncated

        return ExecutionResult(
            requestID: request.id,
            modeUsed: .virtualizationVM,
            exitCode: exitCode,
            stdout: stdoutStr,
            stderr: stderrStr,
            timedOut: timedOut,
            truncatedOutput: finalTruncated,
            durationMs: durationMs
        )
    }

    private static func buildGuestEnvScript(callerEnvironment: [String: String]) -> String {
        var env: [String: String] = [
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/workspace",
            "TMPDIR": "/tmp",
            "LANG": "C.UTF-8",
        ]
        for (k, v) in callerEnvironment {
            guard isValidPOSIXEnvKey(k) else { continue }
            env[k] = v
        }
        return env.keys.sorted().map { key in
            let val = env[key] ?? ""
            let escaped = val.replacingOccurrences(of: "'", with: "'\\''")
            return "export \(key)='\(escaped)'"
        }.joined(separator: "\n") + "\n"
    }

    private static func isValidPOSIXEnvKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let isAlphaOrUnderscore = (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") || first == "_"
        guard isAlphaOrUnderscore else { return false }
        return key.unicodeScalars.allSatisfy { sc in
            (sc >= "A" && sc <= "Z") || (sc >= "a" && sc <= "z") || (sc >= "0" && sc <= "9") || sc == "_"
        }
    }

    // MARK: - Guest /helm-init Script

    public static let helmInitScript: String = """
    #!/bin/sh
    /bin/busybox mkdir -p /proc /sys /dev /tmp /workspace /usr/sbin /usr/bin /sbin /bin
    /bin/busybox --install -s
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    modprobe virtiofs >/dev/null 2>&1 || true
    if ! mount -t virtiofs workspace /workspace >/dev/null 2>&1; then
      echo "HELM_INIT_ERROR: failed to mount virtiofs workspace" > /dev/hvc0
      poweroff -f
      exit 1
    fi
    cd /workspace || exit 1

    RPC=""
    i=0
    while [ "$i" -lt 400 ]; do
      for p in /sys/class/virtio-ports/*/name; do
        if [ -r "$p" ] && [ "$(cat "$p" 2>/dev/null)" = "helm-rpc" ]; then
          dev="/dev/$(basename "$(dirname "$p")")"
          if [ -c "$dev" ]; then
            RPC="$dev"
            break 2
          fi
        fi
      done
      sleep 0.01
      i=$((i + 1))
    done

    if [ -z "$RPC" ]; then
      echo "HELM_INIT_ERROR: helm-rpc virtio port not found" > /dev/hvc0
      poweroff -f
      exit 1
    fi

    exec 3<>"$RPC"
    printf 'READY\\n' >&3

    while IFS= read -r line <&3; do
      case "$line" in
        SHUTDOWN)
          printf 'BYE\\n' >&3
          sync
          poweroff -f
          exit 0
          ;;
        EXEC\\ *)
          set -- $line
          req_id="$2"
          timeout_s="$3"
          max_bytes="$4"
          env_b64="$5"
          cmd_b64="$6"

          work="/tmp/helm_$req_id"
          mkdir -p "$work"
          env_f="$work/env.sh"
          cmd_f="$work/cmd.sh"
          out_f="$work/out"
          err_f="$work/err"

          if [ "$env_b64" != "-" ]; then
            printf '%s' "$env_b64" | base64 -d > "$env_f"
          else
            : > "$env_f"
          fi
          printf '%s' "$cmd_b64" | base64 -d > "$cmd_f"

          timed_out=0
          setsid /bin/sh -c '. "$1"; cd /workspace && exec /bin/sh "$2"' _ "$env_f" "$cmd_f" >"$out_f" 2>"$err_f" &
          child_pid=$!

          killer_flag="$work/timed_out"
          (
            sleep "$timeout_s"
            if kill -0 "$child_pid" 2>/dev/null; then
              : > "$killer_flag"
              kill -TERM -"$child_pid" 2>/dev/null || true
              sleep 0.15
              kill -KILL -"$child_pid" 2>/dev/null || true
            fi
          ) &
          killer_pid=$!

          wait "$child_pid"
          ec=$?
          kill "$killer_pid" 2>/dev/null || true
          wait "$killer_pid" 2>/dev/null || true

          if [ -e "$killer_flag" ]; then
            timed_out=1
            ec=124
          fi

          trunc=0
          out_sz=$(wc -c < "$out_f")
          err_sz=$(wc -c < "$err_f")
          if [ "$max_bytes" -gt 0 ] 2>/dev/null; then
            total_sz=$((out_sz + err_sz))
            if [ "$total_sz" -gt "$max_bytes" ]; then
              trunc=1
              rem="$max_bytes"
              if [ "$out_sz" -gt "$rem" ]; then
                dd if="$out_f" of="$out_f.t" bs=4096 count=$((rem / 4096)) 2>/dev/null || true
                rem_tail=$((rem % 4096))
                if [ "$rem_tail" -gt 0 ]; then
                  dd if="$out_f" of="$out_f.t" bs=1 skip=$(( (rem / 4096) * 4096 )) seek=$(( (rem / 4096) * 4096 )) count="$rem_tail" conv=notrunc 2>/dev/null || true
                fi
                mv "$out_f.t" "$out_f"
                : > "$err_f"
              else
                rem=$((rem - out_sz))
                dd if="$err_f" of="$err_f.t" bs=4096 count=$((rem / 4096)) 2>/dev/null || true
                rem_tail=$((rem % 4096))
                if [ "$rem_tail" -gt 0 ]; then
                  dd if="$err_f" of="$err_f.t" bs=1 skip=$(( (rem / 4096) * 4096 )) seek=$(( (rem / 4096) * 4096 )) count="$rem_tail" conv=notrunc 2>/dev/null || true
                fi
                mv "$err_f.t" "$err_f"
              fi
            fi
          elif [ "$max_bytes" -eq 0 ] 2>/dev/null; then
            if [ "$out_sz" -gt 0 ] || [ "$err_sz" -gt 0 ]; then
              trunc=1
            fi
            : > "$out_f"
            : > "$err_f"
          fi

          out_b64=$(base64 < "$out_f" | tr -d '\\n')
          err_b64=$(base64 < "$err_f" | tr -d '\\n')
          [ -n "$out_b64" ] || out_b64="-"
          [ -n "$err_b64" ] || err_b64="-"

          printf 'RES %s %s %s %s %s %s\\n' "$req_id" "$ec" "$timed_out" "$trunc" "$out_b64" "$err_b64" >&3
          rm -rf "$work"
          ;;
      esac
    done
    """
}

private struct VMProjectEntry {
    let workspacePath: String
    let box: VMBox
}

private struct InFlightBoot {
    let id: UUID
    let workspacePath: String
    let task: Task<VMBox, Error>
}

internal final class VMChannelState: @unchecked Sendable {
    private struct RuntimeState {
        var isStopped = false
        var isMarkedDead = false
        var isStopRequested = false
        var stopReason: String?
        var consoleTail = Data()
        var bufferedLines: [String] = []
        var lineWaiter: CheckedContinuation<String, Error>?
        var activeLineWaiterToken: UInt64 = 0
        var nextLineWaiterToken: UInt64 = 0
        var pendingLineWaiterTokens: Set<UInt64> = []
        var rpcBusy = false
        var pendingRPCLockWaiterIDs: Set<UUID> = []
        var rpcLockWaiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: RuntimeState())
    private let timeoutQueue: DispatchQueue

    init(timeoutQueue: DispatchQueue = DispatchQueue(label: "com.helm.vm.channel.timeout")) {
        self.timeoutQueue = timeoutQueue
    }

    var isAlive: Bool {
        state.withLock { !$0.isStopped && !$0.isMarkedDead && !$0.isStopRequested }
    }

    var isStopRequested: Bool {
        state.withLock { $0.isStopRequested }
    }

    func appendConsoleTail(_ chunk: Data) {
        state.withLock { s in
            s.consoleTail.append(chunk)
            if s.consoleTail.count > 16_384 {
                s.consoleTail = Data(s.consoleTail.suffix(16_384))
            }
        }
    }

    func requestStop() {
        let waitersToFail = state.withLock { s -> [(id: UUID, cont: CheckedContinuation<Bool, Never>)] in
            s.isStopRequested = true
            s.isMarkedDead = true
            let w = s.rpcLockWaiters
            s.rpcLockWaiters.removeAll()
            return w
        }
        for (_, cont) in waitersToFail {
            cont.resume(returning: false)
        }
    }

    func beginGracefulShutdownIfIdle() -> Bool {
        let (shouldSendBye, waitersToFail) = state.withLock { s -> (Bool, [(id: UUID, cont: CheckedContinuation<Bool, Never>)]) in
            s.isMarkedDead = true
            let w = s.rpcLockWaiters
            s.rpcLockWaiters.removeAll()
            let canSend = !s.isStopped && !s.rpcBusy && s.lineWaiter == nil
            if canSend {
                s.rpcBusy = true
            }
            return (canSend, w)
        }
        for (_, cont) in waitersToFail {
            cont.resume(returning: false)
        }
        return shouldSendBye
    }

    func lockRPCIfAlive() async -> Bool {
        if Task.isCancelled { return false }
        let fastResult: Bool? = state.withLock { s in
            if s.isStopped || s.isMarkedDead || s.isStopRequested {
                return false
            }
            if !s.rpcBusy {
                s.rpcBusy = true
                return true
            }
            return nil
        }
        if let fastResult {
            return fastResult
        }

        let waiterID = UUID()
        state.withLock { s in
            _ = s.pendingRPCLockWaiterIDs.insert(waiterID)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let immediate: Bool? = state.withLock { s in
                    if s.pendingRPCLockWaiterIDs.remove(waiterID) == nil {
                        return false
                    }
                    if s.isStopped || s.isMarkedDead || s.isStopRequested {
                        return false
                    }
                    if !s.rpcBusy {
                        s.rpcBusy = true
                        return true
                    }
                    s.rpcLockWaiters.append((id: waiterID, cont: cont))
                    return nil
                }
                if let immediate {
                    cont.resume(returning: immediate)
                }
            }
        } onCancel: {
            let cancelledWaiter = state.withLock { s -> CheckedContinuation<Bool, Never>? in
                if s.pendingRPCLockWaiterIDs.remove(waiterID) != nil {
                    return nil
                }
                if let idx = s.rpcLockWaiters.firstIndex(where: { $0.id == waiterID }) {
                    return s.rpcLockWaiters.remove(at: idx).cont
                }
                return nil
            }
            cancelledWaiter?.resume(returning: false)
        }
    }

    func unlockRPC(markDead: Bool) {
        enum UnlockAction {
            case none
            case wakeNext(CheckedContinuation<Bool, Never>)
            case failAll([(id: UUID, cont: CheckedContinuation<Bool, Never>)])
        }

        let action = state.withLock { s -> UnlockAction in
            if markDead || s.isStopped || s.isMarkedDead || s.isStopRequested {
                s.isMarkedDead = true
                s.rpcBusy = false
                let waiters = s.rpcLockWaiters
                s.rpcLockWaiters.removeAll()
                return waiters.isEmpty ? .none : .failAll(waiters)
            }
            if !s.rpcLockWaiters.isEmpty {
                let next = s.rpcLockWaiters.removeFirst().cont
                return .wakeNext(next)
            }
            s.rpcBusy = false
            return .none
        }

        switch action {
        case .none:
            break
        case .wakeNext(let cont):
            cont.resume(returning: true)
        case .failAll(let waiters):
            for (_, cont) in waiters {
                cont.resume(returning: false)
            }
        }
    }

    func readNextLine(timeoutSeconds: TimeInterval) async throws -> String {
        if Task.isCancelled {
            throw CancellationError()
        }

        let waiterToken: UInt64 = state.withLock { s in
            s.nextLineWaiterToken &+= 1
            if s.nextLineWaiterToken == 0 {
                s.nextLineWaiterToken = 1
            }
            let token = s.nextLineWaiterToken
            s.pendingLineWaiterTokens.insert(token)
            return token
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                enum LookupResult {
                    case immediate(Result<String, Error>)
                    case waiting
                }

                let lookup: LookupResult = state.withLock { s in
                    if s.pendingLineWaiterTokens.remove(waiterToken) == nil {
                        return .immediate(.failure(CancellationError()))
                    }
                    if !s.bufferedLines.isEmpty {
                        return .immediate(.success(s.bufferedLines.removeFirst()))
                    }
                    if s.isStopped {
                        let tail = String(decoding: s.consoleTail, as: UTF8.self)
                        let reason = s.stopReason ?? "VM stopped"
                        let msg = tail.isEmpty ? reason : "\(reason) | console: \(tail)"
                        return .immediate(.failure(HelmIsolationError.vmStoppedUnexpectedly(msg)))
                    }
                    if s.lineWaiter != nil {
                        return .immediate(.failure(
                            HelmIsolationError.rpcProtocolError("Concurrent readNextLine call rejected on VMBox.")
                        ))
                    }
                    s.activeLineWaiterToken = waiterToken
                    s.lineWaiter = cont
                    return .waiting
                }

                switch lookup {
                case .immediate(let result):
                    cont.resume(with: result)
                case .waiting:
                    let deadline = DispatchTime.now() + max(0.1, timeoutSeconds)
                    timeoutQueue.asyncAfter(deadline: deadline) { [weak self] in
                        guard let self else { return }
                        let expired = self.state.withLock { s -> CheckedContinuation<String, Error>? in
                            guard s.activeLineWaiterToken == waiterToken, let w = s.lineWaiter else { return nil }
                            s.lineWaiter = nil
                            s.activeLineWaiterToken = 0
                            return w
                        }
                        expired?.resume(throwing: HelmIsolationError.rpcTimeout)
                    }
                }
            }
        } onCancel: {
            let waiterToCancel = state.withLock { s -> CheckedContinuation<String, Error>? in
                if s.pendingLineWaiterTokens.remove(waiterToken) != nil {
                    return nil
                }
                if s.activeLineWaiterToken == waiterToken, let w = s.lineWaiter {
                    s.lineWaiter = nil
                    s.activeLineWaiterToken = 0
                    return w
                }
                return nil
            }
            waiterToCancel?.resume(throwing: CancellationError())
        }
    }

    func deliverLine(_ line: String) {
        let waiter = state.withLock { s -> CheckedContinuation<String, Error>? in
            if let w = s.lineWaiter {
                s.lineWaiter = nil
                s.activeLineWaiterToken = 0
                return w
            }
            s.bufferedLines.append(line)
            return nil
        }
        waiter?.resume(returning: line)
    }

    func markStopped(reason: String) {
        let (waiter, tail, lockWaiters) = state.withLock {
            s -> (CheckedContinuation<String, Error>?, String, [(id: UUID, cont: CheckedContinuation<Bool, Never>)]) in
            s.isStopped = true
            s.isMarkedDead = true
            if s.stopReason == nil {
                s.stopReason = reason
            }
            let tail = String(decoding: s.consoleTail, as: UTF8.self)
            let w = s.lineWaiter
            s.lineWaiter = nil
            s.activeLineWaiterToken = 0
            let lw = s.rpcLockWaiters
            s.rpcLockWaiters.removeAll()
            return (w, tail, lw)
        }
        let detail = tail.isEmpty ? reason : "\(reason) | console: \(tail)"
        waiter?.resume(throwing: HelmIsolationError.vmStoppedUnexpectedly(detail))
        for (_, cont) in lockWaiters {
            cont.resume(returning: false)
        }
    }
}

private final class VMBox: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let projectID: UUID
    private let vmQueue: DispatchQueue
    private let rpcReadQueue: DispatchQueue
    private let consoleReadQueue: DispatchQueue
    private let vm: VZVirtualMachine
    private let channel: VMChannelState

    // Guarded strictly by vmQueue
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    private let consoleInPipe = Pipe()
    private let consoleOutPipe = Pipe()
    private let rpcHostToGuestPipe = Pipe()
    private let rpcGuestToHostPipe = Pipe()

    var isAlive: Bool {
        channel.isAlive
    }

    init(projectID: UUID, workspaceURL: URL, assets: ResolvedVMAssets) throws {
        self.projectID = projectID
        self.vmQueue = DispatchQueue(label: "com.helm.vm.main.\(projectID.uuidString)")
        let rpcQueue = DispatchQueue(label: "com.helm.vm.rpc.\(projectID.uuidString)")
        self.rpcReadQueue = rpcQueue
        self.consoleReadQueue = DispatchQueue(label: "com.helm.vm.console.\(projectID.uuidString)")
        self.channel = VMChannelState(timeoutQueue: rpcQueue)

        _ = fcntl(rpcHostToGuestPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(consoleInPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = min(2, max(1, ProcessInfo.processInfo.processorCount))
        config.memorySize = 512 * 1024 * 1024
        config.platform = VZGenericPlatformConfiguration()

        let bootLoader = VZLinuxBootLoader(kernelURL: assets.kernelImageURL)
        bootLoader.initialRamdiskURL = assets.initramfsHelmURL
        bootLoader.commandLine = "console=hvc0 rdinit=/helm-init quiet panic=1"
        config.bootLoader = bootLoader

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
        fsDevice.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: workspaceURL, readOnly: false)
        )
        config.directorySharingDevices = [fsDevice]

        let consolePort = VZVirtioConsolePortConfiguration()
        consolePort.isConsole = true
        consolePort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: consoleInPipe.fileHandleForReading,
            fileHandleForWriting: consoleOutPipe.fileHandleForWriting
        )

        let rpcPort = VZVirtioConsolePortConfiguration()
        rpcPort.isConsole = false
        rpcPort.name = "helm-rpc"
        rpcPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: rpcHostToGuestPipe.fileHandleForReading,
            fileHandleForWriting: rpcGuestToHostPipe.fileHandleForWriting
        )

        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        consoleDevice.ports[0] = consolePort
        consoleDevice.ports[1] = rpcPort
        config.consoleDevices = [consoleDevice]

        do {
            try config.validate()
        } catch {
            throw HelmIsolationError.vmStartFailed("VM configuration validation failed: \(error.localizedDescription)")
        }

        self.vm = VZVirtualMachine(configuration: config, queue: vmQueue)
        super.init()
        self.vm.delegate = self

        startConsoleDrainLoop()
        startRPCReadLoop()
    }

    func lockRPCIfAlive() async -> Bool {
        await channel.lockRPCIfAlive()
    }

    func unlockRPC(markDead: Bool) async {
        channel.unlockRPC(markDead: markDead)
    }

    func startAndAwaitReady(timeoutSeconds: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                if self.channel.isStopRequested {
                    self.markStoppedAndDrainStopWaiters(reason: "stopped before start")
                    cont.resume(throwing: HelmIsolationError.vmStoppedUnexpectedly("VM stopped before start."))
                    return
                }
                self.vm.start { result in
                    switch result {
                    case .success:
                        if self.channel.isStopRequested {
                            if self.vm.canStop {
                                self.vm.stop { _ in
                                    self.markStoppedAndDrainStopWaiters(reason: "stopped during start")
                                }
                            } else {
                                self.markStoppedAndDrainStopWaiters(reason: "stopped during start")
                            }
                            cont.resume(throwing: HelmIsolationError.vmStoppedUnexpectedly("VM stopped during start."))
                        } else {
                            cont.resume()
                        }
                    case .failure(let err):
                        self.markStoppedAndDrainStopWaiters(reason: err.localizedDescription)
                        cont.resume(throwing: HelmIsolationError.vmStartFailed(err.localizedDescription))
                    }
                }
            }
        }

        let readyLine = try await channel.readNextLine(timeoutSeconds: timeoutSeconds)
        guard readyLine == "READY" else {
            throw HelmIsolationError.rpcProtocolError("Expected READY from guest, got '\(readyLine)'")
        }
    }

    func sendCommandAndAwaitResponse(
        frame: String,
        expectedRequestID: String,
        safetyTimeoutSeconds: TimeInterval
    ) async throws -> String {
        guard let data = frame.data(using: .utf8) else {
            throw HelmIsolationError.rpcProtocolError("Failed to encode RPC frame.")
        }
        try writeRPCData(data)

        while true {
            let line = try await channel.readNextLine(timeoutSeconds: safetyTimeoutSeconds)
            if line.hasPrefix("RES \(expectedRequestID) ") {
                return line
            }
            if line.hasPrefix("BYE") {
                throw HelmIsolationError.vmStoppedUnexpectedly("Guest sent BYE during active command.")
            }
        }
    }

    func shutdownGracefully() async {
        let shouldSendBye = channel.beginGracefulShutdownIfIdle()
        if shouldSendBye {
            if let byeData = "SHUTDOWN\n".data(using: .utf8) {
                try? writeRPCData(byeData)
                _ = try? await channel.readNextLine(timeoutSeconds: 1.5)
            }
            channel.unlockRPC(markDead: true)
        }
        await forceStop()
    }

    func forceStop() async {
        channel.requestStop()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            vmQueue.async {
                if self.vm.state == .stopped || self.vm.state == .error {
                    self.markStoppedAndDrainStopWaiters(reason: "stopped")
                    cont.resume()
                    return
                }
                if self.vm.canStop {
                    self.vm.stop { _ in
                        self.markStoppedAndDrainStopWaiters(reason: "force stopped")
                        cont.resume()
                    }
                    return
                }
                // Intermediate .starting or .stopping state: wait for transition to complete on vmQueue.
                self.stopWaiters.append(cont)
            }
        }
        closeAllPipes()
    }

    // MARK: - VZVirtualMachineDelegate (Always invoked on vmQueue)

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        markStoppedAndDrainStopWaiters(reason: "guest halted")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        markStoppedAndDrainStopWaiters(reason: error.localizedDescription)
    }

    private func markStoppedAndDrainStopWaiters(reason: String) {
        channel.markStopped(reason: reason)
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for cont in waiters {
            cont.resume()
        }
    }

    // MARK: - Pipe I/O

    private func writeRPCData(_ data: Data) throws {
        let fd = rpcHostToGuestPipe.fileHandleForWriting.fileDescriptor
        guard fd >= 0 else {
            throw HelmIsolationError.vmStoppedUnexpectedly("RPC write pipe closed.")
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    let err = String(cString: strerror(errno))
                    throw HelmIsolationError.vmStoppedUnexpectedly("RPC write failed: \(err)")
                }
            }
        }
    }

    private func startConsoleDrainLoop() {
        let fd = consoleOutPipe.fileHandleForReading.fileDescriptor
        consoleReadQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    let chunk = Data(buf[0..<n])
                    self?.channel.appendConsoleTail(chunk)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func startRPCReadLoop() {
        let fd = rpcGuestToHostPipe.fileHandleForReading.fileDescriptor
        rpcReadQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            var pending = Data()
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    pending.append(contentsOf: buf[0..<n])
                    while let nlIdx = pending.firstIndex(of: 0x0A) {
                        let lineData = pending.subdata(in: pending.startIndex..<nlIdx)
                        pending.removeSubrange(pending.startIndex...nlIdx)
                        let line = String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                        self?.channel.deliverLine(line)
                    }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    self?.channel.markStopped(reason: "RPC stream closed")
                    break
                }
            }
        }
    }

    private func closeAllPipes() {
        try? consoleInPipe.fileHandleForReading.close()
        try? consoleInPipe.fileHandleForWriting.close()
        try? consoleOutPipe.fileHandleForReading.close()
        try? consoleOutPipe.fileHandleForWriting.close()
        try? rpcHostToGuestPipe.fileHandleForReading.close()
        try? rpcHostToGuestPipe.fileHandleForWriting.close()
        try? rpcGuestToHostPipe.fileHandleForReading.close()
        try? rpcGuestToHostPipe.fileHandleForWriting.close()
    }
}
