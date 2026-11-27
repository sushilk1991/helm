import AppKit
import HelmCore
import SwiftUI

public struct OnboardingFlowView: View {
    @Bindable var store: HelmWorkspaceStore

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion

    @State private var step: Int = 0
    @State private var selectedBackend: LLMBackendKind = .mock
    @State private var apiBaseURL: String = ""
    @State private var apiKey: String = ""
    @State private var inlineCLIAPIKey: String = ""
    @State private var isSubmittingInlineCLIKey: Bool = false

    @State private var selectedTemplateID: String = "feature"
    @State private var projectName: String = ""
    @State private var didManuallyEditName: Bool = false
    @State private var projectGoal: String = "Research requirements, implement core features in the isolated sandbox, and verify the live app headlessly."
    @State private var workspacePath: String = ""
    @State private var leadPersonality: AgentPersonality = .calmCommander
    @State private var selectedRoles: Set<AgentRole> = [.researcher, .coder, .browserAnalyst]
    @State private var crewSeeds: [AgentRole: AgentCharacterSeed] = [:]
    @State private var errorMessage: String?
    @State private var isCreating: Bool = false

    private let previewSeeds: [(name: String, role: String, state: AgentActivityState, seed: AgentCharacterSeed)] = [
        ("Compass", "Orchestrator", .thinking, AgentCharacterSeed(agentID: UUID(uuidString: "11111111-1111-1111-1111-111111111101")!, isOrchestrator: true)),
        ("Chart", "Researcher", .completed, AgentCharacterSeed(agentID: UUID(uuidString: "11111111-1111-1111-1111-111111111102")!, isOrchestrator: false)),
        ("Forge", "Coder", .executing, AgentCharacterSeed(agentID: UUID(uuidString: "11111111-1111-1111-1111-111111111103")!, isOrchestrator: false)),
        ("Lookout", "Browser", .browsing, AgentCharacterSeed(agentID: UUID(uuidString: "11111111-1111-1111-1111-111111111104")!, isOrchestrator: false)),
    ]

