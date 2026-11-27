import HelmCore
import SwiftUI

public struct DetailInspectorView: View {
    @Bindable var store: HelmWorkspaceStore

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Clean inspector header with segmented tabs + close button
            HStack(spacing: 8) {
                Picker("", selection: $store.inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    withAnimation(HelmMotion.state) {
                        store.isInspectorVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HelmInk.muted)
                        .frame(width: 24, height: 24)
                        .background(HelmSurface.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Hide Inspector (⌥⌘I)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(HelmSurface.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch store.inspectorTab {
                    case .agent:
                        agentTabContent
                    case .activity:
                        activityTabContent
                    case .timeline:
                        timelineTabContent
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .background(HelmSurface.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(HelmSurface.line)
                .frame(width: 1)
        }
    }

    // MARK: - Tab 1: Selected Agent Showcase

    @ViewBuilder
    private var agentTabContent: some View {
        if let agent = store.selectedAgent {
            VStack(spacing: 14) {
                // Hero living character stage
                VStack(spacing: 12) {
                    AgentCharacterCanvas(
                        seed: agent.characterSeed,
                        state: agent.activityState,
                        size: 76,
                        showStageBacking: true,
                        interactive: true
                    )

                    VStack(spacing: 4) {
                        Text(agent.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(HelmInk.primary)
                        Text("\(agent.role.displayName) · \(agent.backend.displayName)")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                    }

                    AgentStatusBadge(state: agent.activityState)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 14)
                .helmCard(cornerRadius: HelmRadius.card)

                // Mission & Capabilities
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mission")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)

                    Text(agent.goal)
                        .font(.callout)
                        .foregroundStyle(HelmInk.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(HelmSurface.line)

                    Text("Permissions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(Array(agent.capabilities).sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { cap in
                            MetadataTag(cap.displayName)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .helmCard(cornerRadius: HelmRadius.panel)

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
                Text("Click any bot card on the workspace stage to inspect its mission, permissions, and private notes.")
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - Tab 2: Live Sandbox & Headless Browser Output (Zero Debug Buttons)

    private var activityTabContent: some View {
        let exec = store.selectedLatestExecutionResult
        let obs = store.selectedLatestBrowserObservation
        let artifacts = Array(store.selectedProjectArtifacts.suffix(5).reversed())

        return VStack(alignment: .leading, spacing: 16) {
            // Isolated Execution
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

            // Headless Browser + Vision OCR
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
                Text("No activity recorded yet. Start the watch to see milestones and task completions here.")
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
        case .projectHeld: return "Needs Decision"
        case .projectCompleted: return "Project Completed"
        case .agentAdded: return "Agent Joined"
        case .agentStateChanged: return "Status Update"
        case .taskCreated: return "Task Created"
        case .taskDelegated: return "Task Delegated"
        case .taskCompleted: return "Task Completed"
        case .taskSelfCorrected: return "Self-Corrected"
        case .taskFailed: return "Task Failed"
        case .toolExecuted: return "Tool Run"
        case .sharedStateWritten: return "Memory Updated"
        case .sharedStateRejected: return "Memory Guard"
        case .heartbeatSteadyOK: return "Quiet Check-In"
        case .exceptionRaised: return "Exception Surfaced"
        case .exceptionResolved: return "Exception Resolved"
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
