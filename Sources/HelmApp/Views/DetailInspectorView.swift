import HelmCore
import SwiftUI

public struct DetailInspectorView: View {
    @Bindable var store: HelmWorkspaceStore

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HelmSpace.xl) {
                // 1. Selected Agent Header & Private Memory
                if let agent = store.selectedAgent {
                    selectedAgentSection(agent)
                }

                // 2. Sandbox / VM Execution Output Well
                sandboxExecutionSection

                // 3. Headless Browser + Native Vision OCR Preview
                browserOCRSection

                // 4. Run Events Audit Stream
                runEventsSection
            }
            .padding(HelmSpace.xl)
        }
        .frame(width: 320)
        .background(HelmSurface.canvas)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(HelmSurface.line)
                .frame(width: 1)
        }
    }

    // MARK: - Selected Agent

    private func selectedAgentSection(_ agent: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: HelmSpace.m) {
            Text("Agent Inspector")
                .font(.headline)
                .foregroundStyle(HelmInk.primary)

            VStack(alignment: .leading, spacing: HelmSpace.l) {
                HStack(spacing: HelmSpace.l) {
                    AgentCharacterCanvas(seed: agent.characterSeed, state: agent.activityState, size: 36)

                    VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                        Text(agent.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                            .lineLimit(1)
                        Text("\(agent.role.displayName) · \(agent.backend.displayName)")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text(agent.goal)
                    .font(.callout)
                    .foregroundStyle(HelmInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Capabilities
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: HelmSpace.xs)], alignment: .leading, spacing: HelmSpace.xs) {
                    ForEach(Array(agent.capabilities).sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { cap in
                        MetadataTag(cap.displayName)
                    }
                }

                // Private Memory Entries
                if !store.selectedAgentPrivateMemory.isEmpty {
                    Divider().overlay(HelmSurface.line)
                    Text("Private Memory")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)

                    ForEach(store.selectedAgentPrivateMemory.prefix(4)) { mem in
                        VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                            Text(mem.key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(HelmInk.primary)
                            Text(mem.content)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(HelmSpace.l)
            .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )
        }
    }

    // MARK: - Sandbox / VM Output Well

    private var sandboxExecutionSection: some View {
        let exec = store.selectedLatestExecutionResult
        let taskOutputs = Array(
            store.selectedProjectTasks
                .filter {
                    ($0.resultSummary?.isEmpty == false)
                        || ($0.errorSummary?.isEmpty == false)
                        || !$0.artifactPaths.isEmpty
                }
                .suffix(3)
                .reversed()
        )
        let artifacts = Array(store.selectedProjectArtifacts.suffix(4).reversed())

        return VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack {
                Text("Isolated Sandbox")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                MetadataTag(
                    exec?.modeUsed == .virtualizationVM ? "VZ Micro-VM" : (exec != nil ? "Seatbelt" : (store.virtualizationAvailable ? "VZ Ready" : "Seatbelt"))
                )
            }

            VStack(alignment: .leading, spacing: HelmSpace.m) {
                if let exec {
                    HStack(spacing: HelmSpace.m) {
                        Text("exit \(exec.exitCode)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(exec.exitCode == 0 ? HelmSemantic.steady : HelmSemantic.critical)
                        Text(String(format: "%.0f ms", exec.durationMs))
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(HelmInk.muted)
                        Spacer()
                    }
                    Text(exec.stdout.isEmpty ? (exec.stderr.isEmpty ? "(no output)" : exec.stderr) : exec.stdout)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.primary)
                        .lineSpacing(2)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !taskOutputs.isEmpty || !artifacts.isEmpty {
                    ForEach(taskOutputs) { task in
                        VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                            Text(task.title)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            if let summary = task.errorSummary ?? task.resultSummary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(task.errorSummary != nil ? HelmSemantic.critical : HelmInk.secondary)
                                    .lineLimit(3)
                            }
                            if !task.artifactPaths.isEmpty {
                                Text(task.artifactPaths.joined(separator: ", "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(HelmInk.muted)
                                    .lineLimit(2)
                            }
                        }
                    }

                    if !artifacts.isEmpty {
                        if !taskOutputs.isEmpty {
                            Divider().overlay(HelmSurface.line)
                        }
                        ForEach(artifacts) { artifact in
                            HStack(spacing: HelmSpace.s) {
                                Text(artifact.relativePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(HelmInk.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(artifact.kind) · \(artifact.byteSize) B")
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(HelmInk.muted)
                            }
                        }
                    }
                } else {
                    Text("Awaiting isolated code execution. Headless commands stream stdout/stderr here without touching host focus.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.secondary)
                        .lineSpacing(2)
                }
            }
            .padding(HelmSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )

            Button("Run Sandbox Check") {
                Task {
                    await store.runQuickSandboxCheck(command: "pwd && echo helm-sandbox-ok")
                }
            }
            .buttonStyle(HelmSecondaryButtonStyle())
            .disabled(store.isRunningDiagnostic || store.selectedProject == nil)
        }
    }

    // MARK: - Browser + Native Vision OCR Preview

    private var browserOCRSection: some View {
        let obs = store.selectedLatestBrowserObservation
        let webObservations = Array(
            store.selectedProjectSharedState
                .filter { $0.category == .observation }
                .suffix(3)
                .reversed()
        )
        let browserArtifacts = Array(
            store.selectedProjectArtifacts
                .filter {
                    let lowerKind = $0.kind.lowercased()
                    let lowerPath = $0.relativePath.lowercased()
                    return lowerKind.contains("browser") || lowerKind.contains("ocr") || lowerKind.contains("screenshot") || lowerPath.hasSuffix(".png")
                }
                .suffix(3)
                .reversed()
        )

        return VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack {
                Text("Headless Browser & OCR")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                if let obs {
                    TrustLevelBadge(trustLevel: obs.trustTag)
                } else if !webObservations.isEmpty {
                    TrustLevelBadge(trustLevel: webObservations[0].trustLevel)
                }
            }

            VStack(alignment: .leading, spacing: HelmSpace.m) {
                if let obs {
                    HStack(spacing: HelmSpace.s) {
                        Text(obs.url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HelmInk.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f ms", obs.latencyMs))
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(HelmInk.muted)
                    }

                    if obs.ocrLines.isEmpty {
                        Text("No OCR text recognized in viewport.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HelmInk.muted)
                    } else {
                        ForEach(Array(obs.ocrLines.prefix(5).enumerated()), id: \.offset) { _, line in
                            HStack(spacing: HelmSpace.s) {
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
                } else if !webObservations.isEmpty || !browserArtifacts.isEmpty {
                    ForEach(webObservations, id: \.id) { item in
                        VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                            Text(item.key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            Text(item.content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HelmInk.secondary)
                                .lineLimit(3)
                        }
                    }
                    ForEach(browserArtifacts) { artifact in
                        HStack(spacing: HelmSpace.s) {
                            Text(artifact.relativePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HelmInk.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(artifact.kind)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(HelmInk.muted)
                        }
                    }
                } else {
                    Text("No active browser frame captured. Vision OCR lines and DOM element refs appear here.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.secondary)
                        .lineSpacing(2)
                }
            }
            .padding(HelmSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )

            Button("Run Browser Check") {
                Task {
                    await store.runQuickBrowserCheck(
                        url: "data:text/html,<html><body><h1>HELM%20BROWSER%20OK</h1></body></html>"
                    )
                }
            }
            .buttonStyle(HelmSecondaryButtonStyle())
            .disabled(store.isRunningDiagnostic || store.selectedProject == nil)
        }
    }

    // MARK: - Run Events Audit Stream

    private var runEventsSection: some View {
        let events = Array(store.selectedProjectEvents.suffix(12).reversed())

        return VStack(alignment: .leading, spacing: HelmSpace.s) {
            HStack {
                Text("Run Audit Stream")
                    .font(.headline)
                    .foregroundStyle(HelmInk.primary)
                Spacer()
                Text("\(store.selectedProjectEvents.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HelmInk.secondary)
            }

            VStack(alignment: .leading, spacing: HelmSpace.s) {
                if events.isEmpty {
                    Text("No events recorded yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.muted)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: HelmSpace.s) {
                                Text(event.createdAt, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(HelmInk.muted)
                                Text(event.kind.rawValue)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(eventColor(event.kind))
                            }
                            Text(event.summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HelmInk.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(HelmSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 1.0)
            )
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
