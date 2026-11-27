import HelmCore
import SwiftUI

public struct ExceptionBannerView: View {
    public let alert: ExceptionAlert
    public let offendingAgent: AgentProfile?
    public let onResolve: (ExceptionResolution) -> Void
    public let onInspectAgent: ((UUID) -> Void)?

    @State private var redirectNote: String = ""
    @State private var isRedirectExpanded: Bool = false

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

    public var body: some View {
        VStack(alignment: .leading, spacing: HelmSpace.l) {
            HStack(alignment: .top, spacing: HelmSpace.l) {
                if let agent = offendingAgent {
                    AgentCharacterCanvas(seed: agent.characterSeed, state: .exception, size: 32)
                } else {
                    Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    HStack(spacing: HelmSpace.m) {
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
                        .font(.headline)
                        .foregroundStyle(HelmInk.primary)

                    Text(alert.diagnosticSummary)
                        .font(.body)
                        .foregroundStyle(HelmInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

            HStack(spacing: HelmSpace.m) {
                Button("Approve") {
                    onResolve(.approve)
                }
                .buttonStyle(HelmPrimaryButtonStyle())

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
                    .foregroundStyle(HelmAccent.primary)
                }
            }
        }
        .padding(HelmSpace.xl)
        .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                .strokeBorder(accentColor.opacity(0.42), lineWidth: 1.0)
        )
    }

    private func kindLabel(_ kind: ExceptionKind) -> String {
        switch kind {
        case .stall: return "Agent Stalled"
        case .loop: return "Loop Detected"
        case .drift: return "Goal Drift"
        case .budget: return "Budget Hold"
        case .humanDecision: return "Human Decision"
        case .coordinatorStalled: return "Watchdog Hold"
        case .providerFailure: return "Provider Fault"
        }
    }
}
