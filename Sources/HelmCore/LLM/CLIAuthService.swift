#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import os

public enum CLIAuthProfileMode: String, Codable, Sendable, CaseIterable {
    case system = "system"
    case helmIsolated = "helm_isolated"

    public var displayName: String {
        switch self {
        case .system: return "System Profile"
        case .helmIsolated: return "Separate Helm Profile"
        }
    }

    public var subtitle: String {
        switch self {
        case .system:
            return "Share your existing macOS CLI logins (~/.claude, ~/.codex, ~/.pi)"
        case .helmIsolated:
            return "Use dedicated Helm-only credentials under Application Support/Helm/auth"
        }
    }
}

public enum CLIAuthProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case agy
    case pi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code CLI"
        case .codex: return "Codex CLI"
        case .agy: return "Antigravity CLI (agy)"
        case .pi: return "Pi CLI (PyCLI)"
        }
    }

    public var commandName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .agy: return "agy"
        case .pi: return "pi"
        }
    }

    public var backendKind: LLMBackendKind {
        switch self {
        case .claude: return .claudeCLI
        case .codex: return .codexCLI
        case .agy: return .agyCLI
        case .pi: return .piCLI
        }
    }

    public var supportsIsolatedProfile: Bool {
        switch self {
        case .claude, .codex, .pi: return true
        case .agy: return false
        }
    }

    public var supportsBrowserOAuth: Bool {
        switch self {
        case .claude, .codex, .agy: return true
        case .pi: return false
        }
    }

    public var supportsDeviceCodeLogin: Bool {
        self == .codex
    }

    public var supportsAPIKeyLogin: Bool {
        switch self {
        case .codex, .pi: return true
        case .claude, .agy: return false
        }
    }

    public var supportsSignOut: Bool {
        switch self {
        case .claude, .codex, .pi: return true
        case .agy: return false
        }
    }

    public static func from(backend: LLMBackendKind) -> CLIAuthProviderKind? {
        switch backend {
        case .claudeCLI: return .claude
        case .codexCLI: return .codex
        case .agyCLI: return .agy
        case .piCLI: return .pi
        case .mock, .directHTTP, .foundationModels: return nil
        }
    }
}

public enum CLIAuthLoginMethod: String, Sendable, Equatable, CaseIterable, Identifiable {
    case browserOAuth
    case claudeConsole
    case claudeSSO
    case deviceCode
    case apiKey

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .browserOAuth: return "Browser Sign-In"
        case .claudeConsole: return "Claude Console"
        case .claudeSSO: return "Enterprise SSO"
        case .deviceCode: return "Device Code"
        case .apiKey: return "API Key"
        }
    }
}

public struct CLIAuthIdentity: Sendable, Equatable {
    public let provider: CLIAuthProviderKind
    public let email: String?
    public let accountLabel: String?
    public let planTier: String?
    public let authMethod: String
    public let expiresAt: String?
    public let profileMode: CLIAuthProfileMode
    public let configDirectory: String?
    public let summary: String

    public init(
        provider: CLIAuthProviderKind,
        email: String? = nil,
        accountLabel: String? = nil,
        planTier: String? = nil,
        authMethod: String = "oauth",
        expiresAt: String? = nil,
        profileMode: CLIAuthProfileMode = .system,
        configDirectory: String? = nil,
        summary: String = ""
    ) {
        self.provider = provider
        self.email = email
        self.accountLabel = accountLabel
        self.planTier = planTier
        self.authMethod = authMethod
        self.expiresAt = expiresAt
        self.profileMode = profileMode
        self.configDirectory = configDirectory
        if !summary.isEmpty {
            self.summary = summary
        } else if let email, !email.isEmpty {
            if let planTier, !planTier.isEmpty {
                self.summary = "\(email) (\(planTier))"
            } else {
                self.summary = email
            }
        } else if let accountLabel, !accountLabel.isEmpty {
            self.summary = accountLabel
        } else {
            self.summary = "\(provider.displayName) authenticated"
        }
    }
}

