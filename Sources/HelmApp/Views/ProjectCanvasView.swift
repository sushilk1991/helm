import AppKit
import HelmCore
import SwiftUI

private enum NarrowWorkspaceMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case liveWork = "Live Work"
    case tasks = "Tasks"
    case memory = "Memory"

    var id: String { rawValue }
}

public struct ProjectCanvasView: View {
    @Bindable var store: HelmWorkspaceStore
    public let horizonPingOverride: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion

    @State private var pulseOpacity: Double = 0
    @State private var hoveredAgentID: UUID?
    @State private var composerText: String = ""
    @State private var showAllExceptions: Bool = false
    @State private var narrowMode: NarrowWorkspaceMode = .chat

    public init(store: HelmWorkspaceStore, horizonPingOverride: Bool = false) {
        self.store = store
        self.horizonPingOverride = horizonPingOverride
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    public var body: some View {
        Group {
            if let project = store.selectedProject {
                VStack(alignment: .leading, spacing: 12) {
                    headerStrip(project: project)

                    if let err = store.bannerErrorMessage {
                        bannerErrorStrip(err)
                    }

                    if !store.selectedProjectOpenExceptions.isEmpty {
                        exceptionStrip
                            .transition(
                                effectiveReduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .opacity
                                    )
                            )
                    }

                    crewRosterStrip(project: project)

                    workspaceBody(project: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(HelmSurface.canvas)
                .animation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state, value: store.selectedProjectOpenExceptions.count)
                .onChange(of: store.selectedChatChannel) { _, _ in
                    narrowMode = .chat
                }
                .onChange(of: store.chatNavigationNonce) { _, _ in
                    narrowMode = .chat
                }
                .onChange(of: store.secondaryTab) { _, newTab in
                    switch newTab {
                    case .liveWork:
                        if narrowMode != .chat { narrowMode = .liveWork }
                    case .tasks:
                        narrowMode = .tasks
                    case .memory:
                        if narrowMode != .chat { narrowMode = .memory }
                    }
                }
                .onChange(of: store.selectedTaskID) { _, newID in
                    if newID != nil {
                        narrowMode = .tasks
                    }
                }
            } else {
                emptyWorkspaceView
            }
        }
    }

    // MARK: - Header Strip

    private func headerStrip(project: Project) -> some View {
        let pingCount = store.horizonPingCounterByProject[project.id] ?? 0
        let openCount = store.selectedProjectOpenExceptions.count

        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    CompassHelmLogo(
                        size: 28,
                        style: .emblem,
                        hasOpenException: openCount > 0,
                        settleTrigger: store.settleHelmCounter
                    )

                    Text(project.name)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 120, alignment: .leading)

                    ProjectStatusBadge(status: project.status)

                    Spacer(minLength: 4)

                    headerActionButtons(project: project, compact: false)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        CompassHelmLogo(
                            size: 24,
                            style: .emblem,
                            hasOpenException: openCount > 0,
                            settleTrigger: store.settleHelmCounter
                        )

                        Text(project.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(HelmInk.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        Spacer(minLength: 4)

                        headerActionButtons(project: project, compact: true)
                    }

                    ProjectStatusBadge(status: project.status)
                }
            }

            HStack(spacing: 8) {
                folderContextMenu(project: project)
                trustPolicyMenu(project: project)

                Spacer(minLength: 4)

                Text("\(store.selectedProjectAgents.count) crew · \(store.selectedProjectTasks.count) tasks")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // Quiet Watch Horizon Bar + Compact Live Ticker
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(HelmSurface.line)
                            .frame(height: 2)

                        if openCount == 0 && (project.status == .running || project.status == .completed || horizonPingOverride) {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [HelmSemantic.steady.opacity(0.2), HelmSemantic.steady, HelmSemantic.steady.opacity(0.2)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .opacity(horizonPingOverride ? 0.75 : max(0.35, pulseOpacity))
                                .frame(width: min(geo.size.width * 0.34, 240), height: 2)
                        } else if openCount > 0 {
                            Capsule()
                                .fill(HelmSemantic.attention)
                                .frame(width: geo.size.width, height: 2)
                        }
                    }
                }
                .frame(height: 2)

