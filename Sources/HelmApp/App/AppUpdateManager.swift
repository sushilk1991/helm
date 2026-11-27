import AppKit
import CryptoKit
import Foundation
import Observation

public struct HelmSemVer: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.major = parts[0]
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var displayString: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: HelmSemVer, rhs: HelmSemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct HelmReleaseInfo: Sendable, Equatable {
    public let tagName: String
    public let version: HelmSemVer
    public let title: String
    public let notes: String
    public let htmlURL: URL
    public let dmgURL: URL?
    public let sha256URL: URL?

    public init(
        tagName: String,
        version: HelmSemVer,
        title: String,
        notes: String,
        htmlURL: URL,
        dmgURL: URL?,
        sha256URL: URL?
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.notes = notes
        self.htmlURL = htmlURL
        self.dmgURL = dmgURL
        self.sha256URL = sha256URL
    }
}

public enum HelmUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(HelmReleaseInfo)
    case downloading(progress: Double, release: HelmReleaseInfo)
    case installing(release: HelmReleaseInfo)
    case failed(message: String)

    public var availableRelease: HelmReleaseInfo? {
        switch self {
        case .available(let info), .downloading(_, let info), .installing(let info):
            return info
        default:
            return nil
        }
    }

    public var hasUpdateAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }
}

@MainActor
@Observable
public final class AppUpdateManager {
    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/sushilk1991/helm/releases/latest")!
    public static let defaultReleasesPageURL = URL(string: "https://github.com/sushilk1991/helm/releases/latest")!

    public private(set) var state: HelmUpdateState = .idle
    public private(set) var lastCheckedAt: Date?
    public var showUpdatePopover: Bool = false

    public let currentVersionString: String
    public let currentVersion: HelmSemVer
    public let feedURL: URL

    private let urlSession: URLSession
    private let autoCheckEnabled: Bool
    private var periodicTask: Task<Void, Never>?

    public init(
        currentVersionString: String? = nil,
        feedURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        urlSession: URLSession = .shared
    ) {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let resolvedVersion = currentVersionString ?? bundleVersion ?? "0.1.1"
        self.currentVersionString = resolvedVersion
        self.currentVersion = HelmSemVer(parsing: resolvedVersion) ?? HelmSemVer(major: 0, minor: 1, patch: 1)

        if let feedURL {
            self.feedURL = feedURL
        } else if let envFeed = environment["HELM_UPDATE_FEED_URL"], let parsed = URL(string: envFeed) {
            self.feedURL = parsed
        } else {
            self.feedURL = Self.defaultFeedURL
        }

        let isHeadless = arguments.contains("--headless") || environment["HELM_DISABLE_UPDATE_CHECK"] == "1"
        self.autoCheckEnabled = !isHeadless
        self.urlSession = urlSession
    }