    private struct ProjectTemplate: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let defaultName: String
        let defaultGoal: String
        let roles: Set<AgentRole>
    }

    private let templates: [ProjectTemplate] = [
        ProjectTemplate(
            id: "feature",
            title: "Ship a Feature",
            subtitle: "Plan, code in VM & verify",
            icon: "hammer.fill",
            defaultName: "Launch MVP Workspace",
            defaultGoal: "Research architecture, implement core modules in the isolated VM, run tests, and verify results silently.",
            roles: [.researcher, .coder, .qaVerifier]
        ),
        ProjectTemplate(
            id: "research",
            title: "Deep Research",
            subtitle: "Browse, read OCR & synthesize",
            icon: "sparkle.magnifyingglass",
            defaultName: "Market & Competitor Brief",
            defaultGoal: "Browse target sites headlessly, extract verified observations with Vision OCR, and publish a structured report.",
            roles: [.researcher, .browserAnalyst]
        ),
        ProjectTemplate(
            id: "qa",
            title: "Autonomous QA",
            subtitle: "Test & watch web flows 24/7",
            icon: "checkmark.shield.fill",
            defaultName: "Continuous Web Verifier",
            defaultGoal: "Exercise key user journeys in headless Chrome, run regression scripts in sandbox, and alert only on failures.",
            roles: [.browserAnalyst, .qaVerifier]
        ),
        ProjectTemplate(
            id: "custom",
            title: "Blank Project",
            subtitle: "Start with your own brief",
            icon: "square.and.pencil",
            defaultName: "",
            defaultGoal: "",
            roles: [.researcher, .coder]
        ),
    ]

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    public var body: some View {
        ZStack {
            // Subtle top-center ambient glow over refined canvas
            HelmSurface.canvas.ignoresSafeArea()

            RadialGradient(
                colors: [
                    HelmAccent.primary.opacity(0.11),
                    HelmAccent.brass.opacity(0.05),
                    Color.clear,
                ],
                center: .top,
                startRadius: 20,
                endRadius: 560
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top progress & skip bar
                HStack {
                    HStack(spacing: HelmSpace.m) {
                        CompassHelmLogo(size: 26, style: .emblem, hasOpenException: false, settleTrigger: step)
                        Text("Helm")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                    }

                    Spacer()

                    // Step indicators
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { idx in
                            Capsule()
                                .fill(idx == step ? HelmAccent.primary : (idx < step ? HelmSemantic.steady : HelmSurface.lineStrong))
                                .frame(width: idx == step ? 28 : 8, height: 6)
                                .animation(HelmMotion.state, value: step)
                        }
                    }

                    Spacer()

                    Button(store.projects.isEmpty ? "Skip for now" : "Close") {
                        withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                            store.completeOnboarding()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(HelmInk.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 12)

                // Active step content
                ScrollView {
                    VStack(spacing: 0) {
                        switch step {
                        case 0:
                            welcomeStep
                        case 1:
                            providerStep
                        default:
                            firstProjectStep
                        }
                    }
                    .frame(maxWidth: 740)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                }
                .animation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state, value: step)
            }
        }
        .onAppear {
            selectedBackend = store.defaultBackend
            apiBaseURL = store.apiBaseURL
            apiKey = store.apiKeyInput
            if workspacePath.isEmpty {
                let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
                workspacePath = docs.appendingPathComponent("Helm/workspaces/first-project").path
            }
            if crewSeeds.isEmpty {
                for role in [AgentRole.orchestrator, .researcher, .coder, .browserAnalyst, .qaVerifier] {
                    crewSeeds[role] = AgentCharacterSeed(agentID: UUID(), isOrchestrator: role == .orchestrator)
                }
            }
        }
        .onChange(of: step) { _, newStep in
            if newStep == 1 {
                store.cliAuthManager.refreshAllStatuses()
            }
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

    // MARK: - Step 1: Welcome & Meet Your Crew

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                CompassHelmLogo(size: 64, style: .emblem, hasOpenException: false, settleTrigger: step)
                    .shadow(color: HelmAccent.primary.opacity(0.25), radius: 18, x: 0, y: 6)

                Text("Autonomous workspaces that never hijack your Mac.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(HelmInk.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)

                Text("Spin up a project, deploy specialized agents led by an exception-only Orchestrator, and let them code and browse silently in the background.")
                    .font(.body)
                    .foregroundStyle(HelmInk.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            // Live Interactive Bot Parade
            HStack(spacing: 16) {
                ForEach(previewSeeds, id: \.name) { bot in
                    VStack(spacing: 10) {
                        AgentCharacterCanvas(
                            seed: bot.seed,
                            state: bot.state,
                            size: 64,
                            showStageBacking: true,
                            interactive: true
                        )
                        VStack(spacing: 2) {
                            Text(bot.name)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                            Text(bot.role)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
                    .helmCard(cornerRadius: HelmRadius.card)
                }
            }

            // 3 crisp pillars
            HStack(spacing: 14) {
                pillarCard(
                    icon: "bell.badge.slash.fill",
                    tint: HelmSemantic.steady,
                    title: "Silent Until Needed",
                    detail: "Runs quietly when healthy; surfaces clear Approve, Retry, or Redirect decisions only on stalls or drift."
                )
                pillarCard(
                    icon: "cpu.fill",
                    tint: HelmAccent.primary,
                    title: "Isolated Apple VM",
                    detail: "Code runs inside a lightweight ARM64 micro-VM or Seatbelt sandbox—never touching your desktop."
                )
                pillarCard(
                    icon: "eye.fill",
                    tint: HelmSemantic.browsing,
                    title: "Headless Browser + OCR",
                    detail: "Disposable Chrome + native Apple Vision OCR reads and acts on pages with zero focus steal."
                )
            }

            HStack(spacing: 14) {
                Button {
                    withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                        step = 1
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private func pillarCard(icon: String, tint: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(HelmInk.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(HelmInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .helmCard(cornerRadius: HelmRadius.panel)
    }

    // MARK: - Step 2: Connect Intelligence & Local Readiness

    private enum ProviderBadgeTone {
        case positive
        case warning
        case checking
        case neutral
    }

    private var providerStep: some View {
        let env = store.environmentStatus
        let selectedCLIProvider = CLIAuthProviderKind.from(backend: selectedBackend)
        let selectedCLIDetected = selectedCLIProvider.map { isCLIDetected($0) } ?? false
        let selectedCLIState = selectedCLIProvider.map { store.cliAuthManager.state(for: $0) }

        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect Your AI Engine")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(HelmInk.primary)
                Text("Choose the default model backend for your Orchestrator and agents. You can override this per agent anytime.")
                    .font(.body)
                    .foregroundStyle(HelmInk.secondary)
            }

            // Automatic Mac readiness strip (calm, non-intrusive)
            HStack(spacing: 12) {
                readinessChip(
                    ok: true,
                    label: env.virtualizationAvailable ? "Apple Virtualization Ready" : "Seatbelt Sandbox Ready"
                )
                readinessChip(
                    ok: env.chromeAvailable,
                    label: env.chromeAvailable ? "Headless Chrome + Vision OCR Ready" : "Install Chrome for Headless Browsing"
                )
                Spacer()
            }

            // Provider cards
            VStack(spacing: 10) {
                cliProviderCard(
                    kind: .claudeCLI,
                    provider: .claude,
                    title: "Claude Code CLI",
                    subtitle: "Uses your local authenticated `claude` CLI directly.",
                    detected: env.claudeCLIAvailable
                )
                cliProviderCard(
                    kind: .codexCLI,
                    provider: .codex,
                    title: "Codex CLI",
                    subtitle: "Uses your local authenticated `codex` CLI.",
                    detected: env.codexCLIAvailable
                )
                cliProviderCard(
                    kind: .agyCLI,
                    provider: .agy,
                    title: "Antigravity CLI (agy)",
                    subtitle: "Uses your local authenticated `agy` CLI (`agy --print --output-format json`).",
                    detected: env.agyCLIAvailable
                )
                cliProviderCard(
                    kind: .piCLI,
                    provider: .pi,
                    title: "Pi CLI (PyCLI)",
                    subtitle: "Uses your local `pi` coding agent CLI (`pi -p --mode json`) for fast multi-model workflows.",
                    detected: env.piCLIAvailable
                )
                providerCard(
                    kind: .directHTTP,
                    title: "OpenAI / OpenRouter / Custom API",
                    subtitle: "Connect any OpenAI-compatible chat completions endpoint.",
                    badge: "API Key",
                    badgeTone: !apiKey.isEmpty ? .positive : .neutral
                )
                providerCard(
                    kind: .foundationModels,
                    title: "Apple Intelligence (On-Device)",
                    subtitle: "Private local inference via Apple FoundationModels.",
                    badge: env.foundationModelsSupported ? "Available" : "Requires macOS 26+",
                    badgeTone: env.foundationModelsSupported ? .positive : .neutral
                )
                providerCard(
                    kind: .mock,
                    title: "Offline Demo Mode",
                    subtitle: "Try multi-agent delegation, watchdogs, and UI animations right away with no API key.",
                    badge: "Always Ready",
                    badgeTone: .positive
                )
            }

            // Inline one-click CLI sign-in callout when a detected CLI is not yet signed in
            if let provider = selectedCLIProvider,
               selectedCLIDetected,
               let authState = selectedCLIState,
               !authState.isSignedIn {
                onboardingCLISignInCallout(for: provider, state: authState)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if selectedBackend == .directHTTP {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL (optional — defaults to OpenAI)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        TextField("https://api.openai.com/v1/chat/completions", text: $apiBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(14)
                .helmCard(cornerRadius: HelmRadius.panel)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button("Back") {
                    withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                        step = 0
                    }
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Spacer()

                Button {
                    store.savePreferences(backend: selectedBackend, baseURL: apiBaseURL, apiKey: apiKey)
                    withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                        step = 2
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .onAppear {
            store.cliAuthManager.refreshAllStatuses()
        }
    }

    private func isCLIDetected(_ provider: CLIAuthProviderKind) -> Bool {
        let env = store.environmentStatus
        switch provider {
        case .claude: return env.claudeCLIAvailable
        case .codex: return env.codexCLIAvailable
        case .agy: return env.agyCLIAvailable
        case .pi: return env.piCLIAvailable
        }
    }

    private func cliProviderCard(
        kind: LLMBackendKind,
        provider: CLIAuthProviderKind,
        title: String,
        subtitle: String,
        detected: Bool
    ) -> some View {
        let authState = store.cliAuthManager.state(for: provider)
        let badgeInfo: (String, ProviderBadgeTone) = {
            if !detected && !authState.isSignedIn {
                return ("CLI not detected", .neutral)
            }
            switch authState {
            case .signedIn:
                return ("Signed In", .positive)
            case .checking, .signingIn:
                return (authState.badgeTitle, .checking)
            case .notInstalled:
                return ("CLI not detected", .neutral)
            case .signedOut, .error, .unknown:
                return ("Installed · Sign In Needed", .warning)
            }
        }()

        let effectiveSubtitle: String = {
            if case .signedIn(let identity) = authState {
                let account = identity.email ?? identity.accountLabel ?? identity.summary
                if let tier = identity.planTier, !tier.isEmpty {
                    return "Signed in as \(account) · \(tier)"
                }
                return "Signed in as \(account)"
            }
            return subtitle
        }()

        return providerCard(
            kind: kind,
            title: title,
            subtitle: effectiveSubtitle,
            badge: badgeInfo.0,
            badgeTone: badgeInfo.1
        )
    }

    private func onboardingCLISignInCallout(for provider: CLIAuthProviderKind, state: CLIAuthState) -> some View {
        let auth = store.cliAuthManager

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HelmAccent.primary)
                    .frame(width: 34, height: 34)
                    .background(HelmAccent.primarySoft, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign in to \(provider.displayName)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text("`\(provider.commandName)` is installed on this Mac, but not signed in yet. Authenticate now so your crew can start immediately.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    auth.refreshStatus(for: provider)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .help("Re-check \(provider.displayName) login status")
            }

            if provider.supportsBrowserOAuth {
                HStack(spacing: 10) {
                    Button {
                        auth.beginLogin(provider: provider, method: .browserOAuth)
                    } label: {
                        Label("Sign In via Browser…", systemImage: "safari")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())

                    if provider.supportsDeviceCodeLogin {
                        Button {
                            auth.beginLogin(provider: provider, method: .deviceCode)
                        } label: {
                            Label("Device Code (VM)", systemImage: "rectangle.and.pencil.and.ellipsis")
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                    }

                    Spacer(minLength: 0)

                    Button("Open in Terminal") {
                        auth.openTerminalLoginFallback(for: provider)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HelmInk.secondary)
                }
            } else if provider.supportsAPIKeyLogin {
                let trimmedKey = inlineCLIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                HStack(spacing: 8) {
                    SecureField("Paste API key for \(provider.displayName)…", text: $inlineCLIAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        guard !trimmedKey.isEmpty else { return }
                        isSubmittingInlineCLIKey = true
                        let keyToSave = trimmedKey
                        Task {
                            await auth.submitAPIKeyLogin(provider: provider, apiKey: keyToSave)
                            isSubmittingInlineCLIKey = false
                            inlineCLIAPIKey = ""
                        }
                    } label: {
                        if isSubmittingInlineCLIKey {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Save Key")
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(trimmedKey.isEmpty || isSubmittingInlineCLIKey)

                    Button("Open in Terminal") {
                        auth.openTerminalLoginFallback(for: provider)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        auth.openTerminalLoginFallback(for: provider)
                    } label: {
                        Label("Open Login in Terminal", systemImage: "terminal")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .helmCard(cornerRadius: HelmRadius.panel, accentBorder: HelmAccent.primary.opacity(0.38))
    }

    private func readinessChip(ok: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.caption)
                .foregroundStyle(ok ? HelmSemantic.steady : HelmSemantic.attention)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(HelmInk.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(HelmSurface.elevated, in: Capsule())
        .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 1))
    }

    private func providerCard(
        kind: LLMBackendKind,
        title: String,
        subtitle: String,
        badge: String,
        badgeTone: ProviderBadgeTone
    ) -> some View {
        let isSelected = selectedBackend == kind

        return Button {
            withAnimation(HelmMotion.micro) {
                selectedBackend = kind
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? HelmAccent.primary : HelmInk.muted)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 10)

                providerBadgeView(label: badge, tone: badgeTone)
            }
            .padding(14)
            .helmCard(cornerRadius: HelmRadius.panel, isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerBadgeView(label: String, tone: ProviderBadgeTone) -> some View {
        let fg: Color
        let bg: Color
        switch tone {
        case .positive:
            fg = HelmSemantic.steady
            bg = HelmSemantic.steadySoft
        case .warning:
            fg = HelmSemantic.attention
            bg = HelmSemantic.attentionSoft
        case .checking:
            fg = HelmSemantic.thinking
            bg = HelmSemantic.thinkingSoft
        case .neutral:
            fg = HelmInk.muted
            bg = HelmSurface.well
        }

        return HStack(spacing: 5) {
            if tone == .checking {
                ProgressView()
                    .controlSize(.mini)
            } else if tone == .positive || tone == .warning {
                Circle()
                    .fill(fg)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(fg)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bg, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Step 3: Launch First Project & Crew

    private var firstProjectStep: some View {
        let specialistRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier]

        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spin Up Your First Project")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(HelmInk.primary)
                Text("Pick a starter mission or write your own, and assemble your animated crew. Click any bot to remix its look.")
                    .font(.body)
                    .foregroundStyle(HelmInk.secondary)
            }

            // Starter Templates
            HStack(spacing: 10) {
                ForEach(templates) { tpl in
                    let active = selectedTemplateID == tpl.id
                    Button {
                        withAnimation(HelmMotion.micro) {
                            selectedTemplateID = tpl.id
                            if !tpl.defaultName.isEmpty { projectName = tpl.defaultName }
                            if !tpl.defaultGoal.isEmpty { projectGoal = tpl.defaultGoal }
                            selectedRoles = tpl.roles
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: tpl.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(active ? HelmAccent.primary : HelmInk.secondary)
                            Text(tpl.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            Text(tpl.subtitle)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .helmCard(cornerRadius: HelmRadius.panel, isSelected: active)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Project Brief — Repo / Folder FIRST, auto-deriving project name
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Repository or Workspace Folder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        Spacer()
                        if !resolvedProjectName.isEmpty {
                            Text("Project name: \(resolvedProjectName)")
                                .font(.caption)
                                .foregroundStyle(HelmAccent.primary)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("/path/to/your-repo", text: $workspacePath)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: workspacePath) { _, newPath in
                                if !didManuallyEditName {
                                    let derived = URL(fileURLWithPath: newPath).lastPathComponent
                                    if !derived.isEmpty && derived != "/" {
                                        projectName = derived
                                    }
                                }
                            }
                        Button {
                            pickFolder()
                        } label: {
                            Label("Choose Repo…", systemImage: "folder")
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Goal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)
                    TextField("Describe what your autonomous crew should build, research, or monitor…", text: $projectGoal, axis: .vertical)
                        .lineLimit(2...3)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display Name (auto-filled from folder)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.muted)
                        TextField("Auto-detected from repo folder", text: $projectName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: projectName) { _, newValue in
                                let folderName = URL(fileURLWithPath: workspacePath).lastPathComponent
                                didManuallyEditName = !newValue.isEmpty && newValue != folderName
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lead Personality")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.muted)
                        Picker("Lead Personality", selection: $leadPersonality) {
                            ForEach(AgentPersonality.allCases, id: \.self) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 185)
                    }
                }
            }
            .padding(16)
            .helmCard(cornerRadius: HelmRadius.card)

            // Interactive Animated Crew Picker
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your Crew")
                        .font(.headline)
                        .foregroundStyle(HelmInk.primary)
                    Text("Orchestrator included · toggle specialists")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    // Always-included Orchestrator card
                    crewCard(
                        role: .orchestrator,
                        title: "Compass",
                        subtitle: leadPersonality.displayName,
                        state: .thinking,
                        selected: true,
                        locked: true
                    )

                    ForEach(specialistRoles, id: \.self) { role in
                        let preset = AgentRolePreset.preset(for: role)
                        let active = selectedRoles.contains(role)
                        crewCard(
                            role: role,
                            title: preset.name.components(separatedBy: " ").first ?? role.displayName,
                            subtitle: role.displayName,
                            state: role == .coder ? .executing : (role == .browserAnalyst ? .browsing : .idle),
                            selected: active,
                            locked: false
                        )
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(HelmSemantic.critical)
            }

            HStack {
                Button("Back") {
                    withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                        step = 1
                    }
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Spacer()

                Button {
                    launchFirstProject()
                } label: {
                    HStack(spacing: 8) {
                        Text(isCreating ? "Launching Crew…" : "Launch Workspace")
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private func crewCard(
        role: AgentRole,
        title: String,
        subtitle: String,
        state: AgentActivityState,
        selected: Bool,
        locked: Bool
    ) -> some View {
        let seed = crewSeeds[role] ?? AgentCharacterSeed(agentID: UUID(), isOrchestrator: role == .orchestrator)

        return VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AgentCharacterCanvas(
                    seed: seed,
                    state: selected ? state : .paused,
                    size: 52,
                    showStageBacking: true,
                    interactive: true
                )
                .onTapGesture {
                    if !locked {
                        crewSeeds[role] = AgentCharacterSeed(agentID: UUID(), isOrchestrator: false)
                    }
                }

                if locked {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(HelmAccent.brass)
                        .padding(4)
                        .background(HelmSurface.elevated, in: Circle())
                        .offset(x: 4, y: -4)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? HelmAccent.primary : HelmInk.muted)
                        .offset(x: 4, y: -4)
                }
            }

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? HelmInk.primary : HelmInk.muted)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(HelmInk.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .helmCard(
            cornerRadius: HelmRadius.panel,
            isSelected: selected,
            accentBorder: locked ? HelmAccent.brass.opacity(0.45) : nil
        )
        .opacity(selected ? 1.0 : 0.58)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !locked else { return }
            withAnimation(HelmMotion.micro) {
                if selectedRoles.contains(role) {
                    selectedRoles.remove(role)
                } else {
                    selectedRoles.insert(role)
                }
            }
        }
    }

    private var resolvedProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
        return (folder.isEmpty || folder == "/") ? "" : folder
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            projectName = url.lastPathComponent
            didManuallyEditName = false
        }
    }

    private func launchFirstProject() {
        let trimmedName = resolvedProjectName
        let trimmedGoal = projectGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty else {
            errorMessage = "Choose a repository or local workspace folder."
            return
        }
        guard !trimmedName.isEmpty else {
            errorMessage = "Choose a valid folder or enter a project name."
            return
        }
        guard !trimmedGoal.isEmpty else {
            errorMessage = "Describe the goal your crew should work toward."
            return
        }

        isCreating = true
        errorMessage = nil
        store.savePreferences(backend: selectedBackend, baseURL: apiBaseURL, apiKey: apiKey)

        let orderedRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier].filter { selectedRoles.contains($0) }
        let url = URL(fileURLWithPath: trimmedPath, isDirectory: true)

        Task {
            do {
                try await store.createProject(
                    name: trimmedName,
                    goal: trimmedGoal,
                    workspaceRoot: url,
                    backend: selectedBackend,
                    leadPersonality: leadPersonality,
                    starterRoles: orderedRoles
                )
                withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                    store.completeOnboarding()
                }
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
