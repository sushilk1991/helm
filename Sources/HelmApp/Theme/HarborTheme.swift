import AppKit
import HelmCore
import SwiftUI

// MARK: - Dynamic Color Helper

private extension Color {
    static func adaptive(lightHex: UInt32, darkHex: UInt32, lightAlpha: CGFloat = 1.0, darkAlpha: CGFloat = 1.0) -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? darkHex : lightHex
            let alpha = isDark ? darkAlpha : lightAlpha
            let r = CGFloat((hex >> 16) & 0xFF) / 255.0
            let g = CGFloat((hex >> 8) & 0xFF) / 255.0
            let b = CGFloat(hex & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
        return Color(nsColor: nsColor)
    }
}

// MARK: - Surfaces (Warm Obsidian Dark / Refined Alabaster Light)

public enum HelmSurface {
    public static let canvas = Color.adaptive(lightHex: 0xF6F6F3, darkHex: 0x0F1115)
    public static let sidebar = Color.adaptive(lightHex: 0xEFEFEA, darkHex: 0x13161C)
    public static let elevated = Color.adaptive(lightHex: 0xFFFFFF, darkHex: 0x181C24)
    public static let elevatedHover = Color.adaptive(lightHex: 0xFCFCFA, darkHex: 0x1E232D)
    public static let well = Color.adaptive(lightHex: 0xF0F0EB, darkHex: 0x0C0E12)
    public static let line = Color.adaptive(lightHex: 0x121826, darkHex: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.07)
    public static let lineStrong = Color.adaptive(lightHex: 0x121826, darkHex: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.14)
    public static let specularTop = Color.adaptive(lightHex: 0xFFFFFF, darkHex: 0xFFFFFF, lightAlpha: 0.80, darkAlpha: 0.06)
    public static let hoverWash = Color.adaptive(lightHex: 0x1D2430, darkHex: 0xF2F4F7, lightAlpha: 0.04, darkAlpha: 0.05)
    public static let selectedWash = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x5B8DEF, lightAlpha: 0.09, darkAlpha: 0.14)
    public static let cardShadow = Color.adaptive(lightHex: 0x0F172A, darkHex: 0x000000, lightAlpha: 0.06, darkAlpha: 0.35)
}

// MARK: - Typography Ink

public enum HelmInk {
    public static let primary = Color.adaptive(lightHex: 0x161B26, darkHex: 0xF3F5F8)
    public static let secondary = Color.adaptive(lightHex: 0x526072, darkHex: 0x99A5B8)
    public static let muted = Color.adaptive(lightHex: 0x7A8699, darkHex: 0x677386)
}

// MARK: - Brand Accents

public enum HelmAccent {
    public static let primary = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x5B8DEF)
    public static let primarySoft = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x5B8DEF, lightAlpha: 0.11, darkAlpha: 0.16)
    public static let brass = Color.adaptive(lightHex: 0x9A6B11, darkHex: 0xE2B55A)
    public static let brassSoft = Color.adaptive(lightHex: 0x9A6B11, darkHex: 0xE2B55A, lightAlpha: 0.11, darkAlpha: 0.16)
    public static let iconDarkTop = Color.adaptive(lightHex: 0x16202C, darkHex: 0x16202C)
    public static let iconDarkBottom = Color.adaptive(lightHex: 0x0D131B, darkHex: 0x0D131B)
    public static let iconIvory = Color.adaptive(lightHex: 0xF4F1EA, darkHex: 0xF4F1EA)
    public static let iconBrass = Color.adaptive(lightHex: 0xD4A64A, darkHex: 0xD4A64A)
    public static let iconRim = Color.adaptive(lightHex: 0xFFFFFF, darkHex: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.12)
}

// MARK: - Semantic State Tokens (always paired with symbol + label)

public enum HelmSemantic {
    public static let steady = Color.adaptive(lightHex: 0x168052, darkHex: 0x34D399)
    public static let steadySoft = Color.adaptive(lightHex: 0x168052, darkHex: 0x34D399, lightAlpha: 0.11, darkAlpha: 0.15)

