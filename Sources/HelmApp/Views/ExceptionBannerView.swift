import HelmCore
import SwiftUI

public struct ExceptionBannerView: View {
    public let alert: ExceptionAlert
    public let offendingAgent: AgentProfile?
    public let onResolve: (ExceptionResolution) -> Void
    public let onInspectAgent: ((UUID) -> Void)?

    @State private var redirectNote: String = ""
    @State private var isRedirectExpanded: Bool = false
    @State private var showFullDetail: Bool = false

    public init(
        alert: ExceptionAlert,
        offendingAgent: AgentProfile?,
        onResolve: @escaping (ExceptionResolution) -> Void,
        onInspectAgent: ((UUID) -> Void)? = nil
    ) {
        self.alert = alert
        self.offendingAgent = offendingAgent
        self.onResolve = onResolve
        self.onInspectAgent = onInspectAgent
    }

    private var accentColor: Color {
        alert.severity == .critical ? HelmSemantic.critical : HelmSemantic.attention
    }

    private var softBackground: Color {
        alert.severity == .critical ? HelmSemantic.criticalSoft : HelmSemantic.attentionSoft
    }

    private var allowsApprove: Bool {
        alert.suggestedOptions.isEmpty || alert.suggestedOptions.contains("approve")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HelmSpace.m) {
            HStack(alignment: .top, spacing: HelmSpace.m) {
                if let agent = offendingAgent {
                    AgentCharacterCanvas(seed: agent.characterSeed, state: .exception, size: 28)
                } else {
                    Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(accentColor)
                        .frame(width: 28, height: 28)
                }

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    HStack(spacing: HelmSpace.s) {
                        StatusPill(
                            label: kindLabel(alert.kind),
                            symbol: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                            color: accentColor,
                            background: softBackground
                        )

                        if let agent = offendingAgent {
                            MetadataTag(agent.name)
                        }

                        Spacer(minLength: 0)

                        Text(alert.createdAt, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(HelmInk.muted)
                    }

                    Text(alert.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(2)

                    Text(alert.diagnosticSummary)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(showFullDetail ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)

                    if alert.diagnosticSummary.count > 120 {
                        Button(showFullDetail ? "Show less" : "Show more") {
                            showFullDetail.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(HelmAccent.primary)
                    }
                }
            }

            if isRedirectExpanded {
                HStack(spacing: HelmSpace.m) {
                    TextField("Enter course correction or guidance for the Orchestrator…", text: $redirectNote)
                        .textFieldStyle(.roundedBorder)
                    Button("Send Redirect") {
                        let note = redirectNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        onResolve(.redirect(note: note.isEmpty ? "Proceed with adjusted approach" : note))
                        redirectNote = ""
                        isRedirectExpanded = false
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }
            }

            HStack(spacing: HelmSpace.s) {
                if allowsApprove {
                    Button("Approve") {
                        onResolve(.approve)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }

                Button("Retry") {
                    onResolve(.retry)
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Button(isRedirectExpanded ? "Cancel Redirect" : "Redirect") {
                    withAnimation(HelmMotion.micro) {
                        isRedirectExpanded.toggle()
                    }
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Button("Abort", role: .destructive) {
                    onResolve(.abort)
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Spacer(minLength: 0)

                if let agentID = alert.agentID, let onInspectAgent {
                    Button("Inspect") {
                        onInspectAgent(agentID)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HelmAccent.primary)
                }
            }
        }
        .padding(HelmSpace.l)
        .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                .strokeBorder(accentColor.opacity(0.42), lineWidth: 1.0)
        )
    }

    private func kindLabel(_ kind: ExceptionKind) -> String {
        switch kind {
        case .stall: return "Agent Stalled"
        case .loop: return "Loop Detected"
        case .drift: return "Boundary Drift"
        case .budget: return "Budget Hold"
        case .humanDecision: return "Approval Gate"
        case .coordinatorStalled: return "Watchdog Hold"
        case .providerFailure: return "Provider Fault"
        }
    }
}
