import HelmCore
import SwiftUI

public struct ProjectCanvasView: View {
    @Bindable var store: HelmWorkspaceStore
    public let horizonPingOverride: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion

    @State private var pulseOpacity: Double = 0
    @State private var hoveredAgentID: UUID?

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        headerStrip(project: project)

                        if let err = store.bannerErrorMessage {
                            HStack(spacing: HelmSpace.m) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(HelmSemantic.critical)
                                Text(err)
                                    .font(.callout)
                                    .foregroundStyle(HelmInk.primary)
                                Spacer()
                                Button("Dismiss") {
                                    store.bannerErrorMessage = nil
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(HelmSpace.l)
                            .background(HelmSemantic.criticalSoft, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                        }

                        // Exception Alert Strip — completely absent/collapsed when 0 open exceptions
                        if !store.selectedProjectOpenExceptions.isEmpty {
                            VStack(spacing: HelmSpace.m) {
                                ForEach(store.selectedProjectOpenExceptions) { alert in
                                    ExceptionBannerView(
                                        alert: alert,
                                        offendingAgent: store.selectedProjectAgents.first(where: { $0.id == alert.agentID }),
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
                                }
                            }
                            .transition(
                                effectiveReduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .opacity
                                    )
                            )
                        }

                        // Living Crew Stage (Prominent Animated Bot Cards)
                        crewStageSection

                        // Work & Shared Memory Columns
                        HStack(alignment: .top, spacing: 18) {
                            delegatedTasksColumn
                                .frame(maxWidth: .infinity, alignment: .leading)

                            sharedStateColumn
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(24)
                }
                .background(HelmSurface.canvas)
                .animation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state, value: store.selectedProjectOpenExceptions.count)
            } else {
                emptyWorkspaceView
            }
        }
    }

    // MARK: - Calm Project Header

    private func headerStrip(project: Project) -> some View {
        let pingCount = store.horizonPingCounterByProject[project.id] ?? 0
        let openCount = store.selectedProjectOpenExceptions.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CompassHelmLogo(
                    size: 38,
                    style: .emblem,
                    hasOpenException: openCount > 0,
                    settleTrigger: store.settleHelmCounter
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)

                    Text(project.goal)
                        .font(.callout)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(2)
                        .help(project.goal)
                }

                Spacer(minLength: HelmSpace.l)

                HStack(spacing: 8) {
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
                            Label("Start Watch", systemImage: "play.fill")
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                        .disabled(project.status == .held)
                    }

                    Button {
                        store.showAddAgentSheet = true
                    } label: {
                        Label("Add Agent", systemImage: "plus")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())

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

            // Quiet Watch Horizon Bar
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(HelmSurface.line)
                            .frame(height: 2.5)

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
                                .frame(width: min(geo.size.width * 0.34, 240), height: 2.5)
                        } else if openCount > 0 {
                            Capsule()
                                .fill(HelmSemantic.attention)
                                .frame(width: geo.size.width, height: 2.5)
                        }
                    }
                }
                .frame(height: 2.5)

                HStack(spacing: 10) {
                    ProjectStatusBadge(status: project.status)

                    Text(calmStatusSummary(for: project, openCount: openCount))
                        .font(.caption)
                        .foregroundStyle(openCount == 0 ? HelmInk.secondary : HelmSemantic.attention)

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(HelmInk.muted)
                        Text(project.workspaceRoot.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HelmInk.muted)
                            .lineLimit(1)
                    }

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(HelmInk.muted)

                    Text("\(store.selectedProjectAgents.count) crew · \(store.selectedProjectTasks.count) tasks")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HelmInk.secondary)
                }
            }
        }
        .padding(18)
        .helmCard(cornerRadius: HelmRadius.hero)
        .onChange(of: pingCount) { _, _ in
            guard !effectiveReduceMotion else { return }
            pulseOpacity = 0.95
            withAnimation(HelmMotion.pulseSweep) {
                pulseOpacity = 0.35
            }
        }
    }

    private func calmStatusSummary(for project: Project, openCount: Int) -> String {
        if openCount > 0 {
            return "Paused — waiting for your decision"
        }
        switch project.status {
        case .running:
            return "Running quietly in background · zero interruptions"
        case .completed:
            return "All tasks finished quietly"
        case .paused:
            return "Watch paused · resume anytime"
        case .idle:
            return "Ready to deploy your autonomous crew"
        case .held:
            return "Paused for review"
        case .failed:
            return "Needs attention to recover"
        }
    }

    // MARK: - Living Crew Stage (Prominent Animated Bot Grid)

    private var crewStageSection: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14)]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Autonomous Crew")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)

                Text("\(store.selectedProjectAgents.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(HelmSurface.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 0.75))

                Spacer()

                Text("Click any bot to inspect")
                    .font(.caption)
                    .foregroundStyle(HelmInk.muted)
            }

            if store.selectedProjectAgents.isEmpty {
                HStack(spacing: 16) {
                    AgentCharacterCanvas(
                        seed: AgentCharacterSeed(agentID: UUID(uuidString: "22222222-2222-2222-2222-222222222201")!, isOrchestrator: false),
                        state: .idle,
                        size: 52,
                        showStageBacking: true,
                        interactive: true
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your stage is empty")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                        Text("Add specialized agents — researchers, coders, or browser analysts — to start autonomous work.")
                            .font(.callout)
                            .foregroundStyle(HelmInk.secondary)
                    }
                    Spacer()
                    Button {
                        store.showAddAgentSheet = true
                    } label: {
                        Label("Add Agent", systemImage: "plus")
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }
                .padding(18)
                .helmCard(cornerRadius: HelmRadius.card)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(store.selectedProjectAgents) { agent in
                        agentStageCard(agent)
                    }
                }
            }
        }
    }

    private func agentStageCard(_ agent: AgentProfile) -> some View {
        let isSelected = store.isInspectorVisible && store.selectedAgent?.id == agent.id
        let isHovered = hoveredAgentID == agent.id
        let isLead = agent.role == .orchestrator

        return Button {
            withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                store.inspectAgent(agent.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    AgentCharacterCanvas(
                        seed: agent.characterSeed,
                        state: agent.activityState,
                        size: 56,
                        showStageBacking: true,
                        interactive: false
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)

                            if isLead {
                                Text("Lead")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(HelmAccent.brass)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(HelmAccent.brassSoft, in: Capsule())
                            }
                        }

                        Text("\(agent.role.displayName) · \(agent.backend.displayName)")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(1)

                        AgentStatusBadge(state: agent.activityState)
                            .padding(.top, 2)
                    }

                    Spacer(minLength: 0)
                }

                Text(agent.goal)
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .helmCard(
                cornerRadius: HelmRadius.card,
                isSelected: isSelected,
                accentBorder: agent.activityState == .exception
                    ? HelmSemantic.attention.opacity(0.55)
                    : (isLead && !isSelected ? HelmAccent.brass.opacity(0.28) : nil)
            )
            .offset(y: isHovered && !effectiveReduceMotion ? -2 : 0)
            .animation(HelmMotion.bouncy, value: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredAgentID = hovering ? agent.id : (hoveredAgentID == agent.id ? nil : hoveredAgentID)
        }
    }

    // MARK: - Active Tasks & Shared Memory

    private var delegatedTasksColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tasks")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                Text("\(store.selectedProjectTasks.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
            }

            VStack(spacing: 0) {
                if store.selectedProjectTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No tasks yet")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HelmInk.primary)
                        Text("Press Start Watch and Compass will break your project goal into tasks for your crew.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                } else {
                    ForEach(Array(store.selectedProjectTasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider().overlay(HelmSurface.line)
                        }
                        taskRow(task)
                    }
                }
            }
            .helmCard(cornerRadius: HelmRadius.card)
        }
    }

    private func taskRow(_ task: DelegatedTask) -> some View {
        let assignee = store.selectedProjectAgents.first(where: { $0.id == task.assignedAgentID })

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let assignee {
                            HStack(spacing: 5) {
                                AgentCharacterCanvas(seed: assignee.characterSeed, state: assignee.activityState, size: 16)
                                Text(assignee.name)
                                    .font(.caption)
                                    .foregroundStyle(HelmInk.secondary)
                            }
                        }
                        if !task.waitingOn.isEmpty {
                            Text("Waiting on \(task.waitingOn.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(HelmSemantic.attention)
                        }
                    }
                }

                Spacer(minLength: HelmSpace.s)

                TaskStatusBadge(status: task.status)
            }

            if let detail = task.errorSummary ?? task.resultSummary, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(task.errorSummary != nil ? HelmSemantic.critical : HelmInk.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var sharedStateColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shared Memory")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                Text("\(store.selectedProjectSharedState.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
            }

            VStack(spacing: 0) {
                if store.selectedProjectSharedState.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shared memory is clear")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HelmInk.primary)
                        Text("Verified facts, project rules, and web observations captured by your crew appear here.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                } else {
                    ForEach(Array(store.selectedProjectSharedState.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(HelmSurface.line)
                        }
                        sharedStateRow(entry)
                    }
                }
            }
            .helmCard(cornerRadius: HelmRadius.card)
        }
    }

    private func sharedStateRow(_ entry: RunSharedStateSummary) -> some View {
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
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .help("Key: \(entry.key) · Digest: \(String(entry.digest.prefix(12)))")
    }

    private func friendlyKey(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " · ")
            .capitalized
    }

    // MARK: - Inviting Empty Workspace (when onboarding skipped)

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
