import CryptoKit
import Darwin
import Foundation

public struct ResolvedVMAssets: Sendable, Equatable {
    public let kernelImageURL: URL
    public let initramfsHelmURL: URL
    public let sourceDescription: String

    public init(kernelImageURL: URL, initramfsHelmURL: URL, sourceDescription: String) {
        self.kernelImageURL = kernelImageURL
        self.initramfsHelmURL = initramfsHelmURL
        self.sourceDescription = sourceDescription
    }
}

public actor AlpineImageCache {
    public static let defaultBaseURLString = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot"
    public static let pinnedVmlinuzVirtSHA256 = "9e24e2ae4db247fe7f05034b7b2d351a0c8b1e5cb0f174e58789476493fd0b97"
    public static let pinnedInitramfsVirtSHA256 = "a42207383e03b28cc32e7856932885c66276c3d4caf633637a03ca1086f16344"

    private static let zimgMagic: [UInt8] = [0x4D, 0x5A, 0x00, 0x00, 0x7A, 0x69, 0x6D, 0x67] // "MZ\0\0zimg"
    private static let gzipASCII: [UInt8] = [0x67, 0x7A, 0x69, 0x70] // "gzip"
    private static let arm64Magic: [UInt8] = [0x41, 0x52, 0x4D, 0x64] // "ARMd" at 0x38

    private let environment: [String: String]
    private let currentDirectoryURL: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) {
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }

    public func writableCacheDirectory() -> URL {
        if let override = environment["HELM_VM_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Helm", isDirectory: true)
            .appendingPathComponent("vm", isDirectory: true)
    }

    public func findLocalRawAssets() -> (kernelURL: URL, initramfsURL: URL, source: String)? {
        try? resolveLocalRawAssets()
    }

    public func resolveLocalRawAssets() throws -> (kernelURL: URL, initramfsURL: URL, source: String)? {
        let kEnv = environment["HELM_VM_KERNEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let iEnv = environment["HELM_VM_INITRAMFS"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !kEnv.isEmpty || !iEnv.isEmpty {
            guard !kEnv.isEmpty, !iEnv.isEmpty else {
                throw HelmIsolationError.invalidKernelImage(
                    "Both HELM_VM_KERNEL and HELM_VM_INITRAMFS must be set when overriding VM image paths."
                )
            }
            let kURL = URL(fileURLWithPath: (kEnv as NSString).expandingTildeInPath)
            let iURL = URL(fileURLWithPath: (iEnv as NSString).expandingTildeInPath)
            guard Self.isRegularNonEmptyFile(atPath: kURL.path) else {
                throw HelmIsolationError.invalidKernelImage(
                    "Explicit HELM_VM_KERNEL does not exist or is not a regular non-empty file: \(kURL.path)"
                )
            }
            guard Self.isRegularNonEmptyFile(atPath: iURL.path) else {
                throw HelmIsolationError.invalidKernelImage(
                    "Explicit HELM_VM_INITRAMFS does not exist or is not a regular non-empty file: \(iURL.path)"
                )
            }
            return (kURL, iURL, "env(HELM_VM_KERNEL/HELM_VM_INITRAMFS)")
        }

        let candidateDirs: [URL]
        if let cacheOverride = environment["HELM_VM_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cacheOverride.isEmpty {
            // Strict scoping: only inspect HELM_VM_CACHE_DIR when explicitly set.
            candidateDirs = [
                URL(fileURLWithPath: (cacheOverride as NSString).expandingTildeInPath, isDirectory: true)
            ]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            candidateDirs = [
                currentDirectoryURL.appendingPathComponent(".helm-vm", isDirectory: true),
                currentDirectoryURL.appendingPathComponent("Resources/vm", isDirectory: true),
                currentDirectoryURL.appendingPathComponent(".cache/vm", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Helm/vm", isDirectory: true),
                home.appendingPathComponent("Library/Caches/Helm/vm", isDirectory: true),
            ]
        }

        for dir in candidateDirs {
            for (kName, iName) in [("vmlinuz-virt", "initramfs-virt"), ("vmlinuz", "initramfs")] {
                let kURL = dir.appendingPathComponent(kName)
                let iURL = dir.appendingPathComponent(iName)
                if Self.isRegularNonEmptyFile(atPath: kURL.path),
                   Self.isRegularNonEmptyFile(atPath: iURL.path) {
                    return (kURL, iURL, dir.path)
                }
            }
        }

        return nil
    }

    public func hasLocalAssets() -> Bool {
        (try? resolveLocalRawAssets()) != nil
    }

    public func ensureAssets(
        initScriptData: Data,
        allowDownload: Bool = true
    ) async throws -> ResolvedVMAssets {
        let rawKernelURL: URL
        let rawInitramfsURL: URL
        let sourceDesc: String

        if let local = try resolveLocalRawAssets() {
            rawKernelURL = local.kernelURL
            rawInitramfsURL = local.initramfsURL
            sourceDesc = local.source
        } else {
            guard allowDownload else {
                throw HelmIsolationError.imageDownloadFailed("Alpine VM assets not found locally and downloads are disabled.")
            }
            let targetDir = writableCacheDirectory()
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let downloaded = try await downloadAndVerifyAssets(into: targetDir)
            rawKernelURL = downloaded.kernelURL
            rawInitramfsURL = downloaded.initramfsURL
            sourceDesc = "downloaded(\(targetDir.path))"
        }

        let workDir = writableCacheDirectory()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let preparedKernelURL = try ensurePreparedKernelImage(rawKernelURL: rawKernelURL, cacheDir: workDir)
        let preparedInitramfsURL = try ensurePreparedInitramfs(
            rawInitramfsURL: rawInitramfsURL,
            initScriptData: initScriptData,
            cacheDir: workDir
        )

        return ResolvedVMAssets(
            kernelImageURL: preparedKernelURL,
            initramfsHelmURL: preparedInitramfsURL,
            sourceDescription: sourceDesc
        )
    }

    private func downloadAndVerifyAssets(into dir: URL) async throws -> (kernelURL: URL, initramfsURL: URL) {
        let baseURLStr = (environment["HELM_ALPINE_MIRROR_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBaseURLString
        let cleanBase = baseURLStr.hasSuffix("/") ? String(baseURLStr.dropLast()) : baseURLStr

        guard let kernelRemote = URL(string: "\(cleanBase)/vmlinuz-virt"),
              let initramfsRemote = URL(string: "\(cleanBase)/initramfs-virt") else {
            throw HelmIsolationError.imageDownloadFailed("Invalid mirror URL: \(cleanBase)")
        }

        let allowUnpinned = environment["HELM_ALPINE_ALLOW_UNPINNED"] == "1"
            || environment["HELM_ALPINE_MIRROR_URL"] != nil

        let kernelDest = dir.appendingPathComponent("vmlinuz-virt")
        let initramfsDest = dir.appendingPathComponent("initramfs-virt")

        try await downloadFileAtomically(
            from: kernelRemote,
            to: kernelDest,
            expectedSHA256: allowUnpinned ? nil : Self.pinnedVmlinuzVirtSHA256,
            label: "vmlinuz-virt"
        )
        try await downloadFileAtomically(
            from: initramfsRemote,
            to: initramfsDest,
            expectedSHA256: allowUnpinned ? nil : Self.pinnedInitramfsVirtSHA256,
            label: "initramfs-virt"
        )

        return (kernelDest, initramfsDest)
    }

    private func downloadFileAtomically(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedSHA256: String?,
        label: String
    ) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (tempDownloadURL, response): (URL, URLResponse)
        do {
            (tempDownloadURL, response) = try await session.download(from: remoteURL)
        } catch {
            throw HelmIsolationError.imageDownloadFailed("Download '\(label)' failed: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: tempDownloadURL) }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw HelmIsolationError.imageDownloadFailed("HTTP \(http.statusCode) downloading '\(label)' from \(remoteURL.absoluteString)")
        }

        let data = try Data(contentsOf: tempDownloadURL, options: .mappedIfSafe)
        guard !data.isEmpty else {
            throw HelmIsolationError.imageDownloadFailed("Downloaded '\(label)' is empty.")
        }

        if let expectedSHA256 {
            let actual = Self.sha256Hex(data)
            guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw HelmIsolationError.imageDownloadFailed(
                    "SHA-256 mismatch for '\(label)': expected \(expectedSHA256), got \(actual). Set HELM_ALPINE_ALLOW_UNPINNED=1 to override."
                )
            }
        }

        try Self.atomicWrite(data, to: destinationURL)
    }

    private func ensurePreparedKernelImage(rawKernelURL: URL, cacheDir: URL) throws -> URL {
        let rawData = try Data(contentsOf: rawKernelURL, options: .mappedIfSafe)
        let rawHashPrefix = String(Self.sha256Hex(rawData).prefix(12))
        let outURL = cacheDir.appendingPathComponent("vmlinuz-Image-\(rawHashPrefix)")
        if FileManager.default.fileExists(atPath: outURL.path) {
            if let existing = try? Data(contentsOf: outURL, options: .mappedIfSafe),
               Self.hasARM64ImageMagic(existing) {
                return outURL
            }
        }

        let imageData = try Self.extractLinuxKernelImage(from: rawData)
        try Self.atomicWrite(imageData, to: outURL)
        return outURL
    }

    private func ensurePreparedInitramfs(
        rawInitramfsURL: URL,
        initScriptData: Data,
        cacheDir: URL
    ) throws -> URL {
        let baseData = try Data(contentsOf: rawInitramfsURL, options: .mappedIfSafe)
        let baseHashPrefix = String(Self.sha256Hex(baseData).prefix(12))
        let scriptHashPrefix = String(Self.sha256Hex(initScriptData).prefix(12))
        let outURL = cacheDir.appendingPathComponent("initramfs-helm-\(baseHashPrefix)-\(scriptHashPrefix)")

        if FileManager.default.fileExists(atPath: outURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > baseData.count {
            return outURL
        }

        let cpioOverlay = CpioArchiveBuilder.buildNewcArchive(files: [
            CpioEntry(path: "helm-init", mode: 0o100755, data: initScriptData)
        ])
        let gzOverlay = try CpioArchiveBuilder.gzipCompress(cpioOverlay)

        var combined = Data(capacity: baseData.count + gzOverlay.count)
        combined.append(baseData)
        combined.append(gzOverlay)

        try Self.atomicWrite(combined, to: outURL)
        return outURL
    }

    public static func extractLinuxKernelImage(from rawKernelData: Data) throws -> Data {
        if hasARM64ImageMagic(rawKernelData) {
            return rawKernelData
        }

        guard rawKernelData.count >= 28 else {
            throw HelmIsolationError.invalidKernelImage("Kernel file too small (\(rawKernelData.count) bytes).")
        }

        let headerMagic = Array(rawKernelData[0..<8])
        guard headerMagic == zimgMagic else {
            throw HelmIsolationError.invalidKernelImage("Unrecognized kernel format (neither ARM64 Image nor EFI zimg).")
        }

        let compressionTag = Array(rawKernelData[24..<28])
        guard compressionTag == gzipASCII else {
            throw HelmIsolationError.invalidKernelImage("Unsupported EFI zimg compression (expected gzip).")
        }

        let payloadOffset = Int(readUInt32LE(rawKernelData, at: 8))
        let payloadSize = Int(readUInt32LE(rawKernelData, at: 12))
        guard payloadOffset >= 28,
              payloadSize > 0,
              payloadOffset + payloadSize <= rawKernelData.count else {
            throw HelmIsolationError.invalidKernelImage(
                "Invalid EFI zimg payload bounds (offset=\(payloadOffset), size=\(payloadSize), total=\(rawKernelData.count))."
            )
        }

        let compressedSlice = Data(rawKernelData[payloadOffset..<(payloadOffset + payloadSize)])
        let decompressed = try CpioArchiveBuilder.gzipDecompress(compressedSlice)
        guard hasARM64ImageMagic(decompressed) else {
            throw HelmIsolationError.invalidKernelImage("Decompressed zimg payload missing ARM64 'ARMd' magic at offset 0x38.")
        }
        return decompressed
    }

    public static func hasARM64ImageMagic(_ data: Data) -> Bool {
        guard data.count >= 0x3C else { return false }
        return Array(data[0x38..<0x3C]) == arm64Magic
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func isRegularNonEmptyFile(atPath path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG && st.st_size > 0
    }

    private static func atomicWrite(_ data: Data, to destinationURL: URL) throws {
        let dir = destinationURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: [])
        if Darwin.rename(tempURL.path, destinationURL.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}