public enum CLIAuthState: Sendable, Equatable {
    case unknown
    case checking
    case notInstalled
    case signedOut(detail: String?)
    case signingIn(statusMessage: String)
    case signedIn(CLIAuthIdentity)
    case error(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    public var badgeTitle: String {
        switch self {
        case .checking: return "Checking…"
        case .notInstalled: return "Not Installed"
        case .signedOut: return "Signed Out"
        case .signingIn: return "Signing In…"
        case .signedIn: return "Signed In"
        case .error: return "Auth Error"
        case .unknown: return "Unknown"
        }
    }

    public var identity: CLIAuthIdentity? {
        if case .signedIn(let id) = self { return id }
        return nil
    }
}

public enum CLIAuthStreamEvent: Sendable {
    case urlDiscovered(URL)
    case deviceCodeDiscovered(String)
    case logLine(String)
    case finished(exitCode: Int32)
}

public enum CLIAuthError: Error, Sendable, LocalizedError {
    case notInstalled(String)
    case unsupportedMethod(String)
    case invalidInput(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): return "\(name) is not installed on this Mac."
        case .unsupportedMethod(let msg): return msg
        case .invalidInput(let msg): return msg
        case .commandFailed(let msg): return msg
        }
    }
}

public final class CLIAuthLoginHandle: @unchecked Sendable {
    private struct State {
        var process: Process?
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var stdinHandle: FileHandle?
        var cancelled: Bool = false
    }

    private let lock: OSAllocatedUnfairLock<State>

    internal init(
        process: Process,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        stdinHandle: FileHandle?
    ) {
        self.lock = OSAllocatedUnfairLock(
            initialState: State(
                process: process,
                stdoutHandle: stdoutHandle,
                stderrHandle: stderrHandle,
                stdinHandle: stdinHandle,
                cancelled: false
            )
        )
    }

    public func cancel() {
        let extracted: (Process?, FileHandle?, FileHandle?, FileHandle?) = lock.withLockUnchecked { state in
            state.cancelled = true
            let proc = state.process
            let out = state.stdoutHandle
            let err = state.stderrHandle
            let inp = state.stdinHandle
            state.process = nil
            state.stdoutHandle = nil
            state.stderrHandle = nil
            state.stdinHandle = nil
            return (proc, out, err, inp)
        }

        extracted.1?.readabilityHandler = nil
        extracted.2?.readabilityHandler = nil
        try? extracted.3?.close()

        guard let process = extracted.0 else { return }
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }

        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
            if kill(-pid, 0) == 0 || kill(pid, 0) == 0 {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
        }
    }

    internal var isCancelled: Bool {
        lock.withLockUnchecked { $0.cancelled }
    }

    internal func cleanupAfterTermination() {
        let handles: (FileHandle?, FileHandle?, FileHandle?) = lock.withLockUnchecked { state in
            let out = state.stdoutHandle
            let err = state.stderrHandle
            let inp = state.stdinHandle
            state.process = nil
            state.stdoutHandle = nil
            state.stderrHandle = nil
            state.stdinHandle = nil
            return (out, err, inp)
        }
        handles.0?.readabilityHandler = nil
        handles.1?.readabilityHandler = nil
        try? handles.2?.close()
    }
}

public struct LLMAuthErrorDetector: Sendable {
    private static let authPhraseMarkers: [String] = [
        "not logged in",
        "please log in",
        "claude auth login",
        "codex login",
        "authentication required",
        "unauthorized",
        "invalid api key",
        "invalid_api_key",
        "token expired",
        "sign in",
        "no credentials",
        "login required",
        "unauthenticated",
        "session expired",
    ]

    public static func detectRequiredAuthProvider(
        from errorText: String,
        backend: LLMBackendKind
    ) -> CLIAuthProviderKind? {
        guard let provider = CLIAuthProviderKind.from(backend: backend) else {
            return nil
        }
        let lower = errorText.lowercased()
        for marker in authPhraseMarkers {
            if lower.contains(marker) {
                return provider
            }
        }
        if lower.range(of: #"\b401\b"#, options: .regularExpression) != nil {
            return provider
        }
        return nil
    }
}