    public func startPeriodicChecks() {
        guard autoCheckEnabled, periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            // Short calm delay after launch so startup stays instantaneous
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await self?.checkForUpdates(userInitiated: false)
                try? await Task.sleep(for: .seconds(60 * 60 * 4)) // Every 4 hours
            }
        }
    }

    public func stopPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    public func checkForUpdates(userInitiated: Bool) async {
        guard !state.isBusy else { return }
        if userInitiated {
            state = .checking
        } else if case .available = state {
            // Keep existing banner visible while quietly refreshing
        } else {
            state = .checking
        }

        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Helm/\(currentVersionString) (macOS)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "AppUpdateManager",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Update server returned HTTP \(http.statusCode)."]
                )
            }

            let release = try Self.parseGitHubRelease(data: data)
            let now = Date()
            lastCheckedAt = now

            if release.version > currentVersion {
                state = .available(release)
            } else {
                state = .upToDate(checkedAt: now)
            }
        } catch {
            if userInitiated {
                state = .failed(message: error.localizedDescription)
            } else {
                // Silent failure on unattended background checks so we never disturb the user
                if case .checking = state {
                    state = .idle
                }
            }
        }
    }

    public func downloadAndInstall(_ release: HelmReleaseInfo) async {
        guard let dmgURL = release.dmgURL else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        guard !state.isBusy else { return }

        state = .downloading(progress: 0.02, release: release)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelmUpdate-\(release.version.displayString)-\(UUID().uuidString.prefix(6))", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let localDMG = workDir.appendingPathComponent(dmgURL.lastPathComponent)

            // 1. Stream download DMG with live progress updates
            var req = URLRequest(url: dmgURL)
            req.timeoutInterval = 120
            req.setValue("Helm/\(currentVersionString) (macOS)", forHTTPHeaderField: "User-Agent")

            let (asyncBytes, response) = try await urlSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "AppUpdateManager",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download release DMG."]
                )
            }

            let expectedBytes = max(1, response.expectedContentLength)
            FileManager.default.createFile(atPath: localDMG.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localDMG)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(65_536)
            var downloadedBytes: Int64 = 0
            var hasher = SHA256()

            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    downloadedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let progress = min(0.98, Double(downloadedBytes) / Double(expectedBytes))
                    state = .downloading(progress: progress, release: release)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                downloadedBytes += Int64(buffer.count)
            }
            try handle.close()

            state = .installing(release: release)

            // 2. Verify SHA-256 against published .sha256 sidecar if present
            if let shaURL = release.sha256URL {
                let (shaData, shaResp) = try await urlSession.data(from: shaURL)
                if let shaHTTP = shaResp as? HTTPURLResponse, (200..<300).contains(shaHTTP.statusCode),
                   let expectedHex = String(data: shaData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map({ String($0).lowercased() }),
                   expectedHex.count == 64 {
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    guard digest == expectedHex else {
                        throw NSError(
                            domain: "AppUpdateManager",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Downloaded DMG checksum verification failed."]
                        )
                    }
                }
            }

            // 3. Mount read-only, verify code signature of bundled Helm.app
            let mountPoint = workDir.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            try await runProcess("/usr/bin/hdiutil", arguments: [
                "attach", localDMG.path, "-mountpoint", mountPoint.path, "-nobrowse", "-readonly", "-quiet",
            ])

            let mountedApp = mountPoint.appendingPathComponent("Helm.app")
            guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                _ = try? await runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
                throw NSError(
                    domain: "AppUpdateManager",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Helm.app was not found inside the downloaded DMG."]
                )
            }

            try await runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", mountedApp.path])

            // 4. Swap in-place if running from a writable .app bundle; otherwise open DMG for manual drag-install
            let currentAppURL = Bundle.main.bundleURL
            let canSelfReplace = currentAppURL.pathExtension == "app"
                && !currentAppURL.path.hasPrefix("/Volumes/")
                && FileManager.default.isWritableFile(atPath: currentAppURL.deletingLastPathComponent().path)

            if canSelfReplace {
                let pid = ProcessInfo.processInfo.processIdentifier
                let scriptPath = workDir.appendingPathComponent("apply_update.sh")
                let script = """
                #!/bin/sh
                PID="$1"
                SRC_APP="$2"
                DST_APP="$3"
                MNT="$4"
                WORKDIR="$5"
                while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
                rm -rf "${DST_APP}.old"
                mv "$DST_APP" "${DST_APP}.old" || exit 1
                if ditto "$SRC_APP" "$DST_APP"; then
                    rm -rf "${DST_APP}.old"
                else
                    mv "${DST_APP}.old" "$DST_APP"
                    hdiutil detach "$MNT" -quiet || true
                    exit 1
                fi
                hdiutil detach "$MNT" -quiet || true
                open -n "$DST_APP"
                rm -rf "$WORKDIR"
                """
                try script.write(to: scriptPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

                let helper = Process()
                helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                helper.arguments = [scriptPath.path, "\(pid)", mountedApp.path, currentAppURL.path, mountPoint.path, workDir.path]
                try helper.run()

                NSApp.terminate(nil)
            } else {
                _ = try? await runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
                NSWorkspace.shared.open(localDMG)
                state = .available(release)
            }
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            state = .failed(message: error.localizedDescription)
        }
    }

    public func openReleasesPage() {
        let target = state.availableRelease?.htmlURL ?? Self.defaultReleasesPageURL
        NSWorkspace.shared.open(target)
    }

    // MARK: - GitHub Release JSON Parsing

    private struct GitHubReleasePayload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]
    }

    public static func parseGitHubRelease(data: Data) throws -> HelmReleaseInfo {
        let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        guard let version = HelmSemVer(parsing: payload.tag_name) else {
            throw NSError(
                domain: "AppUpdateManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid version tag: \(payload.tag_name)"]
            )
        }
        guard let htmlURL = URL(string: payload.html_url) else {
            throw NSError(
                domain: "AppUpdateManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid release URL."]
            )
        }

        let dmgAsset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") && $0.name.lowercased().contains("arm64") })
            ?? payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
        let shaAsset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg.sha256") })

        return HelmReleaseInfo(
            tagName: payload.tag_name,
            version: version,
            title: payload.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? payload.name! : payload.tag_name,
            notes: payload.body ?? "",
            htmlURL: htmlURL,
            dmgURL: dmgAsset.flatMap { URL(string: $0.browser_download_url) },
            sha256URL: shaAsset.flatMap { URL(string: $0.browser_download_url) }
        )
    }

    @discardableResult
    private func runProcess(_ executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "AppUpdateManager",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: out.isEmpty ? "Command \(executable) failed (\(proc.terminationStatus))." : out]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
