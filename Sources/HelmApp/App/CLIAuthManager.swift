import AppKit
import Foundation
import HelmCore
import Observation

public enum CLIAuthLoginPhase: Equatable, Sendable {
    case idle
    case launching
    case awaitingBrowser
    case verifying
    case succeeded(CLIAuthIdentity)
    case failed(String)
    case cancelled
}

@MainActor
@Observable
public final class CLIAuthManager {
    public private(set) var states: [CLIAuthProviderKind: CLIAuthState]
    public var profileMode: CLIAuthProfileMode
    public var forwardCredentialsToSandbox: Bool

    public var showSignInSheet: Bool = false
    public private(set) var activeLoginProvider: CLIAuthProviderKind?
    public private(set) var activeLoginMethod: CLIAuthLoginMethod?
    public private(set) var activeLoginPhase: CLIAuthLoginPhase = .idle
    public private(set) var discoveredAuthURL: URL?
    public private(set) var discoveredDeviceCode: String?
    public private(set) var liveLogLines: [String] = []
    public private(set) var didAutoOpenBrowser: Bool = false
    public private(set) var lastError: String?

    private let isHeadless: Bool
    private var activeLoginHandle: CLIAuthLoginHandle?
    private var activeLoginGeneration: UInt64 = 0
    private var refreshAllTask: Task<Void, Never>?
    private var providerRefreshTasks: [CLIAuthProviderKind: Task<Void, Never>] = [:]
    private var backgroundPollTask: Task<Void, Never>?

    private static let profileModeKey = "helm.v1.cliAuthProfileMode"
    private static let forwardSandboxAuthKey = "helm.v1.forwardSandboxAuth"
    private static let maxLogLines = 80

    public init(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.isHeadless = arguments.contains("--headless") || environment["HELM_DISABLE_AUTH_PROBE"] == "1"

        var initialStates: [CLIAuthProviderKind: CLIAuthState] = [:]
        for kind in CLIAuthProviderKind.allCases {
            initialStates[kind] = .unknown
        }
        self.states = initialStates

        if let rawMode = UserDefaults.standard.string(forKey: Self.profileModeKey),
           let savedMode = CLIAuthProfileMode(rawValue: rawMode) {
            self.profileMode = savedMode
        } else {
            self.profileMode = .system
        }

        self.forwardCredentialsToSandbox = UserDefaults.standard.bool(forKey: Self.forwardSandboxAuthKey)

        applyProfileEnvironment()
        applySandboxAuthEnvironment()
    }

    // MARK: - Queries & Profile Configuration

    public func state(for provider: CLIAuthProviderKind) -> CLIAuthState {
        states[provider] ?? .unknown
    }