public struct CLIAuthService: Sendable {
    // MARK: - Paths & Environment

    public static func isolatedDirectory(for provider: CLIAuthProviderKind) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Helm/auth/\(provider.rawValue)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    public static func standardSearchDirectories() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.gemini/antigravity-cli/bin",
        ]
    }

    public static func augmentedPATH(from existingPATH: String?) -> String {
        var seen: Set<String> = []
        var components: [String] = []
        let initial = standardSearchDirectories()
            + (existingPATH?.split(separator: ":").map(String.init) ?? [])
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for entry in initial {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            components.append(trimmed)
        }
        return components.joined(separator: ":")
    }

    public static func authEnvironment(
        for provider: CLIAuthProviderKind,
        profileMode: CLIAuthProfileMode,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = baseEnvironment
        env["PATH"] = augmentedPATH(from: env["PATH"])

        switch profileMode {
        case .helmIsolated:
            switch provider {
            case .claude:
                let dir = isolatedDirectory(for: .claude).path
                env["CLAUDE_CONFIG_DIR"] = dir
                env["HELM_CLAUDE_CONFIG_DIR"] = dir
            case .codex:
                let dir = isolatedDirectory(for: .codex).path
                env["CODEX_HOME"] = dir
                env["HELM_CODEX_HOME"] = dir
            case .pi:
                let dir = isolatedDirectory(for: .pi).path
                env["PI_CODING_AGENT_DIR"] = dir
                env["HELM_PI_CONFIG_DIR"] = dir
            case .agy:
                break
            }
        case .system:
            // Strip any Helm-isolated overrides so System Profile reads standard user config locations.
            let isolatedMarker = "/Library/Application Support/Helm/auth/"
            for key in [
                "CLAUDE_CONFIG_DIR", "HELM_CLAUDE_CONFIG_DIR",
                "CODEX_HOME", "HELM_CODEX_HOME",
                "PI_CODING_AGENT_DIR", "HELM_PI_CONFIG_DIR",
            ] {
                if let val = env[key], val.contains(isolatedMarker) {
                    env.removeValue(forKey: key)
                }
            }
        }
        return env
    }

    public static func resolveExecutable(
        for provider: CLIAuthProviderKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        let overrideKey: String
        let commandNames: [String]
        switch provider {
        case .claude:
            overrideKey = "HELM_CLAUDE_PATH"
            commandNames = ["claude"]
        case .codex:
            overrideKey = "HELM_CODEX_PATH"
            commandNames = ["codex"]
        case .agy:
            overrideKey = "HELM_AGY_PATH"
            commandNames = ["agy"]
        case .pi:
            overrideKey = "HELM_PI_PATH"
            commandNames = ["pi", "pycli"]
        }

        if let custom = environment[overrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           fm.isExecutableFile(atPath: custom) {
            return custom
        }

        let searchDirs = standardSearchDirectories()
            + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        for name in commandNames {
            for dir in searchDirs {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Deterministic Parsers & Extractors

    public static func stripANSICodes(_ text: String) -> String {
        var result = text
        // CSI sequences: ESC [ ... final byte
        result = result.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        // OSC sequences: ESC ] ... BEL or ST
        result = result.replacingOccurrences(
            of: #"\u{001B}\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\)"#,
            with: "",
            options: .regularExpression
        )
        // Remaining 2-byte ESC sequences
        result = result.replacingOccurrences(
            of: #"\u{001B}[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )
        return result
    }

    public static func parseClaudeAuthStatusJSON(
        _ raw: String,
        profileMode: CLIAuthProfileMode
    ) -> CLIAuthState {
        let cleaned = stripANSICodes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return .signedOut(detail: "Sign in to Claude Code to run agents")
        }

        let jsonString: String
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            jsonString = String(cleaned[firstBrace...lastBrace])
        } else {
            jsonString = cleaned
        }

        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let lower = cleaned.lowercased()
            if lower.contains("not logged in") || lower.contains("logged out") {
                return .signedOut(detail: "Sign in to Claude Code to run agents")
            }
            return .error("Unable to parse Claude auth status output.")
        }

        let loggedIn = (obj["loggedIn"] as? Bool) ?? false
        guard loggedIn else {
            return .signedOut(detail: "Sign in to Claude Code to run agents")
        }

        let email = nonEmptyString(obj["email"])
        let orgName = nonEmptyString(obj["orgName"]) ?? nonEmptyString(obj["organizationName"])
        let planTier = nonEmptyString(obj["planTier"]) ?? nonEmptyString(obj["subscriptionType"])
        let authMethod = nonEmptyString(obj["authMethod"]) ?? "claude.ai"
        let expiresAt = nonEmptyString(obj["loginExpiresAt"]) ?? nonEmptyString(obj["expiresAt"])
        let configDirectory = nonEmptyString(obj["configDirectory"])
            ?? (profileMode == .helmIsolated ? isolatedDirectory(for: .claude).path : nil)

        var summaryParts: [String] = []
        if let email {
            summaryParts.append(email)
        } else if let orgName {
            summaryParts.append(orgName)
        } else {
            summaryParts.append("Claude (\(authMethod))")
        }
        if let planTier {
            summaryParts.append("(\(planTier))")
        }
        let summary = summaryParts.joined(separator: " ")

        return .signedIn(CLIAuthIdentity(
            provider: .claude,
            email: email,
            accountLabel: orgName,
            planTier: planTier,
            authMethod: authMethod,
            expiresAt: expiresAt,
            profileMode: profileMode,
            configDirectory: configDirectory,
            summary: summary
        ))
    }

    public static func parseCodexLoginStatus(
        _ raw: String,
        exitCode: Int32,
        profileMode: CLIAuthProfileMode
    ) -> CLIAuthState {
        let cleaned = stripANSICodes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()

        if lower.contains("not logged in") || lower.contains("logged out") {
            return .signedOut(detail: "Sign in with ChatGPT or an OpenAI API key")
        }

        if exitCode == 0, lower.contains("logged in") {
            let authMethod: String
            let accountLabel: String?
            let summary: String
            if lower.contains("chatgpt") {
                authMethod = "chatgpt"
                accountLabel = "ChatGPT"
                summary = "Logged in using ChatGPT"
            } else if lower.contains("api key") || lower.contains("api_key") {
                authMethod = "api_key"
                accountLabel = "API Key"
                summary = "Logged in using API key"
            } else {
                authMethod = "codex"
                accountLabel = nil
                summary = cleaned.split(separator: "\n").first.map(String.init) ?? "Logged in to Codex CLI"
            }

            let configDir = profileMode == .helmIsolated ? isolatedDirectory(for: .codex).path : nil
            return .signedIn(CLIAuthIdentity(
                provider: .codex,
                email: extractEmail(from: cleaned),
                accountLabel: accountLabel,
                planTier: nil,
                authMethod: authMethod,
                expiresAt: nil,
                profileMode: profileMode,
                configDirectory: configDir,
                summary: summary
            ))
        }

        if exitCode != 0 {
            let detail = cleaned.isEmpty ? "Sign in with ChatGPT or an OpenAI API key" : cleaned
            return .signedOut(detail: detail)
        }

        return .signedOut(detail: cleaned.isEmpty ? "Sign in with ChatGPT or an OpenAI API key" : cleaned)
    }

    public static func parseAgyModelsOutput(
        _ raw: String,
        exitCode: Int32,
        profileMode: CLIAuthProfileMode
    ) -> CLIAuthState {
        let cleaned = stripANSICodes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()

        if exitCode != 0
            || lower.contains("not logged in")
            || lower.contains("sign in")
            || lower.contains("unauthorized")
            || lower.contains("authentication required")
            || lower.contains("login required") {
            let detail = cleaned.isEmpty ? "Sign in to Antigravity CLI (agy)" : cleaned
            return .signedOut(detail: detail)
        }

        var modelCount = 0
        let knownPrefixes = ["gemini-", "claude-", "gpt-", "o1", "o3", "o4", "deepseek-", "llama-", "qwen-"]
        for rawLine in cleaned.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let lowerLine = line.lowercased()
            if lowerLine.hasPrefix("id\t")
                || lowerLine.hasPrefix("model\t")
                || lowerLine.hasPrefix("name\t")
                || lowerLine.hasPrefix("available models")
                || lowerLine.allSatisfy({ $0 == "-" || $0 == "=" || $0 == " " || $0 == "\t" }) {
                continue
            }
            if line.contains("\t") {
                modelCount += 1
            } else if knownPrefixes.contains(where: { lowerLine.hasPrefix($0) || lowerLine.contains($0) }) {
                modelCount += 1
            }
        }

        if modelCount > 0 {
            return .signedIn(CLIAuthIdentity(
                provider: .agy,
                email: nil,
                accountLabel: "Antigravity",
                planTier: nil,
                authMethod: "oauth",
                expiresAt: nil,
                profileMode: profileMode,
                configDirectory: nil,
                summary: "Antigravity authenticated (\(modelCount) models)"
            ))
        }

        return .signedOut(detail: "Sign in to Antigravity CLI (agy) to access models")
    }

    public static func checkPiAuthStatus(
        profileMode: CLIAuthProfileMode,
        environment: [String: String]
    ) -> CLIAuthState {
        let configDir = activePiConfigDirectory(profileMode: profileMode, environment: environment)
        let authFile = configDir.appendingPathComponent("auth.json")

        if let data = try? Data(contentsOf: authFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var providers: [String] = []
            for (key, value) in obj {
                if let str = value as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    providers.append(key)
                } else if let dict = value as? [String: Any] {
                    let hasCred = ["key", "apiKey", "api_key", "access", "token", "access_token"]
                        .contains { nonEmptyString(dict[$0]) != nil }
                    if hasCred {
                        providers.append(key)
                    }
                }
            }
            let sorted = providers.sorted()
            if !sorted.isEmpty {
                let label = sorted.joined(separator: ", ")
                return .signedIn(CLIAuthIdentity(
                    provider: .pi,
                    email: nil,
                    accountLabel: label,
                    planTier: nil,
                    authMethod: "auth.json",
                    expiresAt: nil,
                    profileMode: profileMode,
                    configDirectory: configDir.path,
                    summary: "Pi authenticated (\(label))"
                ))
            }
        }

        let envKeys = [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "GEMINI_API_KEY",
            "OPENROUTER_API_KEY",
            "HELM_LLM_API_KEY",
        ]
        for key in envKeys {
            if let val = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                return .signedIn(CLIAuthIdentity(
                    provider: .pi,
                    email: nil,
                    accountLabel: key,
                    planTier: nil,
                    authMethod: "env_api_key",
                    expiresAt: nil,
                    profileMode: profileMode,
                    configDirectory: configDir.path,
                    summary: "Authenticated via \(key)"
                ))
            }
        }

        return .signedOut(detail: "Add an API key for Pi CLI (Anthropic, OpenAI, Gemini, or OpenRouter)")
    }

    public static func extractFirstURL(from text: String) -> URL? {
        let cleaned = stripANSICodes(text)
        let pattern = #"(?:https://|http://(?:localhost|127\.0\.0\.1)(?::\d+)?)[^\s<>"'`]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
              let swiftRange = Range(match.range, in: cleaned) else {
            return nil
        }
        var rawURL = String(cleaned[swiftRange])
        let trailingPunctuation = CharacterSet(charactersIn: ").,]>'\"`;")
        while let last = rawURL.unicodeScalars.last, trailingPunctuation.contains(last) {
            rawURL.removeLast()
        }
        return URL(string: rawURL)
    }

    public static func extractDeviceCode(from text: String) -> String? {
        let cleaned = stripANSICodes(text)
        // Strip URLs first so query parameters or URL slugs are never mistaken for device codes.
        let withoutURLs = cleaned.replacingOccurrences(
            of: #"https?://[^\s<>"'`]+"#,
            with: " ",
            options: .regularExpression
        )
        // Strip UUIDs explicitly so segments of UUIDs cannot match.
        let withoutUUIDs = withoutURLs.replacingOccurrences(
            of: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            with: " ",
            options: .regularExpression
        )

        let pattern = #"(?<![A-Za-z0-9-])([A-Z0-9]{4,5}-[A-Z0-9]{4,5})(?![A-Za-z0-9-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(withoutUUIDs.startIndex..<withoutUUIDs.endIndex, in: withoutUUIDs)
        for match in regex.matches(in: withoutUUIDs, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let codeRange = Range(match.range(at: 1), in: withoutUUIDs) else {
                continue
            }
            let candidate = String(withoutUUIDs[codeRange])
            // Require at least one uppercase letter to avoid matching pure numeric year/port pairs.
            if candidate.contains(where: { $0.isLetter }) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Async Status, Sign-Out, API Key & Interactive Browser Login

    public static func checkStatus(
        for provider: CLIAuthProviderKind,
        profileMode: CLIAuthProfileMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> CLIAuthState {
        let env = authEnvironment(for: provider, profileMode: profileMode, baseEnvironment: environment)
        guard let execPath = resolveExecutable(for: provider, environment: env) else {
            return .notInstalled
        }

        switch provider {
        case .pi:
            return checkPiAuthStatus(profileMode: profileMode, environment: env)

        case .claude:
            do {
                let output = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: execPath),
                    arguments: ["auth", "status", "--json"],
                    environment: env,
                    timeoutSeconds: 6
                )
                let combined = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? output.stderr
                    : output.stdout
                return parseClaudeAuthStatusJSON(combined, profileMode: profileMode)
            } catch let err as ProcessRunnerError {
                if case .timedOut = err {
                    return .error("Timed out checking Claude CLI auth status.")
                }
                return .error(err.localizedDescription)
            } catch {
                return .error(error.localizedDescription)
            }

        case .codex:
            do {
                let output = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: execPath),
                    arguments: ["login", "status"],
                    environment: env,
                    timeoutSeconds: 6
                )
                let combined = [output.stdout, output.stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return parseCodexLoginStatus(combined, exitCode: output.exitCode, profileMode: profileMode)
            } catch let err as ProcessRunnerError {
                if case .timedOut = err {
                    return .error("Timed out checking Codex CLI auth status.")
                }
                return .error(err.localizedDescription)
            } catch {
                return .error(error.localizedDescription)
            }

        case .agy:
            do {
                let output = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: execPath),
                    arguments: ["models"],
                    environment: env,
                    timeoutSeconds: 6
                )
                let combined = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? output.stderr
                    : output.stdout
                return parseAgyModelsOutput(combined, exitCode: output.exitCode, profileMode: profileMode)
            } catch let err as ProcessRunnerError {
                if case .timedOut = err {
                    return .error("Timed out checking Antigravity CLI status.")
                }
                return .error(err.localizedDescription)
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }

    public static func signOut(
        provider: CLIAuthProviderKind,
        profileMode: CLIAuthProfileMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let env = authEnvironment(for: provider, profileMode: profileMode, baseEnvironment: environment)

        switch provider {
        case .claude:
            guard let execPath = resolveExecutable(for: .claude, environment: env) else {
                throw CLIAuthError.notInstalled(provider.displayName)
            }
            let output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: execPath),
                arguments: ["auth", "logout"],
                environment: env,
                timeoutSeconds: 10
            )
            if output.exitCode != 0 {
                let msg = stripANSICodes(output.stderr.isEmpty ? output.stdout : output.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIAuthError.commandFailed(msg.isEmpty ? "Claude logout failed (exit \(output.exitCode))." : msg)
            }

        case .codex:
            guard let execPath = resolveExecutable(for: .codex, environment: env) else {
                throw CLIAuthError.notInstalled(provider.displayName)
            }
            let output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: execPath),
                arguments: ["logout"],
                environment: env,
                timeoutSeconds: 10
            )
            if output.exitCode != 0 {
                let msg = stripANSICodes(output.stderr.isEmpty ? output.stdout : output.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIAuthError.commandFailed(msg.isEmpty ? "Codex logout failed (exit \(output.exitCode))." : msg)
            }

        case .pi:
            let configDir = activePiConfigDirectory(profileMode: profileMode, environment: env)
            let authFile = configDir.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: authFile.path) {
                try FileManager.default.removeItem(at: authFile)
            }

        case .agy:
            throw CLIAuthError.unsupportedMethod("Antigravity CLI (agy) does not support direct sign-out from Helm.")
        }
    }

    public static func signInWithAPIKey(
        provider: CLIAuthProviderKind,
        apiKey: String,
        profileMode: CLIAuthProfileMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw CLIAuthError.invalidInput("API key cannot be empty.")
        }

        let env = authEnvironment(for: provider, profileMode: profileMode, baseEnvironment: environment)

        switch provider {
        case .codex:
            guard let execPath = resolveExecutable(for: .codex, environment: env) else {
                throw CLIAuthError.notInstalled(provider.displayName)
            }
            let output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: execPath),
                arguments: ["login", "--with-api-key"],
                environment: env,
                stdinData: Data((trimmedKey + "\n").utf8),
                timeoutSeconds: 15
            )
            if output.exitCode != 0 {
                let msg = stripANSICodes(output.stderr.isEmpty ? output.stdout : output.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIAuthError.commandFailed(msg.isEmpty ? "Codex API key login failed (exit \(output.exitCode))." : msg)
            }

        case .pi:
            let configDir = activePiConfigDirectory(profileMode: profileMode, environment: env)
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let authFile = configDir.appendingPathComponent("auth.json")

            var existing: [String: Any] = [:]
            if let data = try? Data(contentsOf: authFile),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existing = parsed
            }

            let vendor: String
            let envVar: String
            if trimmedKey.hasPrefix("sk-ant-") {
                vendor = "anthropic"
                envVar = "ANTHROPIC_API_KEY"
            } else if trimmedKey.hasPrefix("sk-or-") {
                vendor = "openrouter"
                envVar = "OPENROUTER_API_KEY"
            } else if trimmedKey.hasPrefix("AIza") {
                vendor = "google"
                envVar = "GEMINI_API_KEY"
            } else {
                vendor = "openai"
                envVar = "OPENAI_API_KEY"
            }

            existing[vendor] = [
                "type": "api_key",
                "key": trimmedKey,
            ]

            let encoded = try JSONSerialization.data(
                withJSONObject: existing,
                options: [.prettyPrinted, .sortedKeys]
            )
            try encoded.write(to: authFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)

            setenv(envVar, trimmedKey, 1)
            setenv("HELM_LLM_API_KEY", trimmedKey, 1)

        case .claude, .agy:
            throw CLIAuthError.unsupportedMethod("\(provider.displayName) does not support API key login.")
        }
    }

    public static func startLoginSession(
        provider: CLIAuthProviderKind,
        method: CLIAuthLoginMethod,
        emailHint: String?,
        profileMode: CLIAuthProfileMode,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onEvent: @escaping @Sendable (CLIAuthStreamEvent) -> Void
    ) throws -> CLIAuthLoginHandle {
        let env = authEnvironment(for: provider, profileMode: profileMode, baseEnvironment: environment)
        guard let execPath = resolveExecutable(for: provider, environment: env) else {
            throw CLIAuthError.notInstalled(provider.displayName)
        }

        let args: [String]
        switch (provider, method) {
        case (.claude, .browserOAuth):
            var a = ["auth", "login", "--claudeai"]
            if let hint = emailHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                a.append(contentsOf: ["--email", hint])
            }
            args = a

        case (.claude, .claudeConsole):
            var a = ["auth", "login", "--console"]
            if let hint = emailHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                a.append(contentsOf: ["--email", hint])
            }
            args = a

        case (.claude, .claudeSSO):
            var a = ["auth", "login", "--sso"]
            if let hint = emailHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                a.append(contentsOf: ["--email", hint])
            }
            args = a

        case (.codex, .browserOAuth):
            args = ["login"]

        case (.codex, .deviceCode):
            args = ["login", "--device-auth"]

        case (.agy, .browserOAuth):
            args = ["--print", "Reply with OK", "--print-timeout", "15s"]

        default:
            throw CLIAuthError.unsupportedMethod("\(provider.displayName) does not support \(method.title).")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = args
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        #if canImport(Darwin)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let handle = CLIAuthLoginHandle(
            process: process,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading,
            stdinHandle: stdinPipe.fileHandleForWriting
        )

        final class StreamState: @unchecked Sendable {
            private let lock = OSAllocatedUnfairLock(initialState: Inner())
            private struct Inner: Sendable {
                var stdoutPartial = ""
                var stderrPartial = ""
                var discoveredAnyURL = false
                var didFinish = false
            }

            func consume(chunk: Data, isStdout: Bool, emit: (String) -> Void) {
                let text = String(decoding: chunk, as: UTF8.self)
                let lines: [String] = lock.withLock { inner in
                    var buffer = isStdout ? inner.stdoutPartial : inner.stderrPartial
                    buffer.append(text)
                    var emitted: [String] = []
                    while let idx = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                        let line = String(buffer[..<idx])
                        let next = buffer.index(after: idx)
                        buffer.removeSubrange(buffer.startIndex..<next)
                        emitted.append(line)
                    }
                    if isStdout {
                        inner.stdoutPartial = buffer
                    } else {
                        inner.stderrPartial = buffer
                    }
                    return emitted
                }
                for line in lines {
                    emit(line)
                }
            }

            func flush(isStdout: Bool, emit: (String) -> Void) {
                let remainder: String = lock.withLock { inner in
                    if isStdout {
                        let rem = inner.stdoutPartial
                        inner.stdoutPartial = ""
                        return rem
                    } else {
                        let rem = inner.stderrPartial
                        inner.stderrPartial = ""
                        return rem
                    }
                }
                if !remainder.isEmpty {
                    emit(remainder)
                }
            }

            func markURLDiscovered() {
                lock.withLock { $0.discoveredAnyURL = true }
            }

            var hasDiscoveredURL: Bool {
                lock.withLock { $0.discoveredAnyURL }
            }

            func claimFinish() -> Bool {
                lock.withLock { inner in
                    if inner.didFinish { return false }
                    inner.didFinish = true
                    return true
                }
            }
        }

        let streamState = StreamState()

        let processLine: @Sendable (String) -> Void = { rawLine in
            let clean = stripANSICodes(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            onEvent(.logLine(clean))
            if let url = extractFirstURL(from: clean) {
                streamState.markURLDiscovered()
                onEvent(.urlDiscovered(url))
            }
            if let code = extractDeviceCode(from: clean) {
                onEvent(.deviceCodeDiscovered(code))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                streamState.flush(isStdout: true, emit: processLine)
            } else {
                streamState.consume(chunk: chunk, isStdout: true, emit: processLine)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                streamState.flush(isStdout: false, emit: processLine)
            } else {
                streamState.consume(chunk: chunk, isStdout: false, emit: processLine)
            }
        }

        process.terminationHandler = { proc in
            handle.cleanupAfterTermination()
            streamState.flush(isStdout: true, emit: processLine)
            streamState.flush(isStdout: false, emit: processLine)

            if provider == .agy && proc.terminationStatus != 0 && !streamState.hasDiscoveredURL && !handle.isCancelled {
                onEvent(.logLine("Antigravity CLI requires an interactive terminal sign-in. Click 'Open in Terminal' to authenticate."))
            }

            if streamState.claimFinish() {
                onEvent(.finished(exitCode: proc.terminationStatus))
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            handle.cleanupAfterTermination()
            throw CLIAuthError.commandFailed("Failed to launch \(provider.displayName): \(error.localizedDescription)")
        }

        let pid = process.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
        }

        return handle
    }

    // MARK: - Private Helpers

    private static func activePiConfigDirectory(
        profileMode: CLIAuthProfileMode,
        environment: [String: String]
    ) -> URL {
        if profileMode == .helmIsolated {
            return isolatedDirectory(for: .pi)
        }
        if let dir = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractEmail(from text: String) -> String? {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
