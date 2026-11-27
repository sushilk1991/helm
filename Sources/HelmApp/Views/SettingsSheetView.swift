import AppKit
import HelmCore
import SwiftUI

public struct SettingsSheetView: View {
    @Bindable var store: HelmWorkspaceStore
    @Environment(\.dismiss) private var dismiss

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case sandbox = "Sandbox & VM"
        case general = "Updates"
        var id: String { rawValue }
    }

    @State private var activeTab: SettingsTab = .accounts
    @State private var defaultBackend: LLMBackendKind = .claudeCLI
    @State private var claudePath: String = ""
    @State private var codexPath: String = ""
    @State private var agyPath: String = ""
    @State private var piPath: String = ""
    @State private var apiBaseURL: String = ""
    @State private var apiKey: String = ""
    @State private var justSaved: Bool = false

    // Inline API key inputs for Codex / Pi
    @State private var expandedAPIKeyProvider: CLIAuthProviderKind?
    @State private var inlineAPIKeyDraft: String = ""
    @State private var busyProviders: Set<CLIAuthProviderKind> = []

    // Collapsible custom binary path disclosures (collapsed unless non-empty)
    @State private var expandedBinaryPaths: Set<CLIAuthProviderKind> = []

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    private var auth: CLIAuthManager {
        store.cliAuthManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                CompassHelmLogo(size: 30, style: .emblem)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helm Settings")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(HelmInk.primary)
                    Text("CLI accounts, sandbox isolation & updates")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Picker("", selection: $activeTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 310)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider().overlay(HelmSurface.line)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch activeTab {
                        case .accounts:
                            accountsAndCLIsSection
                        case .sandbox:
                            sandboxAndVMSection
                        case .general:
                            generalSettingsSection
                        }
                    }
                    .padding(22)
                }
                .onAppear {
                    if let highlighted = store.highlightedAuthProvider {
                        activeTab = .accounts
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            withAnimation(HelmMotion.state) {
                                proxy.scrollTo(highlighted, anchor: .center)
                            }
                        }
                    }
                }
                .onChange(of: store.highlightedAuthProvider) { _, highlighted in
                    if let highlighted {
                        activeTab = .accounts
                        withAnimation(HelmMotion.state) {
                            proxy.scrollTo(highlighted, anchor: .center)
                        }
                    }
                }
            }

            Divider().overlay(HelmSurface.line)

            // Footer
            HStack {
                if justSaved {
                    Label("Settings saved", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HelmSemantic.steady)
                } else {
                    Button {
                        store.saveCLISettings(
                            defaultBackend: defaultBackend,
                            claudePath: claudePath,
                            codexPath: codexPath,
                            agyPath: agyPath,
                            piPath: piPath,
                            apiBaseURL: apiBaseURL,
                            apiKey: apiKey
                        )
                        auth.refreshAllStatuses()
                    } label: {
                        Label("Re-scan CLIs", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    store.saveCLISettings(
                        defaultBackend: defaultBackend,
                        claudePath: claudePath,
                        codexPath: codexPath,
                        agyPath: agyPath,
                        piPath: piPath,
                        apiBaseURL: apiBaseURL,
                        apiKey: apiKey
                    )
                    justSaved = true
                    dismiss()
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 660)
        .background(HelmSurface.canvas)
        .onAppear {
            defaultBackend = store.defaultBackend
            claudePath = store.claudeCLIPath
            codexPath = store.codexCLIPath
            agyPath = store.agyCLIPath
            piPath = store.piCLIPath
            apiBaseURL = store.apiBaseURL
            apiKey = store.apiKeyInput

            var preExpanded: Set<CLIAuthProviderKind> = []
            if !store.claudeCLIPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preExpanded.insert(.claude) }
            if !store.codexCLIPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preExpanded.insert(.codex) }
            if !store.agyCLIPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preExpanded.insert(.agy) }
            if !store.piCLIPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preExpanded.insert(.pi) }
            expandedBinaryPaths = preExpanded

            if store.highlightedAuthProvider != nil {
                activeTab = .accounts
            }

            store.rescanEnvironment()
            auth.refreshAllStatuses()
        }
        .onDisappear {
            store.highlightedAuthProvider = nil
        }
        .sheet(isPresented: Binding(
            get: { store.cliAuthManager.showSignInSheet },
            set: { newValue in
                if newValue {
                    store.cliAuthManager.showSignInSheet = true
                } else {
                    store.cliAuthManager.dismissSignInSheet()
                }
            }
        )) {
            CLIAuthSignInSheet(authManager: store.cliAuthManager)
        }
    }

    // MARK: - Tab 1: Accounts & CLIs

    private var accountsAndCLIsSection: some View {
        let env = store.environmentStatus
        let signedInCount = CLIAuthProviderKind.allCases.filter { auth.state(for: $0).isSignedIn }.count

        return VStack(alignment: .leading, spacing: 16) {
            // Login Profile Mode Banner Card
            profileIsolationBannerCard

            // Default Provider row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default AI Engine for New Projects")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text("You can also switch any individual agent's CLI anytime from its card or the Inspector.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }
                Spacer(minLength: 12)
                Picker("Default Engine", selection: $defaultBackend) {
                    ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
            }
            .padding(14)
            .helmCard(cornerRadius: HelmRadius.panel)

            // Local Coding Agent CLIs & Accounts
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Local Coding CLIs")
                        .font(.headline)
                        .foregroundStyle(HelmInk.primary)

                    Text("\(signedInCount) of \(CLIAuthProviderKind.allCases.count) signed in")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(signedInCount > 0 ? HelmSemantic.steady : HelmInk.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(signedInCount > 0 ? HelmSemantic.steadySoft : HelmSurface.well, in: Capsule())

                    Spacer()
                }

                cliAccountCard(
                    provider: .claude,
                    title: "Claude Code CLI",
                    detected: env.claudeCLIAvailable,
                    pathBinding: $claudePath,
                    placeholder: "Auto-detect (/opt/homebrew/bin/claude or ~/.local/bin/claude)"
                )
                .id(CLIAuthProviderKind.claude)

                cliAccountCard(
                    provider: .codex,
                    title: "Codex CLI",
                    detected: env.codexCLIAvailable,
                    pathBinding: $codexPath,
                    placeholder: "Auto-detect (/opt/homebrew/bin/codex or ~/.local/bin/codex)"
                )
                .id(CLIAuthProviderKind.codex)

                cliAccountCard(
                    provider: .agy,
                    title: "Antigravity CLI (agy)",
                    detected: env.agyCLIAvailable,
                    pathBinding: $agyPath,
                    placeholder: "Auto-detect (~/.local/bin/agy or /opt/homebrew/bin/agy)"
                )
                .id(CLIAuthProviderKind.agy)

                cliAccountCard(
                    provider: .pi,
                    title: "Pi CLI (PyCLI)",
                    detected: env.piCLIAvailable,
                    pathBinding: $piPath,
                    placeholder: "Auto-detect (/opt/homebrew/bin/pi or ~/.npm-global/bin/pi)"
                )
                .id(CLIAuthProviderKind.pi)
            }

            // OpenAI / OpenRouter / Custom HTTP API
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenAI / OpenRouter / Custom HTTP Endpoint")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        SecureField("sk-… (used when an agent is set to OpenAI / API)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL (optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        TextField("https://api.openai.com/v1/chat/completions", text: $apiBaseURL)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(14)
                .helmCard(cornerRadius: HelmRadius.panel)
            }
        }
    }

    private var profileIsolationBannerCard: some View {
        let isIsolated = auth.profileMode == .helmIsolated

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isIsolated ? "lock.shield.fill" : "person.2.badge.key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isIsolated ? HelmAccent.primary : HelmSemantic.steady)
                    .frame(width: 32, height: 32)
                    .background(
                        (isIsolated ? HelmAccent.primarySoft : HelmSemantic.steadySoft),
                        in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("CLI Login Isolation")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text(auth.profileMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Button {
                    store.rescanEnvironment()
                    auth.refreshAllStatuses()
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
            }

            Picker(
                "CLI Profile Mode",
                selection: Binding(
                    get: { auth.profileMode },
                    set: { auth.setProfileMode($0) }
                )
            ) {
                ForEach(CLIAuthProfileMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                Image(systemName: isIsolated ? "folder.badge.person.crop" : "link.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(HelmInk.muted)
                Text(
                    isIsolated
                        ? "Isolated logins live in ~/Library/Application Support/Helm/auth/ — ideal for VM setups, work accounts, or keeping your personal terminal untouched."
                        : "Shares your Mac's existing CLI logins (~/.claude & ~/.codex) so Helm stays in sync with your terminal sessions."
                )
                .font(.caption)
                .foregroundStyle(HelmInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .helmCard(
            cornerRadius: HelmRadius.panel,
            accentBorder: isIsolated ? HelmAccent.primary.opacity(0.32) : nil
        )
    }

    private func cliAccountCard(
        provider: CLIAuthProviderKind,
        title: String,
        detected: Bool,
        pathBinding: Binding<String>,
        placeholder: String
    ) -> some View {
        let state = auth.state(for: provider)
        let isHighlighted = store.highlightedAuthProvider == provider
        let isBusy = busyProviders.contains(provider) || state.isChecking
        let hasCustomPath = !pathBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            // Top Row: Title + command chip + Live Auth Status Pill
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)

                Text(provider.commandName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HelmInk.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                if isHighlighted && !state.isSignedIn {
                    Text("Action Needed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HelmAccent.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HelmAccent.primarySoft, in: Capsule())
                }

                Spacer(minLength: 8)

                authStatusPill(for: state, detected: detected)
            }

            // Account Identity / Status Detail Sub-row
            identityOrDetailView(for: provider, state: state, detected: detected)

            // Action Row
            providerActionRow(for: provider, state: state, detected: detected, isBusy: isBusy)

            // Inline API Key Input (Codex / Pi)
            if expandedAPIKeyProvider == provider {
                inlineAPIKeyComposer(for: provider, isBusy: isBusy)
            }

            // Collapsible Binary Path Override
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedBinaryPaths.contains(provider) },
                    set: { expanded in
                        if expanded {
                            expandedBinaryPaths.insert(provider)
                        } else {
                            expandedBinaryPaths.remove(provider)
                        }
                    }
                )
            ) {
                HStack(spacing: 8) {
                    TextField(placeholder, text: pathBinding)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    Button("Browse…") {
                        pickBinary { url in
                            pathBinding.wrappedValue = url.path
                        }
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("Custom binary path")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HelmInk.muted)
                    if hasCustomPath {
                        Text("Custom")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HelmAccent.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(HelmAccent.primarySoft, in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .helmCard(
            cornerRadius: HelmRadius.panel,
            isSelected: isHighlighted,
            accentBorder: isHighlighted ? HelmAccent.primary.opacity(0.65) : nil
        )
    }

    @ViewBuilder
    private func authStatusPill(for state: CLIAuthState, detected: Bool) -> some View {
        switch state {
        case .signedIn:
            HStack(spacing: 5) {
                Circle()
                    .fill(HelmSemantic.steady)
                    .frame(width: 6, height: 6)
                Text("Signed In")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmSemantic.steady)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSemantic.steadySoft, in: Capsule())

        case .signedOut:
            HStack(spacing: 5) {
                Circle()
                    .fill(HelmSemantic.attention)
                    .frame(width: 6, height: 6)
                Text("Sign In Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmSemantic.attention)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSemantic.attentionSoft, in: Capsule())

        case .checking, .signingIn:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text(state.badgeTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HelmSemantic.thinking)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSemantic.thinkingSoft, in: Capsule())

        case .notInstalled:
            HStack(spacing: 5) {
                Circle()
                    .fill(HelmInk.muted)
                    .frame(width: 6, height: 6)
                Text("Not Installed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HelmInk.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSurface.well, in: Capsule())

        case .error:
            HStack(spacing: 5) {
                Circle()
                    .fill(HelmSemantic.critical)
                    .frame(width: 6, height: 6)
                Text("Auth Error")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmSemantic.critical)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSemantic.criticalSoft, in: Capsule())

        case .unknown:
            HStack(spacing: 5) {
                Circle()
                    .fill(detected ? HelmSemantic.attention : HelmInk.muted)
                    .frame(width: 6, height: 6)
                Text(detected ? "Detected" : "Not Installed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(detected ? HelmInk.secondary : HelmInk.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSurface.well, in: Capsule())
        }
    }

    @ViewBuilder
    private func identityOrDetailView(
        for provider: CLIAuthProviderKind,
        state: CLIAuthState,
        detected: Bool
    ) -> some View {
        switch state {
        case .signedIn(let identity):
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 13))
                    .foregroundStyle(HelmSemantic.steady)

                Text(identity.email ?? identity.accountLabel ?? identity.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: 6)

                if let planTier = identity.planTier, !planTier.isEmpty {
                    Text(planTier)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(HelmAccent.brass)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(HelmAccent.brassSoft, in: Capsule())
                }

                if !identity.authMethod.isEmpty {
                    Text(identity.authMethod)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(HelmInk.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(HelmSurface.elevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 0.75))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 0.75)
            )

        case .signedOut(let detail):
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .lineLimit(2)
            }

        case .signingIn(let statusMessage):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(HelmSemantic.thinking)
                    .lineLimit(1)
            }

        case .error(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(HelmSemantic.critical)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(HelmSemantic.critical)
                    .lineLimit(2)
            }

        case .notInstalled:
            Text("Install the `\(provider.commandName)` CLI on this Mac or point to a custom binary below.")
                .font(.caption)
                .foregroundStyle(HelmInk.muted)

        case .checking, .unknown:
            if !detected {
                Text("Install the `\(provider.commandName)` CLI on this Mac or point to a custom binary below.")
                    .font(.caption)
                    .foregroundStyle(HelmInk.muted)
            }
        }
    }

    @ViewBuilder
    private func providerActionRow(
        for provider: CLIAuthProviderKind,
        state: CLIAuthState,
        detected: Bool,
        isBusy: Bool
    ) -> some View {
        let isSignedIn = state.isSignedIn
        let isAvailable = detected || isSignedIn

        HStack(spacing: 8) {
            switch provider {
            case .claude:
                if isSignedIn {
                    Button {
                        auth.beginLogin(provider: .claude, method: .browserOAuth)
                    } label: {
                        Label("Switch Account", systemImage: "arrow.left.arrow.right")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .disabled(isBusy)
                } else {
                    Button {
                        auth.beginLogin(provider: .claude, method: .browserOAuth)
                    } label: {
                        Label("Sign In via Browser", systemImage: "safari")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(!isAvailable || isBusy)
                }

                moreMenu {
                    Button("Sign In via Anthropic Console (API)") {
                        auth.beginLogin(provider: .claude, method: .claudeConsole)
                    }
                    Button("Sign In via Enterprise SSO") {
                        auth.beginLogin(provider: .claude, method: .claudeSSO)
                    }
                    Divider()
                    Button("Open Login in Terminal") {
                        auth.openTerminalLoginFallback(for: .claude)
                    }
                    Button("Refresh Status") {
                        auth.refreshStatus(for: .claude)
                    }
                }
                .disabled(!isAvailable || isBusy)

                Spacer(minLength: 0)

                if isSignedIn && provider.supportsSignOut {
                    signOutButton(for: .claude, isBusy: isBusy)
                }

            case .codex:
                if isSignedIn {
                    Button {
                        auth.beginLogin(provider: .codex, method: .browserOAuth)
                    } label: {
                        Label("Switch Account", systemImage: "arrow.left.arrow.right")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .disabled(isBusy)
                } else {
                    Button {
                        auth.beginLogin(provider: .codex, method: .browserOAuth)
                    } label: {
                        Label("Sign In via Browser", systemImage: "safari")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(!isAvailable || isBusy)
                }

                Button {
                    auth.beginLogin(provider: .codex, method: .deviceCode)
                } label: {
                    Label("Device Code (VM)", systemImage: "rectangle.and.pencil.and.ellipsis")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .disabled(!isAvailable || isBusy)

                Button {
                    toggleAPIKeyComposer(for: .codex)
                } label: {
                    Label("API Key…", systemImage: "key")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .disabled(isBusy)

                moreMenu {
                    Button("Open Login in Terminal") {
                        auth.openTerminalLoginFallback(for: .codex)
                    }
                    Button("Refresh Status") {
                        auth.refreshStatus(for: .codex)
                    }
                }
                .disabled(!isAvailable || isBusy)

                Spacer(minLength: 0)

                if isSignedIn && provider.supportsSignOut {
                    signOutButton(for: .codex, isBusy: isBusy)
                }

            case .agy:
                if isSignedIn {
                    Button {
                        auth.beginLogin(provider: .agy, method: .browserOAuth)
                    } label: {
                        Label("Switch Account", systemImage: "arrow.left.arrow.right")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .disabled(isBusy)
                } else {
                    Button {
                        auth.beginLogin(provider: .agy, method: .browserOAuth)
                    } label: {
                        Label("Sign In via Browser", systemImage: "safari")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(!isAvailable || isBusy)
                }

                Button {
                    auth.openTerminalLoginFallback(for: .agy)
                } label: {
                    Label("Open Login in Terminal", systemImage: "terminal")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .disabled(!isAvailable || isBusy)

                Button {
                    auth.refreshStatus(for: .agy)
                } label: {
                    Label("Verify Status", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .disabled(isBusy)

                Spacer(minLength: 0)

                if isSignedIn && provider.supportsSignOut {
                    signOutButton(for: .agy, isBusy: isBusy)
                }

            case .pi:
                if isSignedIn {
                    Button {
                        toggleAPIKeyComposer(for: .pi)
                    } label: {
                        Label("Update API Key…", systemImage: "key")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .disabled(isBusy)
                } else {
                    Button {
                        toggleAPIKeyComposer(for: .pi)
                    } label: {
                        Label("Set API Key…", systemImage: "key.fill")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(isBusy)
                }

                Button {
                    auth.openTerminalLoginFallback(for: .pi)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .disabled(!isAvailable || isBusy)

                Button {
                    auth.refreshStatus(for: .pi)
                } label: {
                    Label("Verify Status", systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .disabled(isBusy)

                Spacer(minLength: 0)

                if isSignedIn && provider.supportsSignOut {
                    signOutButton(for: .pi, isBusy: isBusy)
                }
            }
        }
    }

    private func moreMenu<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text("More…")
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(HelmInk.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .strokeBorder(HelmSurface.lineStrong, lineWidth: 0.9)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func signOutButton(for provider: CLIAuthProviderKind, isBusy: Bool) -> some View {
        Button {
            busyProviders.insert(provider)
            Task {
                await auth.signOut(provider: provider)
                busyProviders.remove(provider)
            }
        } label: {
            Text("Sign Out")
                .font(.caption.weight(.medium))
                .foregroundStyle(HelmInk.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help("Sign out of \(provider.displayName) in \(auth.profileMode.displayName)")
    }

    private func toggleAPIKeyComposer(for provider: CLIAuthProviderKind) {
        withAnimation(HelmMotion.micro) {
            if expandedAPIKeyProvider == provider {
                expandedAPIKeyProvider = nil
                inlineAPIKeyDraft = ""
            } else {
                expandedAPIKeyProvider = provider
                inlineAPIKeyDraft = ""
            }
        }
    }

    private func inlineAPIKeyComposer(for provider: CLIAuthProviderKind, isBusy: Bool) -> some View {
        let trimmed = inlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 8) {
            SecureField(
                provider == .codex
                    ? "Paste OpenAI API key (sk-…) for Codex CLI"
                    : "Paste API key for Pi CLI",
                text: $inlineAPIKeyDraft
            )
            .textFieldStyle(.roundedBorder)

            Button {
                guard !trimmed.isEmpty else { return }
                busyProviders.insert(provider)
                let submittedKey = trimmed
                Task {
                    await auth.submitAPIKeyLogin(provider: provider, apiKey: submittedKey)
                    busyProviders.remove(provider)
                    withAnimation(HelmMotion.micro) {
                        expandedAPIKeyProvider = nil
                        inlineAPIKeyDraft = ""
                    }
                }
            } label: {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("Save Key")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(HelmPrimaryButtonStyle())
            .disabled(trimmed.isEmpty || isBusy)

            Button("Cancel") {
                withAnimation(HelmMotion.micro) {
                    expandedAPIKeyProvider = nil
                    inlineAPIKeyDraft = ""
                }
            }
            .buttonStyle(HelmSecondaryButtonStyle())
        }
        .padding(10)
        .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                .strokeBorder(HelmAccent.primary.opacity(0.28), lineWidth: 0.9)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Tab 2: Sandbox & VM

    private var sandboxAndVMSection: some View {
        let env = store.environmentStatus

        return VStack(alignment: .leading, spacing: 16) {
            // 3 Metric Status Cards
            HStack(spacing: 12) {
                sandboxMetricCard(
                    icon: "cpu.fill",
                    tint: store.virtualizationAvailable ? HelmSemantic.steady : HelmAccent.primary,
                    title: "ARM64 Micro-VM",
                    status: store.virtualizationAvailable ? "Virtualization Ready" : "Seatbelt Active",
                    statusPositive: store.virtualizationAvailable,
                    detail: store.virtualizationAvailable
                        ? "Apple Virtualization.framework signed & available"
                        : "Falling back to native macOS Seatbelt isolation"
                )

                sandboxMetricCard(
                    icon: "lock.shield.fill",
                    tint: HelmSemantic.steady,
                    title: "Seatbelt Sandbox",
                    status: "Always Ready",
                    statusPositive: true,
                    detail: "Confines filesystem writes & subprocesses safely"
                )

                sandboxMetricCard(
                    icon: "eye.fill",
                    tint: env.chromeAvailable ? HelmSemantic.browsing : HelmSemantic.attention,
                    title: "Chrome + Vision OCR",
                    status: env.chromeAvailable ? "Ready" : "Chrome Not Found",
                    statusPositive: env.chromeAvailable,
                    detail: env.chromeAvailable
                        ? "Headless browsing & Apple Vision OCR online"
                        : "Install Google Chrome for headless web agents"
                )
            }

            // Host CLI OAuth + Isolated ARM64 VM Explainer Card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HelmAccent.primary)
                    Text("How Host CLI OAuth + Isolated Execution Work Together")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    architectureStepRow(
                        icon: "person.badge.key.fill",
                        tint: HelmAccent.primary,
                        title: "AI Reasoning Runs via Host CLI Sessions",
                        detail: "Your agents call your signed-in CLI sessions on macOS (\(auth.profileMode.displayName)). OAuth tokens stay on macOS and are never copied into project repositories."
                    )

                    Divider().overlay(HelmSurface.line)

                    architectureStepRow(
                        icon: "terminal.fill",
                        tint: HelmSemantic.executing,
                        title: "Shell Commands Execute Inside the Isolated VM / Sandbox",
                        detail: "Every `run_command` build, test, and script executes inside the ARM64 Linux micro-VM or Seatbelt sandbox—completely isolated from your desktop and unrelated Mac files."
                    )
                }
                .padding(12)
                .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                        .strokeBorder(HelmSurface.line, lineWidth: 0.75)
                )
            }
            .padding(16)
            .helmCard(cornerRadius: HelmRadius.panel)

            // Opt-in Credential Forwarding Toggle Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Forward API keys into Sandbox / VM")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)

                            Text(auth.forwardCredentialsToSandbox ? "Enabled" : "Off by default")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(auth.forwardCredentialsToSandbox ? HelmSemantic.attention : HelmSemantic.steady)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    (auth.forwardCredentialsToSandbox ? HelmSemantic.attentionSoft : HelmSemantic.steadySoft),
                                    in: Capsule()
                                )
                        }

                        Text("Off by default for maximum isolation. When enabled, Helm forwards configured API keys into `run_command` executions inside the VM or Seatbelt sandbox for builds, integration tests, or scripts that need API credentials.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    Toggle(
                        "Forward API keys into Sandbox / VM",
                        isOn: Binding(
                            get: { auth.forwardCredentialsToSandbox },
                            set: { auth.setForwardCredentialsToSandbox($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            .padding(16)
            .helmCard(
                cornerRadius: HelmRadius.panel,
                accentBorder: auth.forwardCredentialsToSandbox ? HelmSemantic.attention.opacity(0.38) : nil
            )
        }
    }

    private func sandboxMetricCard(
        icon: String,
        tint: Color,
        title: String,
        status: String,
        statusPositive: Bool,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer()
                Circle()
                    .fill(statusPositive ? HelmSemantic.steady : HelmSemantic.attention)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.secondary)
                Text(status)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(HelmInk.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(HelmInk.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .helmCard(cornerRadius: HelmRadius.panel)
    }

    private func architectureStepRow(
        icon: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tab 3: General & Safe Updates

    private var generalSettingsSection: some View {
        let updater = store.updateManager

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safe Auto-Updates")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                        Text("Running v\(updater.currentVersionString). Updates download in the background, checkpoint any active agents safely to SQLite, and auto-resume them after restart—or wait until all projects are idle.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Check Now") {
                        Task { await updater.checkForUpdates(userInitiated: true) }
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .disabled(updater.state.isBusy)
                }

                if case .available(let release) = updater.state {
                    Divider().overlay(HelmSurface.line)
                    HStack {
                        Text("Helm v\(release.version.displayString) is available")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmAccent.primary)
                        Spacer()
                        if store.runningProjectCount > 0 {
                            Button("Install When Idle") {
                                Task { await updater.downloadAndInstall(release, deferUntilIdle: true) }
                            }
                            .buttonStyle(HelmSecondaryButtonStyle())
                        }
                        Button(store.runningProjectCount > 0 ? "Checkpoint & Update" : "Install & Restart") {
                            Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                    }
                }
            }
            .padding(14)
            .helmCard(cornerRadius: HelmRadius.panel)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome Onboarding")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text("Re-open the guided starter crew and project creation flow.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }
                Spacer()
                Button("Run Guided Setup…") {
                    dismiss()
                    store.reopenOnboarding()
                }
                .buttonStyle(HelmSecondaryButtonStyle())
            }
            .padding(14)
            .helmCard(cornerRadius: HelmRadius.panel)
        }
    }

    private func pickBinary(onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}