    public func setProfileMode(_ mode: CLIAuthProfileMode) {
        profileMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.profileModeKey)
        applyProfileEnvironment()
        refreshAllStatuses()
    }

    public func setForwardCredentialsToSandbox(_ enabled: Bool) {
        forwardCredentialsToSandbox = enabled
        UserDefaults.standard.set(enabled, forKey: Self.forwardSandboxAuthKey)
        applySandboxAuthEnvironment()
    }

    // MARK: - Status Probing

    public func refreshAllStatuses() {
        guard !isHeadless else { return }
        refreshAllTask?.cancel()
        for task in providerRefreshTasks.values {
            task.cancel()
        }
        providerRefreshTasks.removeAll()

        let currentMode = profileMode
        for provider in CLIAuthProviderKind.allCases {
            if case .signingIn = states[provider] {
                continue
            }
            states[provider] = .checking
        }

        refreshAllTask = Task { [weak self] in
            let results = await withTaskGroup(of: (CLIAuthProviderKind, CLIAuthState).self) { group in
                for provider in CLIAuthProviderKind.allCases {
                    group.addTask {
                        let status = await CLIAuthService.checkStatus(for: provider, profileMode: currentMode)
                        return (provider, status)
                    }
                }
                var collected: [(CLIAuthProviderKind, CLIAuthState)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }
            guard !Task.isCancelled, let self else { return }
            for (provider, status) in results {
                if case .signingIn = self.states[provider], self.activeLoginProvider == provider {
                    continue
                }
                self.states[provider] = status
            }
        }
    }

    public func refreshStatus(for provider: CLIAuthProviderKind) {
        guard !isHeadless else { return }
        providerRefreshTasks[provider]?.cancel()
        let currentMode = profileMode
        if case .signingIn = states[provider] {
            // Keep signing-in badge while login sheet is actively running
        } else {
            states[provider] = .checking
        }

        providerRefreshTasks[provider] = Task { [weak self] in
            let status = await CLIAuthService.checkStatus(for: provider, profileMode: currentMode)
            guard !Task.isCancelled, let self else { return }
            self.states[provider] = status
            self.providerRefreshTasks.removeValue(forKey: provider)
        }
    }

    // MARK: - Interactive Login Lifecycle

    public func beginLogin(
        provider: CLIAuthProviderKind,
        method: CLIAuthLoginMethod = .browserOAuth,
        emailHint: String? = nil
    ) {
        stopActiveLoginProcessesOnly()
        activeLoginGeneration &+= 1
        let generation = activeLoginGeneration

        showSignInSheet = true
        activeLoginProvider = provider
        activeLoginMethod = method
        discoveredAuthURL = nil
        discoveredDeviceCode = nil
        liveLogLines = []
        didAutoOpenBrowser = false
        lastError = nil

        if method == .apiKey {
            activeLoginPhase = .idle
            return
        }

        activeLoginPhase = .launching
        states[provider] = .signingIn(statusMessage: "Launching \(provider.displayName)…")

        let currentMode = profileMode
        do {
            let handle = try CLIAuthService.startLoginSession(
                provider: provider,
                method: method,
                emailHint: emailHint,
                profileMode: currentMode
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleStreamEvent(event, provider: provider, generation: generation, profileMode: currentMode)
                }
            }
            activeLoginHandle = handle
        } catch {
            let message = error.localizedDescription
            lastError = message
            activeLoginPhase = .failed(message)
            states[provider] = .error(message)
        }
    }

    public func submitAPIKeyLogin(provider: CLIAuthProviderKind, apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let msg = "Please enter an API key."
            lastError = msg
            activeLoginPhase = .failed(msg)
            return
        }

        stopActiveLoginProcessesOnly()
        activeLoginGeneration &+= 1
        let generation = activeLoginGeneration

        activeLoginProvider = provider
        activeLoginMethod = .apiKey
        activeLoginPhase = .verifying
        lastError = nil
        states[provider] = .signingIn(statusMessage: "Saving API key…")

        let currentMode = profileMode
        do {
            try await CLIAuthService.signInWithAPIKey(
                provider: provider,
                apiKey: trimmed,
                profileMode: currentMode
            )
            guard activeLoginGeneration == generation else { return }

            let verified = await CLIAuthService.checkStatus(for: provider, profileMode: currentMode)
            guard activeLoginGeneration == generation else { return }
            states[provider] = verified

            if case .signedIn(let identity) = verified {
                activeLoginPhase = .succeeded(identity)
            } else {
                let msg = "API key was saved, but \(provider.displayName) still reports signed out."
                lastError = msg
                activeLoginPhase = .failed(msg)
            }
        } catch {
            guard activeLoginGeneration == generation else { return }
            let msg = error.localizedDescription
            lastError = msg
            activeLoginPhase = .failed(msg)
            states[provider] = .error(msg)
        }
    }

    public func signOut(provider: CLIAuthProviderKind) async {
        lastError = nil
        states[provider] = .checking
        let currentMode = profileMode
        do {
            try await CLIAuthService.signOut(provider: provider, profileMode: currentMode)
            if isHeadless {
                states[provider] = .signedOut(detail: "Signed out")
            } else {
                let verified = await CLIAuthService.checkStatus(for: provider, profileMode: currentMode)
                states[provider] = verified
            }
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            states[provider] = .error(msg)
        }
    }

    public func cancelActiveLogin() {
        activeLoginGeneration &+= 1
        stopActiveLoginProcessesOnly()

        switch activeLoginPhase {
        case .launching, .awaitingBrowser, .verifying:
            activeLoginPhase = .cancelled
        case .idle, .succeeded, .failed, .cancelled:
            break
        }

        if let provider = activeLoginProvider,
           case .signingIn = states[provider] {
            states[provider] = .signedOut(detail: "Sign-in cancelled")
        }
    }

    public func dismissSignInSheet() {
        if activeLoginHandle != nil || backgroundPollTask != nil {
            cancelActiveLogin()
        }
        showSignInSheet = false
    }

    // MARK: - Browser, Clipboard & Terminal Helpers

    public func openDiscoveredURLInBrowser() {
        guard !isHeadless, let url = discoveredAuthURL else { return }
        NSWorkspace.shared.open(url)
    }

    public func copyDiscoveredURL() {
        guard let url = discoveredAuthURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    public func copyDeviceCode() {
        guard let code = discoveredDeviceCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    public func openTerminalLoginFallback(for provider: CLIAuthProviderKind) {
        guard !isHeadless else { return }

        let currentMode = profileMode
        let env = CLIAuthService.authEnvironment(for: provider, profileMode: currentMode)
        let resolvedExec = CLIAuthService.resolveExecutable(for: provider, environment: env) ?? provider.commandName

        var exportLines: [String] = [
            "export PATH=\(shellQuote(env["PATH"] ?? CLIAuthService.augmentedPATH(from: nil)))",
        ]
        if currentMode == .helmIsolated {
            switch provider {
            case .claude:
                if let dir = env["CLAUDE_CONFIG_DIR"] {
                    exportLines.append("export CLAUDE_CONFIG_DIR=\(shellQuote(dir))")
                }
            case .codex:
                if let dir = env["CODEX_HOME"] {
                    exportLines.append("export CODEX_HOME=\(shellQuote(dir))")
                }
            case .pi:
                if let dir = env["PI_CODING_AGENT_DIR"] {
                    exportLines.append("export PI_CODING_AGENT_DIR=\(shellQuote(dir))")
                }
            case .agy:
                break
            }
        }

        let loginCommand: String
        switch provider {
        case .claude:
            loginCommand = "\(shellQuote(resolvedExec)) auth login"
        case .codex:
            loginCommand = "\(shellQuote(resolvedExec)) login"
        case .agy:
            loginCommand = "\(shellQuote(resolvedExec))"
        case .pi:
            loginCommand = "\(shellQuote(resolvedExec))"
        }

        let script = """
        #!/bin/zsh
        \(exportLines.joined(separator: "\n"))
        echo "Helm — Signing in to \(provider.displayName) (\(currentMode.displayName))"
        echo ""
        \(loginCommand)
        STATUS=$?
        echo ""
        if [ "$STATUS" -eq 0 ]; then
          echo "Sign-in finished. You can return to Helm and close this window."
        else
          echo "Command exited with status $STATUS. Check the output above."
        fi
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm_login_\(provider.rawValue)_\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)

            if showSignInSheet, activeLoginProvider == provider {
                activeLoginPhase = .awaitingBrowser
                appendLogLine("Opened Terminal.app fallback for \(provider.displayName).")
                startBackgroundAuthPoll(provider: provider, generation: activeLoginGeneration, profileMode: currentMode)
            }
        } catch {
            let msg = "Could not open Terminal login fallback: \(error.localizedDescription)"
            lastError = msg
            appendLogLine(msg)
        }
    }

    // MARK: - Private Event Handling & Polling

    private func handleStreamEvent(
        _ event: CLIAuthStreamEvent,
        provider: CLIAuthProviderKind,
        generation: UInt64,
        profileMode: CLIAuthProfileMode
    ) {
        guard activeLoginGeneration == generation else { return }

        switch event {
        case .logLine(let line):
            appendLogLine(line)

        case .urlDiscovered(let url):
            discoveredAuthURL = url
            if activeLoginPhase == .launching || activeLoginPhase == .idle {
                activeLoginPhase = .awaitingBrowser
            }
            states[provider] = .signingIn(statusMessage: "Complete sign-in in your browser")
            if !didAutoOpenBrowser && !isHeadless {
                didAutoOpenBrowser = true
                NSWorkspace.shared.open(url)
            }
            startBackgroundAuthPoll(provider: provider, generation: generation, profileMode: profileMode)

        case .deviceCodeDiscovered(let code):
            discoveredDeviceCode = code
            if activeLoginPhase == .launching || activeLoginPhase == .idle {
                activeLoginPhase = .awaitingBrowser
            }
            states[provider] = .signingIn(statusMessage: "Enter device code \(code) in your browser")
            startBackgroundAuthPoll(provider: provider, generation: generation, profileMode: profileMode)

        case .finished(let exitCode):
            backgroundPollTask?.cancel()
            backgroundPollTask = nil
            activeLoginHandle = nil

            if activeLoginPhase == .cancelled { return }
            if case .succeeded = activeLoginPhase { return }

            activeLoginPhase = .verifying
            states[provider] = .checking

            Task { [weak self] in
                let verified = await CLIAuthService.checkStatus(for: provider, profileMode: profileMode)
                guard let self, self.activeLoginGeneration == generation else { return }
                self.states[provider] = verified
                if case .signedIn(let identity) = verified {
                    self.activeLoginPhase = .succeeded(identity)
                } else {
                    let detail = self.liveLogLines.last
                        ?? "Sign-in did not complete (exit code \(exitCode))."
                    self.lastError = detail
                    self.activeLoginPhase = .failed(detail)
                }
            }
        }
    }

    private func startBackgroundAuthPoll(
        provider: CLIAuthProviderKind,
        generation: UInt64,
        profileMode: CLIAuthProfileMode
    ) {
        guard !isHeadless, backgroundPollTask == nil else { return }
        backgroundPollTask = Task { [weak self] in
            // Poll gently every 2.5s for up to 3 minutes (72 ticks)
            for _ in 0..<72 {
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled, let self else { break }
                guard self.activeLoginGeneration == generation else { break }
                guard self.activeLoginPhase == .awaitingBrowser else { break }

                let status = await CLIAuthService.checkStatus(for: provider, profileMode: profileMode)
                guard !Task.isCancelled, self.activeLoginGeneration == generation else { break }

                if case .signedIn(let identity) = status {
                    self.activeLoginHandle?.cancel()
                    self.activeLoginHandle = nil
                    self.states[provider] = .signedIn(identity)
                    self.activeLoginPhase = .succeeded(identity)
                    break
                }
            }
            if let self, self.activeLoginGeneration == generation {
                self.backgroundPollTask = nil
            }
        }
    }

    private func stopActiveLoginProcessesOnly() {
        backgroundPollTask?.cancel()
        backgroundPollTask = nil
        activeLoginHandle?.cancel()
        activeLoginHandle = nil
    }

    private func appendLogLine(_ line: String) {
        liveLogLines.append(line)
        if liveLogLines.count > Self.maxLogLines {
            liveLogLines.removeFirst(liveLogLines.count - Self.maxLogLines)
        }
    }

    // MARK: - Environment Management

    private func applyProfileEnvironment() {
        switch profileMode {
        case .helmIsolated:
            let claudeDir = CLIAuthService.isolatedDirectory(for: .claude).path
            let codexDir = CLIAuthService.isolatedDirectory(for: .codex).path
            let piDir = CLIAuthService.isolatedDirectory(for: .pi).path

            setenv("CLAUDE_CONFIG_DIR", claudeDir, 1)
            setenv("HELM_CLAUDE_CONFIG_DIR", claudeDir, 1)
            setenv("CODEX_HOME", codexDir, 1)
            setenv("HELM_CODEX_HOME", codexDir, 1)
            setenv("PI_CODING_AGENT_DIR", piDir, 1)
            setenv("HELM_PI_CONFIG_DIR", piDir, 1)

        case .system:
            let current = ProcessInfo.processInfo.environment
            let isolatedMarker = "/Library/Application Support/Helm/auth/"
            for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR"] {
                if let val = current[key], val.contains(isolatedMarker) {
                    unsetenv(key)
                }
            }
            unsetenv("HELM_CLAUDE_CONFIG_DIR")
            unsetenv("HELM_CODEX_HOME")
            unsetenv("HELM_PI_CONFIG_DIR")
        }
    }

    private func applySandboxAuthEnvironment() {
        if forwardCredentialsToSandbox {
            setenv("HELM_FORWARD_SANDBOX_AUTH", "1", 1)
        } else {
            unsetenv("HELM_FORWARD_SANDBOX_AUTH")
        }
    }

    private func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