                if project.status == .running && openCount == 0 {
                    let activeTasks = store.selectedProjectActiveTasks
                    let latest = store.selectedProjectLatestEvent
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        if let firstActive = activeTasks.first,
                           let worker = store.selectedProjectAgents.first(where: { $0.id == firstActive.assignedAgentID }) {
                            Text("Working now:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmSemantic.steady)
                            Text("\(worker.name) (\(worker.backend.displayName)) — \(firstActive.title)")
                                .font(.caption)
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            if activeTasks.count > 1 {
                                Text("+\(activeTasks.count - 1) more")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(HelmInk.secondary)
                            }
                        } else if let latest {
                            Text("Orchestrator active:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmSemantic.steady)
                            Text(latest.summary.replacingOccurrences(of: "STEADY_OK: ", with: ""))
                                .font(.caption)
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                        } else {
                            Text("Crew ready — send a message below or watch autonomous tasks run")
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(HelmSemantic.steadySoft, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .helmCard(cornerRadius: HelmRadius.card)
        .onChange(of: pingCount) { _, _ in
            guard !effectiveReduceMotion else { return }
            pulseOpacity = 0.95
            withAnimation(HelmMotion.pulseSweep) {
                pulseOpacity = 0.35
            }
        }
    }

    private func headerActionButtons(project: Project, compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 5) {
            if project.status == .running {
                Button {
                    Task { await store.pauseSelectedProject() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
            } else {
                Button {
                    Task { await store.startSelectedProject() }
                } label: {
                    Label(compact ? "Watch" : "Start Watch", systemImage: "play.fill")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .disabled(project.status == .held)
            }

            Button {
                store.showAddAgentSheet = true
            } label: {
                if compact {
                    Image(systemName: "plus")
                } else {
                    Label("Agent", systemImage: "plus")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(HelmSecondaryButtonStyle())
            .help("Add Agent (⇧⌘A)")

            Button {
                withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                    store.isInspectorVisible.toggle()
                }
            } label: {
                Image(systemName: store.isInspectorVisible ? "sidebar.right" : "sidebar.trailing")
                    .foregroundStyle(store.isInspectorVisible ? HelmAccent.primary : HelmInk.secondary)
            }
            .buttonStyle(HelmSecondaryButtonStyle())
            .help("Toggle Agent Inspector (⌥⌘I)")
        }
    }

    private func folderContextMenu(project: Project) -> some View {
        Menu {
            Text(project.workspaceRoot.path)
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.workspaceRoot])
            } label: {
                Label("Reveal Folder in Finder", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.workspaceRoot.path, forType: .string)
            } label: {
                Label("Copy Folder Path", systemImage: "doc.on.doc")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(HelmAccent.primary)
                Text(project.workspaceRoot.lastPathComponent)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(HelmInk.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSurface.well, in: Capsule())
            .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("Project folder: \(project.workspaceRoot.path)")
    }

    private func trustPolicyMenu(project: Project) -> some View {
        Menu {
            ForEach(SandboxTrustPolicy.allCases, id: \.self) { policy in
                Button {
                    Task {
                        do {
                            try await store.updateProjectTrustPolicy(policy, projectID: project.id)
                        } catch {
                            store.bannerErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    if project.sandboxTrustPolicy == policy {
                        Label("\(policy.displayName) — \(policy.summary)", systemImage: "checkmark")
                    } else {
                        Text("\(policy.displayName) — \(policy.summary)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: trustPolicySymbol(project.sandboxTrustPolicy))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(trustPolicyColor(project.sandboxTrustPolicy))
                Text(project.sandboxTrustPolicy.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HelmInk.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(HelmInk.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HelmSurface.well, in: Capsule())
            .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("\(project.sandboxTrustPolicy.displayName): \(project.sandboxTrustPolicy.summary)")
    }

    private func trustPolicySymbol(_ policy: SandboxTrustPolicy) -> String {
        switch policy {
        case .sandboxed: return "lock.shield.fill"
        case .standardWorkspace: return "folder.badge.gearshape"
        case .trustedFullAccess: return "checkmark.shield.fill"
        }
    }

    private func trustPolicyColor(_ policy: SandboxTrustPolicy) -> Color {
        switch policy {
        case .sandboxed: return HelmAccent.brass
        case .standardWorkspace: return HelmAccent.primary
        case .trustedFullAccess: return HelmSemantic.steady
        }
    }

    // MARK: - Inline Alerts Strip

    private func bannerErrorStrip(_ err: String) -> some View {
        HStack(spacing: HelmSpace.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(HelmSemantic.critical)
            Text(err)
                .font(.callout)
                .foregroundStyle(HelmInk.primary)
                .lineLimit(2)
            Spacer()
            if isAuthRequiredText(err) {
                Button {
                    store.openSettingsToAuth(
                        highlighting: inferredAuthProvider(from: err, agent: nil)
                    )
                } label: {
                    Label("Sign In in Settings…", systemImage: "person.badge.key.fill")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmPrimaryButtonStyle())
            }
            Button("Dismiss") {
                store.bannerErrorMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(HelmSpace.l)
        .background(HelmSemantic.criticalSoft, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
    }

    private var exceptionStrip: some View {
        let alerts = store.selectedProjectOpenExceptions
        let visibleAlerts = showAllExceptions ? alerts : Array(alerts.prefix(1))

        return VStack(alignment: .leading, spacing: HelmSpace.s) {
            ForEach(visibleAlerts) { alert in
                exceptionCard(for: alert)
            }

            if alerts.count > 1 {
                Button {
                    withAnimation(HelmMotion.micro) {
                        showAllExceptions.toggle()
                    }
                } label: {
                    Text(showAllExceptions
                        ? "Collapse additional alerts"
                        : "+ \(alerts.count - 1) more open alert\(alerts.count - 1 == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmSemantic.attention)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func exceptionCard(for alert: ExceptionAlert) -> some View {
        let offendingAgent = store.selectedProjectAgents.first(where: { $0.id == alert.agentID })
        let needsAuth = isAuthRequiredException(alert)
        let matchedProvider = inferredAuthProvider(
            from: "\(alert.title) \(alert.diagnosticSummary)",
            agent: offendingAgent
        )

        return VStack(spacing: HelmSpace.s) {
            ExceptionBannerView(
                alert: alert,
                offendingAgent: offendingAgent,
                onResolve: { resolution in
                    Task {
                        await store.resolveException(alert, resolution: resolution)
                    }
                },
                onInspectAgent: { agentID in
                    withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                        store.inspectAgent(agentID)
                    }
                }
            )

            if needsAuth {
                HStack(spacing: HelmSpace.m) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HelmAccent.primary)
                        .frame(width: 28, height: 28)
                        .background(HelmAccent.primarySoft, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            matchedProvider.map { "\($0.displayName) sign-in required" }
                                ?? "CLI sign-in required"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)

                        Text("Authenticate in Helm Settings, then click Retry above to resume automatically.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: HelmSpace.m)

                    Button {
                        store.openSettingsToAuth(highlighting: matchedProvider)
                    } label: {
                        Label("Sign In in Settings…", systemImage: "arrow.up.right.circle.fill")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }
                .padding(.horizontal, HelmSpace.l)
                .padding(.vertical, HelmSpace.m)
                .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                        .strokeBorder(HelmAccent.primary.opacity(0.38), lineWidth: 1.0)
                )
            }
        }
    }

    private func isAuthRequiredException(_ alert: ExceptionAlert) -> Bool {
        isAuthRequiredText(alert.title) || isAuthRequiredText(alert.diagnosticSummary)
    }

    private func isAuthRequiredText(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("Sign-In Required")
            || text.localizedCaseInsensitiveContains("not logged in")
            || text.localizedCaseInsensitiveContains("auth login")
            || text.localizedCaseInsensitiveContains("authentication required")
    }

    private func inferredAuthProvider(from text: String, agent: AgentProfile?) -> CLIAuthProviderKind? {
        if let agent, let provider = CLIAuthProviderKind.from(backend: agent.backend) {
            return provider
        }
        if text.localizedCaseInsensitiveContains("claude") {
            return .claude
        }
        if text.localizedCaseInsensitiveContains("codex") {
            return .codex
        }
        if text.localizedCaseInsensitiveContains("antigravity")
            || text.localizedCaseInsensitiveContains("agy") {
            return .agy
        }
        if text.localizedCaseInsensitiveContains("pi cli")
            || text.localizedCaseInsensitiveContains("pycli")
            || text.localizedCaseInsensitiveContains("`pi`") {
            return .pi
        }
        return nil
    }

    // MARK: - Horizontal Zero-Truncation Crew Roster Strip

    private func crewRosterStrip(project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Crew")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.secondary)
                Text("\(store.selectedProjectAgents.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(HelmSurface.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 0.75))

                Spacer()

                Text("Click card for 1-on-1 chat · slider icon for prompt & settings")
                    .font(.caption2)
                    .foregroundStyle(HelmInk.muted)
                    .lineLimit(1)
            }

            if store.selectedProjectAgents.isEmpty {
                HStack(spacing: 12) {
                    AgentCharacterCanvas(
                        seed: AgentCharacterSeed(agentID: UUID(uuidString: "22222222-2222-2222-2222-222222222201")!, isOrchestrator: false),
                        state: .idle,
                        size: 38,
                        showStageBacking: true,
                        interactive: false
                    )
                    Text("No agents attached to \(project.name) yet.")
                        .font(.callout)
                        .foregroundStyle(HelmInk.secondary)
                    Spacer()
                    Button {
                        store.showAddAgentSheet = true
                    } label: {
                        Label("Add Agent", systemImage: "plus")
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }
                .padding(12)
                .helmCard(cornerRadius: HelmRadius.panel)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.selectedProjectAgents) { agent in
                            crewRosterCard(agent)
                        }
                        addAgentRosterChip
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func crewRosterCard(_ agent: AgentProfile) -> some View {
        let isDirectSelected = store.selectedChatChannel == .direct(agentID: agent.id)
        let isInspected = store.isInspectorVisible && store.selectedAgent?.id == agent.id
        let isSelected = isDirectSelected || isInspected
        let isHovered = hoveredAgentID == agent.id
        let isLead = agent.role == .orchestrator
        let currentTask = store.activeTask(for: agent.id)
        let isActivelyWorking = currentTask != nil || agent.activityState == .thinking || agent.activityState == .executing || agent.activityState == .browsing

        return HStack(alignment: .center, spacing: 10) {
            AgentCharacterCanvas(
                seed: agent.characterSeed,
                state: agent.activityState,
                size: 40,
                showStageBacking: true,
                interactive: false
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .fixedSize(horizontal: true, vertical: false)

                    if isLead {
                        Text("Lead")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HelmAccent.brass)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(HelmAccent.brassSoft, in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 6)

                    Button {
                        withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                            store.inspectAgent(agent.id)
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isInspected ? HelmAccent.primary : HelmInk.muted)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isInspected ? HelmAccent.primarySoft : HelmSurface.well)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Configure \(agent.name) & edit system prompt")
                }

                Text("\(agent.role.displayName) · \(agent.backend.displayName)")
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 6) {
                    AgentStatusBadge(state: agent.activityState)
                }
            }
        }
        .frame(minWidth: 204, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .helmCard(
            cornerRadius: HelmRadius.panel,
            isSelected: isSelected,
            accentBorder: agent.activityState == .exception
                ? HelmSemantic.attention.opacity(0.55)
                : (isActivelyWorking && !isSelected
                    ? HelmSemantic.steady.opacity(0.40)
                    : (isLead && !isSelected ? HelmAccent.brass.opacity(0.28) : nil))
        )
        .offset(y: isHovered && !effectiveReduceMotion ? -1 : 0)
        .animation(HelmMotion.bouncy, value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                store.selectAgent(agent.id, openDirectChat: true, openInspector: false)
            }
        }
        .onHover { hovering in
            hoveredAgentID = hovering ? agent.id : (hoveredAgentID == agent.id ? nil : hoveredAgentID)
        }
    }

    private var addAgentRosterChip: some View {
        Button {
            store.showAddAgentSheet = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HelmAccent.primary)
                Text("Add Agent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 104, minHeight: 68)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .fill(HelmSurface.elevated.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .strokeBorder(HelmSurface.lineStrong, style: StrokeStyle(lineWidth: 1.1, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Deploy another specialized agent (⇧⌘A)")
    }

    // MARK: - Width-Aware Workspace Body (Chat + Secondary Pane)

    private func workspaceBody(project: Project) -> some View {
        GeometryReader { geo in
            if geo.size.width >= 780 {
                let secondaryWidth = min(420, max(340, geo.size.width * 0.37))
                HStack(alignment: .top, spacing: 14) {
                    chatCenterPane(project: project)
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

                    secondaryPane(project: project)
                        .frame(width: secondaryWidth)
                        .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    Picker("Workspace Mode", selection: $narrowMode) {
                        Text("Chat").tag(NarrowWorkspaceMode.chat)
                        Text("Live Work").tag(NarrowWorkspaceMode.liveWork)
                        Text("Tasks (\(store.selectedProjectTasks.count))").tag(NarrowWorkspaceMode.tasks)
                        Text("Memory (\(store.selectedProjectSharedState.count))").tag(NarrowWorkspaceMode.memory)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: narrowMode) { _, mode in
                        switch mode {
                        case .chat: break
                        case .liveWork: store.secondaryTab = .liveWork
                        case .tasks: store.secondaryTab = .tasks
                        case .memory: store.secondaryTab = .memory
                        }
                    }

                    if narrowMode == .chat {
                        chatCenterPane(project: project)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        secondaryPaneContent(project: project)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Chat Center Pane (R1)

    private func chatCenterPane(project: Project) -> some View {
        let messages = store.selectedChatMessages
        let channel = store.selectedChatChannel
        let targetLabel = chatTargetLabel(channel: channel)

        return VStack(spacing: 0) {
            // Channel Switcher Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(chatChannelHeaderTitle(channel: channel))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)

                    Spacer()

                    if case .direct(let agentID) = channel {
                        Button {
                            store.inspectAgent(agentID)
                        } label: {
                            Label("Configure Agent", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.medium))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(HelmAccent.primary)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        channelPill(
                            title: "Shared Crew",
                            systemImage: "person.3.fill",
                            agent: nil,
                            isActive: channel == .crew
                        ) {
                            store.selectChatChannel(.crew)
                        }

                        ForEach(store.selectedProjectAgents) { agent in
                            channelPill(
                                title: agent.name,
                                systemImage: nil,
                                agent: agent,
                                isActive: channel == .direct(agentID: agent.id)
                            ) {
                                store.selectChatChannel(.direct(agentID: agent.id))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(HelmSurface.line)

            // Message Feed
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            chatEmptyState(project: project, channel: channel)
                        } else {
                            ForEach(messages) { message in
                                chatMessageCard(message: message, project: project)
                                    .id(message.id)
                            }
                        }

                        if store.isSendingSelectedChat {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Sending to \(targetLabel)…")
                                    .font(.caption)
                                    .foregroundStyle(HelmInk.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { _, _ in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
                .onChange(of: channel) { _, _ in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }

            Divider().overlay(HelmSurface.line)

            // Bottom Composer with Folder Context
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(HelmAccent.primary)
                        Text(project.workspaceRoot.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(HelmSurface.well, in: Capsule())

                    Text("To: \(targetLabel)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text("⌘↩ to send")
                        .font(.caption2)
                        .foregroundStyle(HelmInk.muted)
                }

                if let chatErr = store.selectedChatError, !chatErr.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(HelmSemantic.critical)
                        Text(chatErr)
                            .font(.caption)
                            .foregroundStyle(HelmSemantic.critical)
                            .lineLimit(2)
                        Spacer()
                        Button("Dismiss") {
                            store.chatErrorByProject[project.id] = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(HelmSemantic.criticalSoft, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        "Message \(targetLabel) about \(project.workspaceRoot.lastPathComponent)…",
                        text: $composerText,
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                            .strokeBorder(HelmSurface.line, lineWidth: 1)
                    )
                    .onSubmit {
                        submitComposer()
                    }

                    Button {
                        submitComposer()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSendingSelectedChat)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(12)
        }
        .helmCard(cornerRadius: HelmRadius.card)
    }

    private func submitComposer() {
        let rawDraft = composerText
        let draft = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !store.isSendingSelectedChat else { return }
        let targetProjectID = store.selectedProject?.id
        let targetChannel = store.selectedChatChannel
        composerText = ""
        Task {
            let outcome = await store.sendChatMessageWithOutcome(
                content: draft,
                to: targetChannel,
                projectID: targetProjectID
            )
            if outcome.shouldRestoreDraft,
               composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerText = rawDraft
            }
        }
    }

    private func channelPill(
        title: String,
        systemImage: String?,
        agent: AgentProfile?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let agent {
                    AgentCharacterCanvas(
                        seed: agent.characterSeed,
                        state: agent.activityState,
                        size: 16,
                        showStageBacking: false,
                        interactive: false
                    )
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? HelmAccent.primary : HelmInk.secondary)
                }

                Text(title)
                    .font(.caption.weight(isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? HelmInk.primary : HelmInk.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isActive ? HelmAccent.primarySoft : HelmSurface.well)
            )
            .overlay(
                Capsule().strokeBorder(isActive ? HelmAccent.primary.opacity(0.45) : HelmSurface.line, lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
    }

    private func chatChannelHeaderTitle(channel: ChatChannelKind) -> String {
        switch channel {
        case .crew:
            return "Shared Crew Chat"
        case .direct(let agentID):
            if let agent = store.selectedProjectAgents.first(where: { $0.id == agentID }) {
                return "1-on-1 with \(agent.name)"
            }
            return "Direct Agent Chat"
        }
    }

    private func chatTargetLabel(channel: ChatChannelKind) -> String {
        switch channel {
        case .crew:
            return "Shared Crew"
        case .direct(let agentID):
            if let agent = store.selectedProjectAgents.first(where: { $0.id == agentID }) {
                return "\(agent.name) (1-on-1)"
            }
            return "Agent"
        }
    }

    private func chatEmptyState(project: Project, channel: ChatChannelKind) -> some View {
        let starters: [String] = {
            switch channel {
            case .crew:
                return [
                    "Inspect the project folder and summarize the architecture and next steps.",
                    "Run tests in the workspace and report any failures."
                ]
            case .direct(let agentID):
                let name = store.selectedProjectAgents.first(where: { $0.id == agentID })?.name ?? "this agent"
                return [
                    "Review \(project.workspaceRoot.lastPathComponent) and report what you find.",
                    "Tell me your current plan and start executing with \(name)'s tools."
                ]
            }
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: channel == .crew ? "person.3.fill" : "bubble.left.and.bubble.right.fill")
                    .font(.title3)
                    .foregroundStyle(HelmAccent.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chatChannelHeaderTitle(channel: channel))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text("Folder context attached automatically: \(project.workspaceRoot.path)")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Try a prompt:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.muted)
                ForEach(starters, id: \.self) { prompt in
                    Button {
                        composerText = prompt
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(HelmAccent.primary)
                            Text(prompt)
                                .font(.caption)
                                .foregroundStyle(HelmInk.primary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                                .strokeBorder(HelmSurface.line, lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HelmSurface.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
    }

    private func chatMessageCard(message: ChatMessage, project: Project) -> some View {
        let isUser = message.senderKind == .user
        let senderAgent = message.senderAgentID.flatMap { id in
            store.selectedProjectAgents.first(where: { $0.id == id })
        }
        let linkedTask = message.relatedTaskID.flatMap { tid in
            store.selectedProjectTasks.first(where: { $0.id == tid })
        }

        return HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 36)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if !isUser {
                        if let senderAgent {
                            AgentCharacterCanvas(
                                seed: senderAgent.characterSeed,
                                state: senderAgent.activityState,
                                size: 22,
                                showStageBacking: false,
                                interactive: false
                            )
                        } else {
                            CompassHelmLogo(size: 20, style: .emblem)
                        }
                    }

                    Text(message.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)

                    if let senderAgent {
                        MetadataTag(senderAgent.role.displayName)
                    } else if message.senderKind == .orchestrator {
                        MetadataTag("Orchestrator")
                    } else if message.senderKind == .system {
                        MetadataTag("System")
                    }

                    Spacer(minLength: 8)

                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(HelmInk.muted)
                }

                Text(message.content)
                    .font(.callout)
                    .foregroundStyle(HelmInk.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !message.referencedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.referencedFiles, id: \.self) { relPath in
                                fileReferenceChip(relPath: relPath, workspaceRoot: project.workspaceRoot)
                            }
                        }
                    }
                }

                if let linkedTask {
                    Button {
                        store.openTaskInWorkspace(linkedTask.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checklist")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(HelmAccent.primary)
                            Text(linkedTask.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            TaskStatusBadge(status: linkedTask.status)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous)
                                .strokeBorder(HelmSurface.line, lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open task detail")
                }
            }
            .padding(12)
            .frame(maxWidth: isUser ? 480 : .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .fill(isUser ? HelmAccent.primarySoft : HelmSurface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .strokeBorder(isUser ? HelmAccent.primary.opacity(0.28) : HelmSurface.line, lineWidth: 0.9)
            )

            if !isUser {
                Spacer(minLength: 16)
            }
        }
    }

    private func fileReferenceChip(relPath: String, workspaceRoot: URL) -> some View {
        Button {
            let fileURL = workspaceRoot.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relPath, forType: .string)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(HelmAccent.primary)
                Text(relPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HelmInk.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help(relPath)
    }

    // MARK: - Secondary Pane (Live Work / Navigable Tasks / Shared Memory)

    private func secondaryPane(project: Project) -> some View {
        VStack(spacing: 0) {
            Picker("Secondary View", selection: $store.secondaryTab) {
                Text("Live Work").tag(WorkspaceSecondaryTab.liveWork)
                Text("Tasks (\(store.selectedProjectTasks.count))").tag(WorkspaceSecondaryTab.tasks)
                Text("Memory (\(store.selectedProjectSharedState.count))").tag(WorkspaceSecondaryTab.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(HelmSurface.line)

            secondaryPaneContent(project: project)
        }
        .helmCard(cornerRadius: HelmRadius.card)
    }

    @ViewBuilder
    private func secondaryPaneContent(project: Project) -> some View {
        switch store.secondaryTab {
        case .liveWork:
            liveWorkPane(project: project)
        case .tasks:
            tasksPane(project: project)
        case .memory:
            sharedMemoryPane
        }
    }

    // MARK: - Tab 1: Live Per-Agent Work Feed

    private func liveWorkPane(project: Project) -> some View {
        let entries = Array(store.selectedWorkFeed.reversed())
        let filterID = store.selectedWorkFeedFilterAgentID

        return VStack(spacing: 0) {
            // Per-Agent Filter Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    workFilterChip(title: "All Crew", agent: nil, isActive: filterID == nil) {
                        store.setWorkFeedFilter(agentID: nil)
                    }

                    ForEach(store.selectedProjectAgents) { agent in
                        workFilterChip(title: agent.name, agent: agent, isActive: filterID == agent.id) {
                            store.setWorkFeedFilter(agentID: agent.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider().overlay(HelmSurface.line)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live Work Feed")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                            Text("Agent reasoning steps, tool calls, touched files, and outputs stream here as your crew works in \(project.workspaceRoot.lastPathComponent).")
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HelmSurface.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                    } else {
                        ForEach(entries) { entry in
                            workEntryCard(entry, workspaceRoot: project.workspaceRoot)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func workFilterChip(
        title: String,
        agent: AgentProfile?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let agent {
                    AgentCharacterCanvas(
                        seed: agent.characterSeed,
                        state: agent.activityState,
                        size: 14,
                        showStageBacking: false,
                        interactive: false
                    )
                }
                Text(title)
                    .font(.caption2.weight(isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? HelmInk.primary : HelmInk.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isActive ? HelmAccent.primarySoft : HelmSurface.well))
            .overlay(Capsule().strokeBorder(isActive ? HelmAccent.primary.opacity(0.45) : HelmSurface.line, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    private func workEntryCard(_ entry: AgentWorkEntry, workspaceRoot: URL) -> some View {
        let agent = store.selectedProjectAgents.first(where: { $0.id == entry.agentID })

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let agent {
                    AgentCharacterCanvas(
                        seed: agent.characterSeed,
                        state: agent.activityState,
                        size: 20,
                        showStageBacking: false,
                        interactive: false
                    )
                }

                Text(entry.agentName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                    .lineLimit(1)

                MetadataTag("Step \(entry.stepNumber)", monospaced: true)

                workPhaseBadge(entry.phase)

                Spacer(minLength: 4)

                Text(entry.createdAt, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.muted)
            }

            if let taskTitle = entry.taskTitle, !taskTitle.isEmpty {
                Button {
                    if let taskID = entry.taskID {
                        store.openTaskInWorkspace(taskID)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                        Text(taskTitle)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(HelmAccent.primary)
                }
                .buttonStyle(.plain)
            }

            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(HelmInk.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let toolName = entry.toolName, !toolName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(HelmAccent.primary)
                        Text(toolName)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(HelmInk.primary)
                    }
                    if let input = entry.toolInputSummary, !input.isEmpty {
                        Text(input)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(2)
                    }
                    if let output = entry.toolOutputSummary, !output.isEmpty {
                        Text("→ \(output)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(HelmInk.primary)
                            .lineLimit(3)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
            }

            if !entry.touchedFiles.isEmpty || !entry.artifactPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(entry.touchedFiles, id: \.self) { file in
                            fileReferenceChip(relPath: file, workspaceRoot: workspaceRoot)
                        }
                        ForEach(entry.artifactPaths, id: \.self) { artifact in
                            MetadataTag(artifact, monospaced: true)
                        }
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                .strokeBorder(HelmSurface.line, lineWidth: 0.85)
        )
    }

    private func workPhaseBadge(_ phase: AgentWorkPhase) -> some View {
        let spec: (label: String, color: Color, bg: Color) = {
            switch phase {
            case .planning: return ("Planning", HelmAccent.primary, HelmAccent.primarySoft)
            case .reasoning: return ("Reasoning", HelmSemantic.thinking, HelmSemantic.thinkingSoft)
            case .toolCall: return ("Tool", HelmSemantic.executing, HelmSemantic.executingSoft)
            case .fileEdit: return ("File Edit", HelmAccent.brass, HelmAccent.brassSoft)
            case .completed: return ("Done", HelmSemantic.steady, HelmSemantic.steadySoft)
            case .failed: return ("Failed", HelmSemantic.critical, HelmSemantic.criticalSoft)
            }
        }()

        return Text(spec.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(spec.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(spec.bg, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Tab 2: Interactive Navigable Tasks

    private func tasksPane(project: Project) -> some View {
        let tasks = store.selectedProjectTasks
        let activeCount = tasks.filter { $0.status == .running }.count
        let queuedCount = tasks.filter { $0.status == .queued }.count
        let doneCount = tasks.filter { $0.status == .done }.count
        let blockedCount = tasks.filter { $0.status == .blocked || $0.status == .needsHuman || $0.status == .failed }.count

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                taskSummaryChip(label: "\(activeCount) Active", color: HelmSemantic.thinking, bg: HelmSemantic.thinkingSoft)
                taskSummaryChip(label: "\(queuedCount) Queued", color: HelmInk.secondary, bg: HelmSurface.well)
                taskSummaryChip(label: "\(doneCount) Done", color: HelmSemantic.steady, bg: HelmSemantic.steadySoft)
                if blockedCount > 0 {
                    taskSummaryChip(label: "\(blockedCount) Blocked", color: HelmSemantic.attention, bg: HelmSemantic.attentionSoft)
                }
                Spacer(minLength: 0)
                if store.selectedTask != nil {
                    Button("Clear") {
                        store.selectTask(nil)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HelmAccent.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(HelmSurface.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let selectedTask = store.selectedTask {
                        selectedTaskDetailCard(selectedTask, allTasks: tasks, workspaceRoot: project.workspaceRoot)
                    }

                    if tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No tasks yet")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                            Text("Send a goal in Shared Crew Chat or press Start Watch to break work into tasks for your crew.")
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HelmSurface.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                    } else {
                        ForEach(tasks) { task in
                            interactiveTaskRow(task, allTasks: tasks)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func taskSummaryChip(label: String, color: Color, bg: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func selectedTaskDetailCard(
        _ task: DelegatedTask,
        allTasks: [DelegatedTask],
        workspaceRoot: URL
    ) -> some View {
        let assignee = store.selectedProjectAgents.first(where: { $0.id == task.assignedAgentID })
        let upstream = task.waitingOn.compactMap { depID in allTasks.first(where: { $0.id == depID }) }
        let downstream = allTasks.filter { $0.waitingOn.contains(task.id) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(HelmInk.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Attempt \(task.attemptCount)/\(task.maxAttempts)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(HelmInk.muted)
                }

                Spacer(minLength: 6)

                TaskStatusBadge(status: task.status)
            }

            if let assignee {
                HStack(spacing: 8) {
                    AgentCharacterCanvas(
                        seed: assignee.characterSeed,
                        state: assignee.activityState,
                        size: 20,
                        showStageBacking: false,
                        interactive: false
                    )
                    Text(assignee.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    MetadataTag(assignee.role.displayName)
                    Spacer()
                    Button {
                        store.selectAgent(assignee.id, openDirectChat: true, openInspector: false)
                    } label: {
                        Label("Chat with \(assignee.name)", systemImage: "bubble.left.fill")
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HelmInk.muted)
                Text(task.instructions)
                    .font(.caption)
                    .foregroundStyle(HelmInk.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !upstream.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting On")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HelmInk.muted)
                    ForEach(upstream) { dep in
                        Button {
                            store.selectTask(dep.id)
                        } label: {
                            HStack(alignment: .center, spacing: 6) {
                                Image(systemName: "arrow.up.left")
                                    .font(.caption2)
                                    .foregroundStyle(HelmAccent.primary)
                                Text(dep.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(HelmInk.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                TaskStatusBadge(status: dep.status)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !downstream.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unblocks")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HelmInk.muted)
                    ForEach(downstream) { nextTask in
                        Button {
                            store.selectTask(nextTask.id)
                        } label: {
                            HStack(alignment: .center, spacing: 6) {
                                Image(systemName: "arrow.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(HelmAccent.primary)
                                Text(nextTask.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(HelmInk.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                TaskStatusBadge(status: nextTask.status)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let err = task.errorSummary, !err.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Blocker / Error")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HelmSemantic.critical)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(HelmSemantic.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HelmSemantic.criticalSoft, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
            }

            if let res = task.resultSummary, !res.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Output Summary")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HelmSemantic.steady)
                    Text(res)
                        .font(.caption)
                        .foregroundStyle(HelmInk.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HelmSemantic.steadySoft, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
            }

            if !task.artifactPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Artifacts")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HelmInk.muted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(task.artifactPaths, id: \.self) { path in
                                fileReferenceChip(relPath: path, workspaceRoot: workspaceRoot)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .helmCard(cornerRadius: HelmRadius.panel, isSelected: true)
    }

    private func interactiveTaskRow(_ task: DelegatedTask, allTasks: [DelegatedTask]) -> some View {
        let isSelected = store.selectedTaskID == task.id
        let assignee = store.selectedProjectAgents.first(where: { $0.id == task.assignedAgentID })
        let depTitles = task.waitingOn.compactMap { depID in
            allTasks.first(where: { $0.id == depID })?.title
        }

        return Button {
            store.selectTask(isSelected ? nil : task.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    Spacer(minLength: 6)

                    TaskStatusBadge(status: task.status)
                }

                HStack(spacing: 8) {
                    if let assignee {
                        HStack(spacing: 5) {
                            AgentCharacterCanvas(seed: assignee.characterSeed, state: assignee.activityState, size: 15)
                            Text(assignee.name)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                        }
                    }

                    if !depTitles.isEmpty {
                        Text("After: \(depTitles.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(HelmSemantic.attention)
                            .lineLimit(1)
                    }

                    if !task.artifactPaths.isEmpty {
                        MetadataTag("\(task.artifactPaths.count) artifact\(task.artifactPaths.count == 1 ? "" : "s")")
                    }
                }

                if let detail = task.errorSummary ?? task.resultSummary, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(task.errorSummary != nil ? HelmSemantic.critical : HelmInk.secondary)
                        .lineLimit(2)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .helmCard(cornerRadius: HelmRadius.panel, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 3: Compact Shared Memory

    private var sharedMemoryPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if store.selectedProjectSharedState.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shared memory is clear")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                        Text("Verified facts, project rules, and observations captured by your crew appear here.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HelmSurface.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                } else {
                    ForEach(store.selectedProjectSharedState, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(friendlyKey(entry.key))
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(HelmInk.primary)
                                    .lineLimit(1)

                                Spacer(minLength: HelmSpace.s)

                                TrustLevelBadge(trustLevel: entry.trustLevel)
                            }

                            Text(entry.content)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .helmCard(cornerRadius: HelmRadius.panel)
                        .help("Key: \(entry.key) · Digest: \(String(entry.digest.prefix(12)))")
                    }
                }
            }
            .padding(12)
        }
    }

    private func friendlyKey(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " · ")
            .capitalized
    }

    // MARK: - Empty Workspace (when onboarding skipped)

    private var emptyWorkspaceView: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                AgentCharacterCanvas(
                    seed: AgentCharacterSeed(agentID: UUID(uuidString: "33333333-3333-3333-3333-333333333301")!, isOrchestrator: true),
                    state: .idle,
                    size: 58,
                    showStageBacking: true,
                    interactive: true
                )
                AgentCharacterCanvas(
                    seed: AgentCharacterSeed(agentID: UUID(uuidString: "33333333-3333-3333-3333-333333333302")!, isOrchestrator: false),
                    state: .executing,
                    size: 58,
                    showStageBacking: true,
                    interactive: true
                )
                AgentCharacterCanvas(
                    seed: AgentCharacterSeed(agentID: UUID(uuidString: "33333333-3333-3333-3333-333333333303")!, isOrchestrator: false),
                    state: .browsing,
                    size: 58,
                    showStageBacking: true,
                    interactive: true
                )
            }

            VStack(spacing: 8) {
                Text("Ready when you are")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(HelmInk.primary)
                Text("Create a project or walk through the 30-second setup to configure your AI provider and deploy your first crew.")
                    .font(.body)
                    .foregroundStyle(HelmInk.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 12) {
                Button {
                    store.showNewProjectSheet = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(HelmPrimaryButtonStyle())

                Button {
                    store.reopenOnboarding()
                } label: {
                    Label("Guided Setup", systemImage: "sparkles")
                }
                .buttonStyle(HelmSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HelmSurface.canvas)
    }
}
