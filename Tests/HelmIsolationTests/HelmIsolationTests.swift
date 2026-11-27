import Darwin
import Foundation
@testable import HelmCore
@testable import HelmIsolation
import Testing

@Suite("HelmIsolation Unit & Integration Tests")
struct HelmIsolationTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelmIsolationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Cpio & Zlib Tests

    @Test("CpioArchiveBuilder builds valid 512-padded newc archive and gzip round-trips")
    func cpioAndGzipRoundTrip() throws {
        let payload = Data("#!/bin/sh\necho hi\n".utf8)
        let archive = CpioArchiveBuilder.buildNewcArchive(files: [
            CpioEntry(path: "/helm-init", mode: 0o100755, data: payload)
        ])

        #expect(archive.count % 512 == 0)
        #expect(String(data: archive.prefix(6), encoding: .utf8) == "070701")
        #expect(archive.range(of: Data("helm-init\0".utf8)) != nil)
        #expect(archive.range(of: Data("TRAILER!!!\0".utf8)) != nil)

        let gz = try CpioArchiveBuilder.gzipCompress(archive)
        #expect(gz.prefix(2) == Data([0x1F, 0x8B]))
        let inflated = try CpioArchiveBuilder.gzipDecompress(gz)
        #expect(inflated == archive)
    }

    @Test("CpioArchiveBuilder rejects invalid gzip input")
    func invalidGzipThrows() {
        #expect(throws: HelmIsolationError.self) {
            _ = try CpioArchiveBuilder.gzipDecompress(Data([0x00, 0x01, 0x02, 0x03]))
        }
        #expect(throws: HelmIsolationError.self) {
            _ = try CpioArchiveBuilder.gzipDecompress(Data())
        }
    }

    // MARK: - AlpineImageCache zimg Tests

    @Test("AlpineImageCache extracts ARM64 Image from EFI zimg container")
    func zimgExtractionAndDirectARMd() throws {
        // Construct a minimal synthetic ARM64 Image (> 0x40 bytes, "ARMd" at 0x38)
        var rawImage = Data(repeating: 0xAA, count: 256)
        rawImage.replaceSubrange(0x38..<0x3C, with: Data("ARMd".utf8))

        // Direct ARMd input passes through unchanged
        let direct = try AlpineImageCache.extractLinuxKernelImage(from: rawImage)
        #expect(direct == rawImage)

        // Wrap inside synthetic EFI zimg ("MZ\0\0zimg", offset @ 8, size @ 12, "gzip" @ 24)
        let gzPayload = try CpioArchiveBuilder.gzipCompress(rawImage)
        let payloadOffset: UInt32 = 64
        let payloadSize = UInt32(gzPayload.count)

        var zimg = Data(repeating: 0, count: Int(payloadOffset))
        zimg.replaceSubrange(0..<8, with: Data([0x4D, 0x5A, 0x00, 0x00, 0x7A, 0x69, 0x6D, 0x67]))
        zimg.replaceSubrange(8..<12, with: withUnsafeBytes(of: payloadOffset.littleEndian) { Data($0) })
        zimg.replaceSubrange(12..<16, with: withUnsafeBytes(of: payloadSize.littleEndian) { Data($0) })
        zimg.replaceSubrange(24..<28, with: Data("gzip".utf8))
        zimg.append(gzPayload)

        let extracted = try AlpineImageCache.extractLinuxKernelImage(from: zimg)
        #expect(extracted == rawImage)
        #expect(AlpineImageCache.hasARM64ImageMagic(extracted))
    }

    @Test("AlpineImageCache builds initramfs-helm overlay from local raw assets")
    func alpineCachePreparesLocalAssets() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var rawImage = Data(repeating: 0x11, count: 128)
        rawImage.replaceSubrange(0x38..<0x3C, with: Data("ARMd".utf8))
        let gzKernel = try CpioArchiveBuilder.gzipCompress(rawImage)
        var zimg = Data(repeating: 0, count: 64)
        zimg.replaceSubrange(0..<8, with: Data([0x4D, 0x5A, 0x00, 0x00, 0x7A, 0x69, 0x6D, 0x67]))
        let offsetLE = UInt32(64).littleEndian
        let sizeLE = UInt32(gzKernel.count).littleEndian
        zimg.replaceSubrange(8..<12, with: withUnsafeBytes(of: offsetLE) { Data($0) })
        zimg.replaceSubrange(12..<16, with: withUnsafeBytes(of: sizeLE) { Data($0) })
        zimg.replaceSubrange(24..<28, with: Data("gzip".utf8))
        zimg.append(gzKernel)

        let baseInitramfs = try CpioArchiveBuilder.gzipCompress(
            CpioArchiveBuilder.buildNewcArchive(files: [
                CpioEntry(path: "bin/busybox", mode: 0o100755, data: Data("BB".utf8))
            ])
        )

        let kernelURL = dir.appendingPathComponent("vmlinuz-virt")
        let initrdURL = dir.appendingPathComponent("initramfs-virt")
        try zimg.write(to: kernelURL)
        try baseInitramfs.write(to: initrdURL)

        let cache = AlpineImageCache(environment: ["HELM_VM_CACHE_DIR": dir.path])
        #expect(await cache.hasLocalAssets())
        let resolved = try await cache.ensureAssets(
            initScriptData: Data("#!/bin/sh\necho READY\n".utf8),
            allowDownload: false
        )
        #expect(FileManager.default.fileExists(atPath: resolved.kernelImageURL.path))
        #expect(FileManager.default.fileExists(atPath: resolved.initramfsHelmURL.path))
        let preparedKernel = try Data(contentsOf: resolved.kernelImageURL)
        #expect(preparedKernel == rawImage)
        let preparedInitrd = try Data(contentsOf: resolved.initramfsHelmURL)
        #expect(preparedInitrd.count > baseInitramfs.count)
    }

    @Test("AlpineImageCache fails loudly on missing explicit HELM_VM_KERNEL / HELM_VM_INITRAMFS and isolates HELM_VM_CACHE_DIR")
    func alpineCacheStrictEnvOverridesAndConcurrentAtomicWrite() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let emptyDir = dir.appendingPathComponent("empty_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        // 1. HELM_VM_CACHE_DIR set to empty dir must NOT fall back to ~/Library/Application Support/Helm/vm
        let emptyCache = AlpineImageCache(
            environment: ["HELM_VM_CACHE_DIR": emptyDir.path],
            currentDirectoryURL: dir
        )
        #expect(await !emptyCache.hasLocalAssets())
        await #expect(throws: HelmIsolationError.self) {
            _ = try await emptyCache.ensureAssets(
                initScriptData: Data("#!/bin/sh\n".utf8),
                allowDownload: false
            )
        }

        // 2. Populate valid local assets inside populatedDir, then pass invalid HELM_VM_KERNEL
        let populatedDir = dir.appendingPathComponent("populated_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: populatedDir, withIntermediateDirectories: true)

        var rawImage = Data(repeating: 0x22, count: 128)
        rawImage.replaceSubrange(0x38..<0x3C, with: Data("ARMd".utf8))
        let baseInitramfs = try CpioArchiveBuilder.gzipCompress(
            CpioArchiveBuilder.buildNewcArchive(files: [
                CpioEntry(path: "bin/busybox", mode: 0o100755, data: Data("BB".utf8))
            ])
        )
        try rawImage.write(to: populatedDir.appendingPathComponent("vmlinuz-virt"))
        try baseInitramfs.write(to: populatedDir.appendingPathComponent("initramfs-virt"))

        let missingKernelCache = AlpineImageCache(
            environment: [
                "HELM_VM_KERNEL": "/nonexistent/vmlinuz-virt",
                "HELM_VM_INITRAMFS": populatedDir.appendingPathComponent("initramfs-virt").path,
                "HELM_VM_CACHE_DIR": populatedDir.path,
            ],
            currentDirectoryURL: dir
        )
        await #expect(throws: HelmIsolationError.self) {
            _ = try await missingKernelCache.ensureAssets(
                initScriptData: Data("#!/bin/sh\n".utf8),
                allowDownload: true
            )
        }

        let singleOverrideCache = AlpineImageCache(
            environment: [
                "HELM_VM_KERNEL": populatedDir.appendingPathComponent("vmlinuz-virt").path,
                "HELM_VM_CACHE_DIR": populatedDir.path,
            ],
            currentDirectoryURL: dir
        )
        await #expect(throws: HelmIsolationError.self) {
            _ = try await singleOverrideCache.ensureAssets(
                initScriptData: Data("#!/bin/sh\n".utf8),
                allowDownload: true
            )
        }

        // 3. Concurrent ensureAssets calls on populatedDir must atomically rename without NSFileWriteFileExistsError
        let initData = Data("#!/bin/sh\necho CONCURRENT_CACHE\n".utf8)
        try await withThrowingTaskGroup(of: ResolvedVMAssets.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let c = AlpineImageCache(environment: ["HELM_VM_CACHE_DIR": populatedDir.path])
                    return try await c.ensureAssets(initScriptData: initData, allowDownload: false)
                }
            }
            var count = 0
            for try await resolved in group {
                #expect(FileManager.default.fileExists(atPath: resolved.kernelImageURL.path))
                #expect(FileManager.default.fileExists(atPath: resolved.initramfsHelmURL.path))
                count += 1
            }
            #expect(count == 8)
        }
    }

    // MARK: - EntitlementChecker & PowerAssertionGuard

    @Test("EntitlementChecker probes cleanly without crashing")
    func entitlementCheckerSafe() {
        _ = EntitlementChecker.isVirtualizationSupported()
        _ = EntitlementChecker.hasVirtualizationEntitlement()
        _ = EntitlementChecker.isVirtualizationAvailable()
    }

    @Test("PowerAssertionGuard reference-counts and releases IOPMAssertion cleanly")
    func powerAssertionGuardNoLeaks() async throws {
        let guardObj = PowerAssertionGuard()
        let t1 = guardObj.acquire(reason: "HelmTestAssertion")
        let t2 = guardObj.acquire(reason: "HelmTestAssertion")
        #expect(guardObj.activeCount == 2)
        #expect(guardObj.hasActiveAssertion)

        guardObj.release(t1)
        #expect(guardObj.activeCount == 1)
        #expect(guardObj.hasActiveAssertion)

        // Idempotent duplicate release
        guardObj.release(t1)
        #expect(guardObj.activeCount == 1)

        guardObj.release(t2)
        #expect(guardObj.activeCount == 0)
        #expect(!guardObj.hasActiveAssertion)

        // Verify pmset -g assertions contains no lingering HelmTestAssertion
        let pmset = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: ["-g", "assertions"],
            timeoutSeconds: 5
        )
        #expect(!pmset.stdout.contains("HelmTestAssertion"))
    }

    // MARK: - SeatbeltSandboxRunner

    @Test("SeatbeltSandboxRunner executes echo, workspace RW, and preserves non-zero exit code")
    func seatbeltBasicAndExitCode() async throws {
        let ws = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        let runner = SeatbeltSandboxRunner()
        let res1 = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "/bin/echo HELM_UNIT_OK && printf 'data1' > out.txt && cat out.txt",
            preferredMode: .seatbeltSandbox
        ))
        #expect(res1.modeUsed == .seatbeltSandbox)
        #expect(res1.exitCode == 0)
        #expect(!res1.timedOut)
        #expect(res1.stdout.contains("HELM_UNIT_OK"))
        #expect(res1.stdout.contains("data1"))
        #expect(try String(contentsOf: ws.appendingPathComponent("out.txt"), encoding: .utf8) == "data1")

        let res2 = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "exit 42",
            preferredMode: .seatbeltSandbox
        ))
        #expect(res2.exitCode == 42)
        #expect(!res2.timedOut)
    }

    @Test("SeatbeltSandboxRunner kills runaway CPU loop at timeout and reaps background grandchild")
    func seatbeltTimeoutAndGrandchildReap() async throws {
        let ws = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        let runner = SeatbeltSandboxRunner()
        let cpuRes = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "while true; do :; done",
            preferredMode: .seatbeltSandbox,
            timeoutSeconds: 1.0
        ))
        #expect(cpuRes.timedOut)
        #expect(cpuRes.durationMs < 5000.0)

        let marker = "HELM_UNIT_GC_\(UUID().uuidString)"
        let gcRes = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "(sh -c 'sleep 30; true' \(marker) &) ; echo PARENT_DONE",
            preferredMode: .seatbeltSandbox,
            timeoutSeconds: 2.0
        ))
        #expect(gcRes.stdout.contains("PARENT_DONE"))
        #expect(gcRes.durationMs < 5000.0)

        let pgrep = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", marker],
            timeoutSeconds: 5
        )
        #expect(pgrep.exitCode != 0 || pgrep.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("SeatbeltSandboxRunner truncates output at maxOutputBytes safely for UTF-8 and blocks /tmp & ~/.ssh")
    func seatbeltTruncationAndDenials() async throws {
        let ws = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        let runner = SeatbeltSandboxRunner()
        // Multi-byte UTF-8 flood ("🚀" is 4 bytes)
        let floodRes = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "yes '🚀' | head -c 16384",
            preferredMode: .seatbeltSandbox,
            maxOutputBytes: 255
        ))
        #expect(floodRes.truncatedOutput)
        #expect(floodRes.stdout.utf8.count <= 255)
        #expect(!floodRes.stdout.isEmpty)

        // /tmp write denial
        let escapePath = "/tmp/helm_unit_escape_\(getpid())"
        try? FileManager.default.removeItem(atPath: escapePath)
        defer { try? FileManager.default.removeItem(atPath: escapePath) }
        let escapeRes = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "touch \(escapePath)",
            preferredMode: .seatbeltSandbox
        ))
        #expect(escapeRes.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: escapePath))

        // ~/.ssh read denial (if ~/.ssh exists on host)
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshDir.path) {
            let sshRes = try await runner.execute(ExecutionRequest(
                projectID: UUID(),
                workspacePath: ws,
                command: "ls -la \(sshDir.path)",
                preferredMode: .seatbeltSandbox
            ))
            #expect(sshRes.exitCode != 0)
        }
    }

    @Test("SeatbeltSandboxRunner rejects empty command and missing workspace without auto-creating")
    func seatbeltValidationErrors() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = SeatbeltSandboxRunner()
        await #expect(throws: HelmIsolationError.emptyCommand) {
            _ = try await runner.execute(ExecutionRequest(
                projectID: UUID(),
                workspacePath: dir,
                command: "   ",
                preferredMode: .seatbeltSandbox
            ))
        }

        let missing = dir.appendingPathComponent("does_not_exist")
        await #expect(throws: HelmIsolationError.self) {
            _ = try await runner.execute(ExecutionRequest(
                projectID: UUID(),
                workspacePath: missing,
                command: "echo hi",
                preferredMode: .seatbeltSandbox
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: - ExecutionRouter

    @Test("ExecutionRouter enforces strict .virtualizationVM entitlement and auto-falls back on nil")
    func executionRouterSemantics() async throws {
        let ws = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        let router = ExecutionRouter()

        if !EntitlementChecker.hasVirtualizationEntitlement() {
            await #expect(throws: HelmIsolationError.missingEntitlement) {
                _ = try await router.execute(ExecutionRequest(
                    projectID: UUID(),
                    workspacePath: ws,
                    command: "uname -s",
                    preferredMode: .virtualizationVM
                ))
            }

            let autoRes = try await router.execute(ExecutionRequest(
                projectID: UUID(),
                workspacePath: ws,
                command: "echo AUTO_OK",
                preferredMode: nil
            ))
            #expect(autoRes.modeUsed == .seatbeltSandbox)
            #expect(autoRes.stdout.contains("AUTO_OK"))
        }
    }

    @Test("ExecutionRouter handles BatonPreflight .hold by falling back in auto mode")
    func executionRouterBatonHoldFallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = dir.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        // Create a mock baton executable returning critical memory pressure
        let mockBaton = dir.appendingPathComponent("mock-baton.sh")
        let script = """
        #!/bin/sh
        cat <<'JSON'
        {"time":"2026-11-26T00:00:00Z","lanes":[],"memory":{"pressure":"critical","total_bytes":68719476736,"available_bytes":100000000,"swap_total_bytes":0,"swap_used_bytes":0}}
        JSON
        """
        try Data(script.utf8).write(to: mockBaton)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockBaton.path)

        let preflight = BatonPreflight(executablePath: mockBaton.path)
        let verdict = await preflight.checkPreflight(requiredMemoryBytes: 768 * 1024 * 1024)
        if case .hold = verdict {
            // expected
        } else {
            Issue.record("Expected BatonPreflight .hold verdict, got \(verdict)")
        }

        let router = ExecutionRouter(batonPreflight: preflight)
        let res = try await router.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "echo HOLD_FALLBACK_OK",
            preferredMode: nil
        ))
        #expect(res.modeUsed == .seatbeltSandbox)
        #expect(res.stdout.contains("HOLD_FALLBACK_OK"))
    }

    // MARK: - Live Signed VM Integration (via signed helmctl when available)

    @Test("Live Virtualization.framework VM execution via signed helmctl")
    func liveSignedVMExecution() async throws {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidateBins = [
            cwd.appendingPathComponent(".build/debug/helmctl"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/helmctl"),
        ]
        guard let helmctl = candidateBins.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            return // Not built yet during first test invocation
        }

        // Check entitlement on helmctl and cached VM assets before running live VM check
        let signCheck = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", "-", helmctl.path],
            timeoutSeconds: 5
        )
        let hasEnt = signCheck.stdout.contains("com.apple.security.virtualization")
            || signCheck.stderr.contains("com.apple.security.virtualization")
        let hasAssets = await AlpineImageCache().hasLocalAssets()
        guard hasEnt && hasAssets else {
            return
        }

        let ws = try makeTempDir()
        defer { try? fm.removeItem(at: ws) }

        // 1. Linux uname + virtiofs /workspace write parity
        let out = try await ProcessRunner.run(
            executableURL: helmctl,
            arguments: [
                "sandbox", "exec",
                "--workspace", ws.path,
                "--cmd", "uname -s && echo VM_LIVE_OK > live.txt && cat live.txt",
                "--mode", "vm",
            ],
            timeoutSeconds: 45
        )
        #expect(out.exitCode == 0)
        let res = try HelmJSON.makeDecoder().decode(ExecutionResult.self, from: out.stdoutData)
        #expect(res.modeUsed == .virtualizationVM)
        #expect(res.exitCode == 0)
        #expect(res.stdout.contains("Linux"))
        #expect(res.stdout.contains("VM_LIVE_OK"))
        #expect(try String(contentsOf: ws.appendingPathComponent("live.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "VM_LIVE_OK")

        // 2. Timeout inside VM
        let timeoutOut = try await ProcessRunner.run(
            executableURL: helmctl,
            arguments: [
                "sandbox", "exec",
                "--workspace", ws.path,
                "--cmd", "while true; do :; done",
                "--mode", "vm",
                "--timeout", "1",
            ],
            timeoutSeconds: 30
        )
        #expect(timeoutOut.exitCode == 0)
        let timeoutRes = try HelmJSON.makeDecoder().decode(ExecutionResult.self, from: timeoutOut.stdoutData)
        #expect(timeoutRes.modeUsed == .virtualizationVM)
        #expect(timeoutRes.timedOut)

        // 3. Output byte cap inside VM
        let capOut = try await ProcessRunner.run(
            executableURL: helmctl,
            arguments: [
                "sandbox", "exec",
                "--workspace", ws.path,
                "--cmd", "yes VM_FLOOD | head -c 32768",
                "--mode", "vm",
                "--max-output-bytes", "128",
            ],
            timeoutSeconds: 30
        )
        #expect(capOut.exitCode == 0)
        let capRes = try HelmJSON.makeDecoder().decode(ExecutionResult.self, from: capOut.stdoutData)
        #expect(capRes.modeUsed == .virtualizationVM)
        #expect(capRes.truncatedOutput)
        #expect(capRes.stdout.utf8.count <= 128)

        // 4. Invalid UTF-8 (\xff) post-decode U+FFFD cap inside VM
        let binaryCapOut = try await ProcessRunner.run(
            executableURL: helmctl,
            arguments: [
                "sandbox", "exec",
                "--workspace", ws.path,
                "--cmd", "awk 'BEGIN{for(i=0;i<2048;i++) printf \"\\xff\"}'",
                "--mode", "vm",
                "--max-output-bytes", "1024",
            ],
            timeoutSeconds: 30
        )
        #expect(binaryCapOut.exitCode == 0)
        let binaryCapRes = try HelmJSON.makeDecoder().decode(ExecutionResult.self, from: binaryCapOut.stdoutData)
        #expect(binaryCapRes.modeUsed == .virtualizationVM)
        #expect(binaryCapRes.truncatedOutput)
        #expect(binaryCapRes.stdout.utf8.count <= 1024)

        // 5. Explicit HELM_VM_KERNEL=/nonexistent must fail loudly via CLI
        let badKernelOut = try await ProcessRunner.run(
            executableURL: helmctl,
            arguments: [
                "sandbox", "exec",
                "--workspace", ws.path,
                "--cmd", "uname -s",
                "--mode", "vm",
            ],
            environment: ["HELM_VM_KERNEL": "/nonexistent/vmlinuz-virt"],
            timeoutSeconds: 15
        )
        #expect(badKernelOut.exitCode != 0)
    }

    @Test("SeatbeltSandboxRunner caps invalid UTF-8 U+FFFD expansion within maxOutputBytes and cleans active PIDs")
    func seatbeltBinaryOutputCapAndFastPidCleanup() async throws {
        let ws = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: ws) }

        let runner = SeatbeltSandboxRunner()

        // Binary \xff flood (each raw byte expands to 3-byte U+FFFD if uncapped post-decode)
        let binRes = try await runner.execute(ExecutionRequest(
            projectID: UUID(),
            workspacePath: ws,
            command: "/usr/bin/awk 'BEGIN{for(i=0;i<2048;i++) printf \"\\xff\"}'",
            preferredMode: .seatbeltSandbox,
            maxOutputBytes: 1024
        ))
        #expect(binRes.exitCode == 0)
        #expect(binRes.truncatedOutput)
        #expect(binRes.stdout.utf8.count <= 1024)

        // Direct decodeUTF8Bounded combined budget test
        let rawInvalid = Data(repeating: 0xFF, count: 1024)
        let (boundedStr, postTrunc) = SeatbeltSandboxRunner.decodeUTF8Bounded(rawInvalid, maxUTF8Bytes: 1024)
        #expect(postTrunc)
        #expect(boundedStr.utf8.count <= 1024)

        // Fast-exit PID lifecycle race check across 20 rapid runs on same projectID
        let projID = UUID()
        for idx in 0..<20 {
            let res = try await runner.execute(ExecutionRequest(
                projectID: projID,
                workspacePath: ws,
                command: "echo FAST_\(idx)",
                preferredMode: .seatbeltSandbox
            ))
            #expect(res.exitCode == 0)
        }
        #expect(await runner.activePidCount(for: projID) == 0)
    }

    @Test("VMChannelState rejects concurrent readNextLine, handles cancellation, and wakes waiters on dead unlock")
    func vmChannelStateConcurrencyAndCancellation() async throws {
        let channel = VMChannelState()

        // 1. First reader waits; second concurrent reader is rejected without overwriting first waiter
        let firstTask = Task {
            try await channel.readNextLine(timeoutSeconds: 5.0)
        }
        try await Task.sleep(for: .milliseconds(30))

        await #expect(throws: HelmIsolationError.self) {
            _ = try await channel.readNextLine(timeoutSeconds: 1.0)
        }

        channel.deliverLine("READY")
        let firstLine = try await firstTask.value
        #expect(firstLine == "READY")

        // 2. Cancelled readNextLine resumes immediately with CancellationError
        let cancelReadTask = Task {
            try await channel.readNextLine(timeoutSeconds: 30.0)
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelReadTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelReadTask.value
        }

        // Subsequent reader still works cleanly
        channel.deliverLine("RES 1 0 0 0 - -")
        let nextLine = try await channel.readNextLine(timeoutSeconds: 1.0)
        #expect(nextLine == "RES 1 0 0 0 - -")

        // 3. lockRPCIfAlive cancellation & unlockRPC(markDead: true) wakeup
        #expect(await channel.lockRPCIfAlive())

        let cancelledLockWaiter = Task {
            await channel.lockRPCIfAlive()
        }
        let queuedWaiter = Task {
            await channel.lockRPCIfAlive()
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelledLockWaiter.cancel()
        #expect(await cancelledLockWaiter.value == false)

        channel.unlockRPC(markDead: true)
        #expect(await queuedWaiter.value == false)
    }
}
