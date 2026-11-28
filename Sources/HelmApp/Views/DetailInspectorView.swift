import HelmCore
import SwiftUI

public struct DetailInspectorView: View {
    @Bindable var store: HelmWorkspaceStore

    @State private var draftAgentID: UUID?
    @State private var draftGoal: String = ""
    @State private var draftPersonality: AgentPersonality = .calmCommander
    @State private var draftSystemPrompt: String = ""
    @State private var draftBackend: LLMBackendKind = .claudeCLI
    @State private var isSaving: Bool = false
    @State private var justSaved: Bool = false
    @State private var saveError: String?

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Inspector Header
            VStack(spacing: 10) {
                HStack {
                    Text(store.selectedAgent?.name ?? "Inspector")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(HelmMotion.state) {
                            store.isInspectorVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HelmInk.secondary)
                            .frame(width: 22, height: 22)
                            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Hide Inspector (⌥⌘I)")
                }

                Picker("", selection: $store.inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(HelmSurface.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch store.inspectorTab {
                    case .agent:
                        agentTabContent
                    case .activity:
                        activityTabContent
                    case .timeline:
                        timelineTabContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 380)
        .background(HelmSurface.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(HelmSurface.line)
                .frame(width: 1)
        }
        .onAppear {
            syncDraftIfNeeded(force: true)
        }
        .onChange(of: store.selectedAgent?.id) { _, _ in
            syncDraftIfNeeded(force: true)
        }
    }

    private func syncDraftIfNeeded(force: Bool) {
        guard let agent = store.selectedAgent else {
            draftAgentID = nil
            return
        }
        if force || draftAgentID != agent.id {
            draftAgentID = agent.id
            draftGoal = agent.goal
            draftPersonality = agent.personality
            draftSystemPrompt = agent.systemPrompt
            draftBackend = agent.backend
            saveError = nil
            justSaved = false
        }
    }

    private func hasUnsavedChanges(for agent: AgentProfile) -> Bool {
        draftAgentID == agent.id && (
            draftGoal.trimmingCharacters(in: .whitespacesAndNewlines) != agent.goal ||
            draftPersonality != agent.personality ||
            draftSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) != agent.systemPrompt ||
            draftBackend != agent.backend
        )
    }

    // MARK: - Tab 1: Selected Agent & Editable System Prompt

    @ViewBuilder
    private var agentTabContent: some View {
        if let agent = store.selectedAgent {
            let dirty = hasUnsavedChanges(for: agent)

            VStack(spacing: 14) {
                // Hero living character stage
                VStack(spacing: 10) {
                    AgentCharacterCanvas(
                        seed: agent.characterSeed,
                        state: agent.activityState,
                        size: 68,
                        showStageBacking: true,
                        interactive: true
                    )

                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(HelmInk.primary)
                            if agent.role == .orchestrator {
                                Text("Lead")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(HelmAccent.brass)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(HelmAccent.brassSoft, in: Capsule())
                            }
                        }
                        Text("\(agent.role.displayName) · \(draftBackend.displayName)")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                    }

                    HStack(spacing: 8) {
                        AgentStatusBadge(state: agent.activityState)

                        Button {
                            store.selectAgent(agent.id, openDirectChat: true, openInspector: false)
                        } label: {
                            Label("1-on-1 Chat", systemImage: "bubble.left.fill")
                                .font(.caption.weight(.medium))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .helmCard(cornerRadius: HelmRadius.card)

                // Engine, Personality & Full Editable System Prompt
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("AI Engine", systemImage: "cpu")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                        Spacer()
                        Picker("AI Engine", selection: $draftBackend) {
                            ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    Divider().overlay(HelmSurface.line)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Personality", systemImage: draftPersonality.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                            Spacer()
                            Picker("Personality", selection: $draftPersonality) {
                                ForEach(AgentPersonality.allCases, id: \.self) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        }

                        Text(draftPersonality.tagline)
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(HelmSurface.line)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Role Summary")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                        TextField("Brief responsibility summary…", text: $draftGoal, axis: .vertical)
                            .font(.caption)
                            .lineLimit(2...3)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider().overlay(HelmSurface.line)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Text("System Prompt")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                            Spacer()
                            Button {
                                draftSystemPrompt = AgentProfile.buildSystemPromptTemplate(
                                    role: agent.role,
                                    personality: draftPersonality,
                                    goal: draftGoal,
                                    notes: ""
                                )
                                justSaved = false
                            } label: {
                                Label("Apply Preset Template", systemImage: "wand.and.stars")
                                    .font(.caption2.weight(.semibold))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(HelmSecondaryButtonStyle())
                            .help("Populate a template from the selected personality without locking edits")
                        }

                        TextEditor(text: $draftSystemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 170, maxHeight: 260)
                            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                                    .strokeBorder(HelmSurface.line, lineWidth: 1)
                            )

                        Text("Edits apply directly to future turns. Changing Personality above never overwrites your prompt unless you click Apply Preset Template.")
                            .font(.system(size: 10))
                            .foregroundStyle(HelmInk.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .helmCard(cornerRadius: HelmRadius.panel)

                // Save bar when edited
                if dirty || justSaved || saveError != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let saveError {
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(HelmSemantic.critical)
                        }
                        HStack(spacing: 8) {
                            if dirty {
                                Button("Reset") {
                                    syncDraftIfNeeded(force: true)
                                }
                                .buttonStyle(HelmSecondaryButtonStyle())

                                Button {
                                    saveAgentChanges(agent)
                                } label: {
                                    Text(isSaving ? "Saving…" : "Save Changes")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(HelmPrimaryButtonStyle())
                                .disabled(isSaving)
                            } else if justSaved {
                                Label("Saved to workspace", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(HelmSemantic.steady)
                                Spacer()
                            }
                        }
                    }
                }

                // Simplified Project-Level Workspace & Tool Access
                if let project = store.selectedProject {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Workspace & Tool Access", systemImage: "folder.badge.gearshape")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.primary)
                            Spacer()
                        }

                        Picker(
                            "Sandbox Policy",
                            selection: Binding(
                                get: { project.sandboxTrustPolicy },
                                set: { newPolicy in
                                    Task {
                                        do {
                                            try await store.updateProjectTrustPolicy(newPolicy, projectID: project.id)
                                        } catch {
                                            saveError = error.localizedDescription
                                        }
                                    }
                                }
                            )
                        ) {
                            ForEach(SandboxTrustPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(project.sandboxTrustPolicy.summary)
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Agents operate directly against \(project.workspaceRoot.lastPathComponent) with their role tools under this project-level trust policy.")
                            .font(.system(size: 10))
                            .foregroundStyle(HelmInk.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .helmCard(cornerRadius: HelmRadius.panel)
                }

                // Private Memory
                if !store.selectedAgentPrivateMemory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Private Notes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)

                        ForEach(store.selectedAgentPrivateMemory.prefix(5)) { mem in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mem.title.isEmpty ? mem.key : mem.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(HelmInk.primary)
                                Text(mem.content)
                                    .font(.caption)
                                    .foregroundStyle(HelmInk.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .helmCard(cornerRadius: HelmRadius.panel)
                }
            }
        } else {
            VStack(spacing: 10) {
                Text("Select an agent")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text("Click the slider button on any crew card to edit its system prompt, personality, AI engine, and project trust policy.")
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private func saveAgentChanges(_ agent: AgentProfile) {
        let trimmedGoal = draftGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = draftSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            saveError = "Role summary cannot be empty."
            return
        }
        guard !trimmedPrompt.isEmpty else {
            saveError = "System prompt cannot be empty."
            return
        }

        isSaving = true
        saveError = nil
        Task {
            do {
                try await store.updateAgent(
                    agentID: agent.id,
                    goal: trimmedGoal,
                    backend: draftBackend,
                    personality: draftPersonality,
                    systemPrompt: trimmedPrompt
                )
                isSaving = false
                justSaved = true
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }

    // MARK: - Tab 2: Live Agent Work & Sandbox / Browser Diagnostics

    private var activityTabContent: some View {
        let exec = store.selectedLatestExecutionResult
        let obs = store.selectedLatestBrowserObservation
        let artifacts = Array(store.selectedProjectArtifacts.suffix(5).reversed())
        let agentEntries: [AgentWorkEntry] = {
            if let project = store.selectedProject {
                let scoped = store.workFeed(forProject: project.id, agentID: store.selectedAgent?.id)
                let source = scoped.isEmpty ? store.workFeed(forProject: project.id, agentID: nil) : scoped
                return Array(source.suffix(6).reversed())
            }
            return []
        }()

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recent Agent Work", systemImage: "bolt.horizontal.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Spacer()
                    if let agent = store.selectedAgent {
                        MetadataTag(agent.name)
                    }
                }

                if agentEntries.isEmpty {
                    Text("No live steps recorded yet. Steps, tool calls, and touched files will appear here as agents run.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.muted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .helmCard(cornerRadius: HelmRadius.panel)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(agentEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(entry.agentName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(HelmInk.primary)
                                    MetadataTag("Step \(entry.stepNumber)", monospaced: true)
                                    Spacer()
                                    Text(entry.createdAt, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(HelmInk.muted)
                                }
                                Text(entry.summary)
                                    .font(.caption)
                                    .foregroundStyle(HelmInk.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let toolName = entry.toolName, !toolName.isEmpty {
                                    Text("\(toolName): \(entry.toolOutputSummary ?? entry.toolInputSummary ?? "")")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(HelmInk.muted)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Sandbox Output", systemImage: "terminal")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Spacer()
                    MetadataTag(
                        exec?.modeUsed == .virtualizationVM ? "Apple VM" : (store.virtualizationAvailable ? "VM Ready" : "Sandbox")
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let exec {
                        HStack(spacing: 8) {
                            Text(exec.exitCode == 0 ? "Succeeded" : "Exit \(exec.exitCode)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(exec.exitCode == 0 ? HelmSemantic.steady : HelmSemantic.critical)
                            Spacer()
                            Text(String(format: "%.0f ms", exec.durationMs))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(HelmInk.muted)
                        }
                        Text(exec.stdout.isEmpty ? (exec.stderr.isEmpty ? "(no output)" : exec.stderr) : exec.stdout)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HelmInk.primary)
                            .lineSpacing(2)
                            .lineLimit(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("No code has run in this project yet. Sandbox output streams here automatically when a coder agent executes.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                        .strokeBorder(HelmSurface.line, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Browser & Vision OCR", systemImage: "globe")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Spacer()
                    if let obs {
                        TrustLevelBadge(trustLevel: obs.trustTag)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let obs {
                        HStack(spacing: 6) {
                            Text(obs.url)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f ms", obs.latencyMs))
                                .font(.system(size: 10, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(HelmInk.muted)
                        }

                        if obs.ocrLines.isEmpty {
                            Text("No readable text detected in viewport.")
                                .font(.caption)
                                .foregroundStyle(HelmInk.muted)
                        } else {
                            ForEach(Array(obs.ocrLines.prefix(5).enumerated()), id: \.offset) { _, line in
                                HStack(spacing: 6) {
                                    Text(line.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(HelmInk.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.0f%%", line.confidence * 100))
                                        .font(.system(size: 10, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(HelmInk.muted)
                                }
                            }
                        }
                    } else {
                        Text("No web pages visited yet. Live Vision OCR reads appear here automatically when a browser agent navigates.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                        .strokeBorder(HelmSurface.line, lineWidth: 1)
                )
            }

            if !artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Captured Artifacts", systemImage: "doc.on.doc")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(artifacts) { art in
                            HStack(spacing: 6) {
                                Text(art.relativePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(HelmInk.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(art.byteSize) B")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(HelmInk.muted)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .helmCard(cornerRadius: HelmRadius.panel)
                }
            }
        }
    }

    // MARK: - Tab 3: Human-Readable Timeline

    private var timelineTabContent: some View {
        let events = Array(store.selectedProjectEvents.suffix(20).reversed())

        return VStack(alignment: .leading, spacing: 10) {
            if events.isEmpty {
                Text("No activity recorded yet. Start the watch or send a message in chat to see milestones here.")
                    .font(.caption)
                    .foregroundStyle(HelmInk.muted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .helmCard(cornerRadius: HelmRadius.panel)
            } else {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(eventColor(event.kind))
                                .frame(width: 6, height: 6)
                            Text(friendlyEventLabel(event.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(eventColor(event.kind))
                            Spacer()
                            Text(event.createdAt, format: .dateTime.hour().minute().second())
                                .font(.system(size: 10, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(HelmInk.muted)
                        }
                        Text(event.summary.replacingOccurrences(of: "STEADY_OK: ", with: ""))
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .helmCard(cornerRadius: HelmRadius.panel)
                }
            }
        }
    }

    private func friendlyEventLabel(_ kind: RunEventKind) -> String {
        switch kind {
        case .projectCreated: return "Project Created"
        case .projectStarted: return "Watch Started"
        case .projectPaused: return "Watch Paused"
        case .projectHeld: return "Paused for Review"
        case .projectCompleted: return "Project Completed"
        case .agentAdded: return "Agent Joined"
        case .agentStateChanged: return "Agent Updated"
        case .taskCreated: return "Task Created"
        case .taskDelegated: return "Task Delegated"
        case .taskCompleted: return "Task Completed"
        case .taskSelfCorrected: return "Self-Corrected"
        case .taskFailed: return "Task Failed"
        case .toolExecuted: return "Tool Run"
        case .sharedStateWritten: return "Memory Updated"
        case .sharedStateRejected: return "Memory Guard"
        case .heartbeatSteadyOK: return "Quiet Check-In"
        case .exceptionRaised: return "Alert Surfaced"
        case .exceptionResolved: return "Alert Resolved"
        case .recoveryReconciled: return "Recovered"
        }
    }

    private func eventColor(_ kind: RunEventKind) -> Color {
        switch kind {
        case .exceptionRaised, .projectHeld, .sharedStateRejected, .taskFailed:
            return HelmSemantic.attention
        case .exceptionResolved, .projectCompleted, .taskCompleted, .heartbeatSteadyOK:
            return HelmSemantic.steady
        default:
            return HelmInk.primary
        }
    }
}
