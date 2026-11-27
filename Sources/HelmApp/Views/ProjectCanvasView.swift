import HelmCore
import SwiftUI

public struct ProjectCanvasView: View {
    @Bindable var store: HelmWorkspaceStore
    public let horizonPingOverride: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion

    @State private var pulseOpacity: Double = 0

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
                    VStack(alignment: .leading, spacing: HelmSpace.l) {
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
                                            store.selectedAgentID = agentID
                                            store.isInspectorVisible = true
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

                        // Specialized Agent Roster
                        agentRosterSection

                        // Delegated Task DAG & Shared State Board
                        HStack(alignment: .top, spacing: HelmSpace.xl) {
                            delegatedTasksColumn
                                .frame(maxWidth: .infinity, alignment: .leading)

                            sharedStateColumn
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(HelmSpace.xxl)
                }
                .background(HelmSurface.canvas)
                .animation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state, value: store.selectedProjectOpenExceptions.count)
            } else {
                emptyWorkspaceView
            }
        }
    }

    // MARK: - Project & Orchestrator Header Strip

    private func headerStrip(project: Project) -> some View {
        let pingCount = store.horizonPingCounterByProject[project.id] ?? 0
        let openCount = store.selectedProjectOpenExceptions.count

        return VStack(alignment: .leading, spacing: HelmSpace.l) {
            HStack(alignment: .top, spacing: HelmSpace.l) {
                CompassHelmLogo(
                    size: 36,
                    style: .inlineMark,
                    hasOpenException: openCount > 0,
                    settleTrigger: store.settleHelmCounter
                )

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text(project.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)

                    Text(project.goal)
                        .font(.body)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(2)
                        .help(project.goal)
                }

                Spacer(minLength: HelmSpace.l)

                // <= 4 primary/secondary controls per cognitive load rubric
                HStack(spacing: HelmSpace.m) {
                    if project.status == .running {
                        Button {
                            Task { await store.pauseSelectedProject() }
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                    } else {
                        Button {
                            Task { await store.startSelectedProject() }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                        .disabled(project.status == .held)
                    }

                    Button {
                        store.showAddAgentSheet = true
                    } label: {
                        Label("Agent", systemImage: "plus")
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .help("Deploy Specialized Agent")

                    Menu {
                        Button("Simulate Stall") {
                            Task { await store.simulateCondition(.stall) }
                        }
                        Button("Simulate Goal Drift") {
                            Task { await store.simulateCondition(.drift) }
                        }
                        Button("Simulate Human Decision") {
                            Task { await store.simulateCondition(.humanDecision) }
                        }
                        Button("Simulate Dependency Cycle") {
                            Task { await store.simulateCondition(.cycle) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Simulate Exception Conditions")

                    Button {
                        withAnimation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state) {
                            store.isInspectorVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .help("Toggle Inspector (⌥⌘I)")
                }
            }

            // Calm Watch Horizon Strip — silent steady pulse without noisy alert banners
            VStack(alignment: .leading, spacing: HelmSpace.xs) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(HelmSurface.line)
                            .frame(height: 2)

                        if openCount == 0 && (project.status == .running || project.status == .completed || horizonPingOverride) {
                            Capsule()
                                .fill(HelmSemantic.steady.opacity(horizonPingOverride ? 0.55 : pulseOpacity))
                                .frame(width: min(geo.size.width * 0.28, 180), height: 2)
                        }
                    }
                }
                .frame(height: 2)

                HStack(spacing: HelmSpace.m) {
                    ProjectStatusBadge(status: project.status)

                    Text(openCount == 0 ? "Orchestrator Watch: Quiet (STEADY_OK)" : "Orchestrator Watch: Paused on Exception")
                        .font(.caption)
                        .foregroundStyle(openCount == 0 ? HelmInk.secondary : HelmSemantic.attention)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(HelmInk.muted)

                    Text(project.workspaceRoot.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.muted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text("\(store.selectedProjectAgents.count) agents · \(store.selectedProjectTasks.count) tasks")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HelmInk.secondary)
                }
            }
        }
        .padding(HelmSpace.xl)
        .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                .strokeBorder(HelmSurface.line, lineWidth: 1.0)
        )
        .onChange(of: pingCount) { _, _ in
            guard !effectiveReduceMotion else { return }
            pulseOpacity = 0.65
            withAnimation(HelmMotion.pulseSweep) {
                pulseOpacity = 0.15
            }
        }
    }

    // MARK: - Specialized Agent Roster

    private var agentRosterSection: some View {
        VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack {
                Text("Specialized Agent Roster")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                Text("\(store.selectedProjectAgents.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
            }
            .padding(.top, HelmSpace.xl)
            .padding(.bottom, HelmSpace.s)

            VStack(spacing: 0) {
                if store.selectedProjectAgents.isEmpty {
                    Text("No agents deployed yet. Add at least two specialists alongside the Orchestrator.")
                        .font(.callout)
                        .foregroundStyle(HelmInk.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HelmSpace.xl)
                } else {
                    ForEach(Array(store.selectedProjectAgents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 {
                            Divider().overlay(HelmSurface.line)
                        }
                        agentRow(agent)
                    }
                }
            }
            .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )
        }
    }

    private func agentRow(_ agent: AgentProfile) -> some View {
        let isSelected = store.selectedAgent?.id == agent.id

        return Button {
            store.selectedAgentID = agent.id
        } label: {
            HStack(spacing: HelmSpace.l) {
                AgentCharacterCanvas(seed: agent.characterSeed, state: agent.activityState, size: 24)

                VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                    HStack(spacing: HelmSpace.m) {
                        Text(agent.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                            .lineLimit(1)

                        MetadataTag(agent.role.displayName)
                        MetadataTag(agent.backend.displayName)
                    }

                    Text(agent.goal)
                        .font(.callout)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)
                        .help(agent.goal)
                }

                Spacer(minLength: HelmSpace.m)

                AgentStatusBadge(state: agent.activityState)
            }
            .padding(.horizontal, HelmSpace.xl)
            .padding(.vertical, HelmSpace.l)
            .background(isSelected ? HelmSurface.selectedWash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Delegated Task DAG & Shared State Board

    private var delegatedTasksColumn: some View {
        VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack {
                Text("Delegated Tasks")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                Text("\(store.selectedProjectTasks.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
            }
            .padding(.top, HelmSpace.xl)
            .padding(.bottom, HelmSpace.s)

            VStack(spacing: 0) {
                if store.selectedProjectTasks.isEmpty {
                    Text("No tasks delegated yet. Start the Orchestrator watch to decompose the project goal.")
                        .font(.callout)
                        .foregroundStyle(HelmInk.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HelmSpace.xl)
                } else {
                    ForEach(Array(store.selectedProjectTasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider().overlay(HelmSurface.line)
                        }
                        taskRow(task)
                    }
                }
            }
            .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )
        }
    }

    private func taskRow(_ task: DelegatedTask) -> some View {
        let assignee = store.selectedProjectAgents.first(where: { $0.id == task.assignedAgentID })

        return VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack(alignment: .top, spacing: HelmSpace.m) {
                VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(2)

                    HStack(spacing: HelmSpace.m) {
                        if let assignee {
                            Text(assignee.name)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
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
        .padding(.horizontal, HelmSpace.xl)
        .padding(.vertical, HelmSpace.l)
    }

    private var sharedStateColumn: some View {
        VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack {
                Text("Shared State Board")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                Text("\(store.selectedProjectSharedState.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
            }
            .padding(.top, HelmSpace.xl)
            .padding(.bottom, HelmSpace.s)

            VStack(spacing: 0) {
                if store.selectedProjectSharedState.isEmpty {
                    Text("No shared state recorded yet. Verified facts, rules, and web observations appear here.")
                        .font(.callout)
                        .foregroundStyle(HelmInk.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HelmSpace.xl)
                } else {
                    ForEach(Array(store.selectedProjectSharedState.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(HelmSurface.line)
                        }
                        sharedStateRow(entry)
                    }
                }
            }
            .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )
        }
    }

    private func sharedStateRow(_ entry: RunSharedStateSummary) -> some View {
        VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack(spacing: HelmSpace.m) {
                Text(entry.key)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HelmInk.primary)
                    .lineLimit(1)

                Spacer(minLength: HelmSpace.s)

                TrustLevelBadge(trustLevel: entry.trustLevel)
            }

            Text(entry.content)
                .font(.callout)
                .foregroundStyle(HelmInk.secondary)
                .lineLimit(2)

            HStack(spacing: HelmSpace.m) {
                MetadataTag(entry.category.rawValue)
                Text("sha256:\(String(entry.digest.prefix(10)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HelmInk.muted)
            }
        }
        .padding(.horizontal, HelmSpace.xl)
        .padding(.vertical, HelmSpace.l)
    }

    private var emptyWorkspaceView: some View {
        VStack(spacing: HelmSpace.xl) {
            CompassHelmLogo(size: 64, style: .emblem, hasOpenException: false, settleTrigger: store.settleHelmCounter)
            VStack(spacing: HelmSpace.s) {
                Text("Create Your First Autonomous Project")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text("Spin up a local workspace with specialized agents governed by an exception-only Orchestrator.")
                    .font(.body)
                    .foregroundStyle(HelmInk.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                store.showNewProjectSheet = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(HelmPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HelmSurface.canvas)
    }
}