    public static let thinking = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x60A5FA)
    public static let thinkingSoft = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x60A5FA, lightAlpha: 0.11, darkAlpha: 0.15)

    public static let browsing = Color.adaptive(lightHex: 0x0E7490, darkHex: 0x22D3EE)
    public static let browsingSoft = Color.adaptive(lightHex: 0x0E7490, darkHex: 0x22D3EE, lightAlpha: 0.11, darkAlpha: 0.15)

    public static let executing = Color.adaptive(lightHex: 0x4F46E5, darkHex: 0x818CF8)
    public static let executingSoft = Color.adaptive(lightHex: 0x4F46E5, darkHex: 0x818CF8, lightAlpha: 0.11, darkAlpha: 0.15)

    public static let attention = Color.adaptive(lightHex: 0xB45309, darkHex: 0xFBBF24)
    public static let attentionSoft = Color.adaptive(lightHex: 0xB45309, darkHex: 0xFBBF24, lightAlpha: 0.12, darkAlpha: 0.16)

    public static let critical = Color.adaptive(lightHex: 0xB91C1C, darkHex: 0xF87171)
    public static let criticalSoft = Color.adaptive(lightHex: 0xB91C1C, darkHex: 0xF87171, lightAlpha: 0.11, darkAlpha: 0.16)

    public static let idle = Color.adaptive(lightHex: 0x64748B, darkHex: 0x94A3B8)
    public static let idleSoft = Color.adaptive(lightHex: 0x64748B, darkHex: 0x94A3B8, lightAlpha: 0.10, darkAlpha: 0.14)
}

// MARK: - Curated Character Palette (6 luminous Harbor hues)

public enum HelmCharacterPalette {
    public static let hues: [Color] = [
        Color.adaptive(lightHex: 0x2563EB, darkHex: 0x60A5FA), // 0: Chart Cobalt
        Color.adaptive(lightHex: 0x0891B2, darkHex: 0x22D3EE), // 1: Harbor Cyan
        Color.adaptive(lightHex: 0xB47B15, darkHex: 0xF0C05A), // 2: Maritime Brass
        Color.adaptive(lightHex: 0x4F46E5, darkHex: 0x818CF8), // 3: Deep Indigo
        Color.adaptive(lightHex: 0x7C3AED, darkHex: 0xA78BFA), // 4: Slate Violet
        Color.adaptive(lightHex: 0x059669, darkHex: 0x34D399), // 5: Sea Jade
    ]

    public static func color(for index: Int) -> Color {
        let safeIndex = ((index % hues.count) + hues.count) % hues.count
        return hues[safeIndex]
    }
}

// MARK: - 4pt Spacing & Radii Scale

public enum HelmSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 6
    public static let m: CGFloat = 8
    public static let l: CGFloat = 12
    public static let xl: CGFloat = 16
    public static let xxl: CGFloat = 20
    public static let xxxl: CGFloat = 28
}

public enum HelmRadius {
    public static let badge: CGFloat = 6
    public static let control: CGFloat = 8
    public static let panel: CGFloat = 12
    public static let card: CGFloat = 14
    public static let hero: CGFloat = 18
}

// MARK: - Motion Discipline (Snappy Springs & Smooth Curves)

public enum HelmMotion {
    public static let micro = Animation.easeOut(duration: 0.14)
    public static let state = Animation.spring(response: 0.34, dampingFraction: 0.84)
    public static let bouncy = Animation.spring(response: 0.36, dampingFraction: 0.64)
    public static let settle = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.50)
    public static let exit = Animation.easeOut(duration: 0.15)
    public static let pulseSweep = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.45)
}

// MARK: - Reduce Motion & Window Occlusion Environment Keys

private struct HelmReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct HelmWindowOccludedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var helmReduceMotion: Bool {
        get { self[HelmReduceMotionKey.self] }
        set { self[HelmReduceMotionKey.self] = newValue }
    }

    var helmWindowOccluded: Bool {
        get { self[HelmWindowOccludedKey.self] }
        set { self[HelmWindowOccludedKey.self] = newValue }
    }
}

// MARK: - Card Elevation Modifier

public struct HelmCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var isSelected: Bool
    public var accentBorder: Color?

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(HelmSurface.elevated)
                    .shadow(color: HelmSurface.cardShadow, radius: isSelected ? 12 : 6, x: 0, y: isSelected ? 4 : 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        accentBorder ?? (isSelected ? HelmAccent.primary.opacity(0.45) : HelmSurface.line),
                        lineWidth: isSelected ? 1.25 : 1.0
                    )
            )
    }
}

