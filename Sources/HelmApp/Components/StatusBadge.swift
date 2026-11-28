import HelmCore
import SwiftUI

// MARK: - Semantic Status Badge (Always Color + Symbol + Label)

public struct StatusPill: View {
    public let label: String
    public let symbol: String
    public let color: Color
    public let background: Color

    public init(label: String, symbol: String, color: Color, background: Color) {
        self.label = label
        self.symbol = symbol
        self.color = color
        self.background = background
    }

    public var body: some View {
        HStack(spacing: HelmSpace.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, HelmSpace.s)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.22), lineWidth: 0.75)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

public struct AgentStatusBadge: View {
    public let state: AgentActivityState

    public init(state: AgentActivityState) {
        self.state = state
    }

    public var body: some View {
        StatusPill(label: label, symbol: symbol, color: color, background: background)
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .thinking: return "Reasoning"
        case .browsing: return "Browsing"
        case .executing: return "Running Code"
        case .waiting: return "Waiting"
        case .exception: return "Needs Attention"
        case .paused: return "Paused"
        case .completed: return "Completed"
        }
    }

    private var symbol: String {
        switch state {
        case .idle: return "circle"
        case .thinking: return "brain.head.profile"
        case .browsing: return "globe"
        case .executing: return "terminal"
        case .waiting: return "clock"
        case .exception: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .idle, .waiting, .paused: return HelmSemantic.idle
        case .thinking: return HelmSemantic.thinking
        case .browsing: return HelmSemantic.browsing
        case .executing: return HelmSemantic.executing
        case .exception: return HelmSemantic.attention
        case .completed: return HelmSemantic.steady
        }
    }

    private var background: Color {
        switch state {
        case .idle, .waiting, .paused: return HelmSemantic.idleSoft
        case .thinking: return HelmSemantic.thinkingSoft
        case .browsing: return HelmSemantic.browsingSoft
        case .executing: return HelmSemantic.executingSoft
        case .exception: return HelmSemantic.attentionSoft
        case .completed: return HelmSemantic.steadySoft
        }
    }
}

public struct ProjectStatusBadge: View {
    public let status: ProjectStatus

    public init(status: ProjectStatus) {
        self.status = status
    }

    public var body: some View {
        StatusPill(label: label, symbol: symbol, color: color, background: background)
    }

    private var label: String {
        switch status {
        case .idle: return "Ready"
        case .running: return "Running"
        case .paused: return "Paused"
        case .held: return "Attention"
        case .completed: return "Completed"
        case .failed: return "Fault"
        }
    }

    private var symbol: String {
        switch status {
        case .idle: return "circle"
        case .running: return "circle.fill"
        case .paused: return "pause.circle"
        case .held: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch status {
        case .idle, .paused: return HelmSemantic.idle
        case .running, .completed: return HelmSemantic.steady
        case .held: return HelmSemantic.attention
        case .failed: return HelmSemantic.critical
        }
    }

    private var background: Color {
        switch status {
        case .idle, .paused: return HelmSemantic.idleSoft
        case .running, .completed: return HelmSemantic.steadySoft
        case .held: return HelmSemantic.attentionSoft
        case .failed: return HelmSemantic.criticalSoft
        }
    }
}

public struct TaskStatusBadge: View {
    public let status: TaskStatus

    public init(status: TaskStatus) {
        self.status = status
    }

    public var body: some View {
        StatusPill(label: label, symbol: symbol, color: color, background: background)
    }

    private var label: String {
        switch status {
        case .queued: return "Queued"
        case .running: return "Active"
        case .blocked: return "Blocked"
        case .needsHuman: return "Needs Human"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .outcomeUnknown: return "Outcome Unknown"
        }
    }

    private var symbol: String {
        switch status {
        case .queued: return "circle.dotted"
        case .running: return "play.circle.fill"
        case .blocked: return "link"
        case .needsHuman: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .outcomeUnknown: return "questionmark.diamond.fill"
        }
    }

    private var color: Color {
        switch status {
        case .queued, .cancelled: return HelmSemantic.idle
        case .running: return HelmSemantic.thinking
        case .blocked, .needsHuman, .outcomeUnknown: return HelmSemantic.attention
        case .done: return HelmSemantic.steady
        case .failed: return HelmSemantic.critical
        }
    }

    private var background: Color {
        switch status {
        case .queued, .cancelled: return HelmSemantic.idleSoft
        case .running: return HelmSemantic.thinkingSoft
        case .blocked, .needsHuman, .outcomeUnknown: return HelmSemantic.attentionSoft
        case .done: return HelmSemantic.steadySoft
        case .failed: return HelmSemantic.criticalSoft
        }
    }
}

public struct TrustLevelBadge: View {
    public let trustLevel: TrustLevel

    public init(trustLevel: TrustLevel) {
        self.trustLevel = trustLevel
    }

    public var body: some View {
        StatusPill(label: label, symbol: symbol, color: color, background: background)
    }

    private var label: String {
        switch trustLevel {
        case .humanAuthoritative: return "Owner Rule"
        case .orchestratorVerified: return "Verified"
        case .agentGenerated: return "Agent Note"
        case .untrustedData: return "Untrusted Web"
        }
    }

    private var symbol: String {
        switch trustLevel {
        case .humanAuthoritative: return "checkmark.seal.fill"
        case .orchestratorVerified: return "shield.checkered"
        case .agentGenerated: return "doc.text"
        case .untrustedData: return "exclamationmark.shield.fill"
        }
    }

    private var color: Color {
        switch trustLevel {
        case .humanAuthoritative: return HelmAccent.brass
        case .orchestratorVerified: return HelmSemantic.steady
        case .agentGenerated: return HelmSemantic.thinking
        case .untrustedData: return HelmSemantic.attention
        }
    }

    private var background: Color {
        switch trustLevel {
        case .humanAuthoritative: return HelmAccent.brassSoft
        case .orchestratorVerified: return HelmSemantic.steadySoft
        case .agentGenerated: return HelmSemantic.thinkingSoft
        case .untrustedData: return HelmSemantic.attentionSoft
        }
    }
}

public struct MetadataTag: View {
    public let text: String
    public var monospaced: Bool = false

    public init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }

    public var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 11, weight: .medium, design: .monospaced) : .caption.weight(.medium))
            .foregroundStyle(HelmInk.secondary)
            .padding(.horizontal, HelmSpace.s)
            .padding(.vertical, 2)
            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.badge, style: .continuous)
                    .strokeBorder(HelmSurface.line, lineWidth: 0.75)
            )
    }
}