public extension View {
    func helmCard(cornerRadius: CGFloat = HelmRadius.card, isSelected: Bool = false, accentBorder: Color? = nil) -> some View {
        modifier(HelmCardModifier(cornerRadius: cornerRadius, isSelected: isSelected, accentBorder: accentBorder))
    }
}

// MARK: - Native Control Styles (crisp, tactile, hover-reactive)

public struct HelmPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : HelmInk.muted)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .fill(isEnabled
                        ? (configuration.isPressed ? HelmAccent.primary.opacity(0.82) : HelmAccent.primary)
                        : HelmSurface.well)
                    .shadow(color: isEnabled ? HelmAccent.primary.opacity(0.24) : .clear, radius: 6, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .strokeBorder(isEnabled ? Color.white.opacity(0.16) : HelmSurface.line, lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(HelmMotion.micro, value: configuration.isPressed)
    }
}

public struct HelmSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? HelmInk.primary : HelmInk.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? HelmSurface.well : HelmSurface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .strokeBorder(HelmSurface.lineStrong, lineWidth: 0.9)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(HelmMotion.micro, value: configuration.isPressed)
    }
}

// MARK: - Shared Formatting Helpers

public extension AgentRole {
    var displayName: String {
        switch self {
        case .orchestrator: return "Orchestrator"
        case .researcher: return "Researcher"
        case .coder: return "Coder"
        case .browserAnalyst: return "Browser Analyst"
        case .qaVerifier: return "QA Verifier"
        case .specialist: return "Specialist"
        }
    }

    var shortTagline: String {
        switch self {
        case .orchestrator: return "Delegates tasks & watches for exceptions"
        case .researcher: return "Investigates specs & verifies facts"
        case .coder: return "Writes & tests code in isolated VM"
        case .browserAnalyst: return "Browses headlessly & reads via Vision OCR"
        case .qaVerifier: return "Validates outputs & acceptance checks"
        case .specialist: return "Focused specialist collaborating on shared state"
        }
    }
}

public extension LLMBackendKind {
    var displayName: String {
        switch self {
        case .mock: return "Demo Mode"
        case .claudeCLI: return "Claude"
        case .codexCLI: return "Codex"
        case .piCLI: return "Pi CLI"
        case .directHTTP: return "OpenAI / API"
        case .foundationModels: return "Apple On-Device"
        }
    }
}

public extension AgentPersonality {
    var symbolName: String {
        switch self {
        case .calmCommander: return "helm"
        case .pragmaticBuilder: return "hammer.fill"
        case .methodicalArchitect: return "compass.drawing"
        case .adversarialReviewer: return "magnifyingglass.circle.fill"
        case .creativeExplorer: return "sparkles"
        case .rapidOperator: return "bolt.fill"
        }
    }
}

public extension AgentCapability {
    var displayName: String {
        switch self {
        case .codeExec: return "Run Code in Sandbox"
        case .browser: return "Headless Browser"
        case .ocr: return "Vision OCR Reading"
        case .readSharedState: return "Read Shared Memory"
        case .proposeSharedState: return "Write Shared Memory"
        case .delegateTasks: return "Delegate Tasks"
        case .requestHumanDecision: return "Ask Human Approval"
        }
    }

    var humanDescription: String {
        switch self {
        case .codeExec: return "Run shell commands & tests inside the isolated VM or Seatbelt sandbox"
        case .browser: return "Open and click pages in a background headless Chrome session"
        case .ocr: return "Read visible text & button coordinates via Apple Vision OCR"
        case .readSharedState: return "See verified facts, rules, and findings shared by the crew"
        case .proposeSharedState: return "Publish new facts and observations for other agents"
        case .delegateTasks: return "Break goals into subtasks and assign work to specialists"
        case .requestHumanDecision: return "Pause and alert you before risky or ambiguous actions"
        }
    }

    var symbolName: String {
        switch self {
        case .codeExec: return "terminal"
        case .browser: return "globe"
        case .ocr: return "text.viewfinder"
        case .readSharedState: return "tray.full"
        case .proposeSharedState: return "square.and.pencil"
        case .delegateTasks: return "arrow.triangle.branch"
        case .requestHumanDecision: return "hand.raised"
        }
    }
}
