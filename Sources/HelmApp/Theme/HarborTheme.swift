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

// MARK: - Surfaces

public enum HelmSurface {
    public static let canvas = Color.adaptive(lightHex: 0xF7F7F5, darkHex: 0x141619)
    public static let sidebar = Color.adaptive(lightHex: 0xF1F1ED, darkHex: 0x181B20)
    public static let elevated = Color.adaptive(lightHex: 0xFFFFFF, darkHex: 0x1C1F24)
    public static let well = Color.adaptive(lightHex: 0xF0F0EC, darkHex: 0x101215)
    public static let line = Color.adaptive(lightHex: 0x000000, darkHex: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
    public static let lineStrong = Color.adaptive(lightHex: 0x000000, darkHex: 0xFFFFFF, lightAlpha: 0.15, darkAlpha: 0.16)
    public static let hoverWash = Color.adaptive(lightHex: 0x1D2430, darkHex: 0xF2F4F7, lightAlpha: 0.04, darkAlpha: 0.05)
    public static let selectedWash = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x5B8DEF, lightAlpha: 0.10, darkAlpha: 0.16)
}

// MARK: - Typography Ink

public enum HelmInk {
    public static let primary = Color.adaptive(lightHex: 0x1D2430, darkHex: 0xF2F4F7)
    public static let secondary = Color.adaptive(lightHex: 0x526072, darkHex: 0x9CA8B8)
    public static let muted = Color.adaptive(lightHex: 0x64748B, darkHex: 0x7A8699)
}

// MARK: - Brand Accents

public enum HelmAccent {
    public static let primary = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x5B8DEF)
    public static let primarySoft = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x5B8DEF, lightAlpha: 0.12, darkAlpha: 0.18)
    public static let brass = Color.adaptive(lightHex: 0x8F6510, darkHex: 0xD4A64A)
    public static let brassSoft = Color.adaptive(lightHex: 0x8F6510, darkHex: 0xD4A64A, lightAlpha: 0.12, darkAlpha: 0.18)
    public static let iconDarkTop = Color.adaptive(lightHex: 0x16202C, darkHex: 0x16202C)
    public static let iconDarkBottom = Color.adaptive(lightHex: 0x0D131B, darkHex: 0x0D131B)
    public static let iconIvory = Color.adaptive(lightHex: 0xF4F1EA, darkHex: 0xF4F1EA)
    public static let iconBrass = Color.adaptive(lightHex: 0xD4A64A, darkHex: 0xD4A64A)
    public static let iconRim = Color.adaptive(lightHex: 0xFFFFFF, darkHex: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.12)
}

// MARK: - Semantic State Tokens (always paired with symbol + label)

public enum HelmSemantic {
    public static let steady = Color.adaptive(lightHex: 0x1B7A50, darkHex: 0x34D399)
    public static let steadySoft = Color.adaptive(lightHex: 0x1B7A50, darkHex: 0x34D399, lightAlpha: 0.12, darkAlpha: 0.16)

    public static let thinking = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x60A5FA)
    public static let thinkingSoft = Color.adaptive(lightHex: 0x2454B8, darkHex: 0x60A5FA, lightAlpha: 0.12, darkAlpha: 0.16)

    public static let browsing = Color.adaptive(lightHex: 0x0E7490, darkHex: 0x22D3EE)
    public static let browsingSoft = Color.adaptive(lightHex: 0x0E7490, darkHex: 0x22D3EE, lightAlpha: 0.12, darkAlpha: 0.16)

    public static let executing = Color.adaptive(lightHex: 0x4338CA, darkHex: 0x818CF8)
    public static let executingSoft = Color.adaptive(lightHex: 0x4338CA, darkHex: 0x818CF8, lightAlpha: 0.12, darkAlpha: 0.16)

    public static let attention = Color.adaptive(lightHex: 0xB45309, darkHex: 0xF59E0B)
    public static let attentionSoft = Color.adaptive(lightHex: 0xB45309, darkHex: 0xF59E0B, lightAlpha: 0.12, darkAlpha: 0.17)

    public static let critical = Color.adaptive(lightHex: 0xB91C1C, darkHex: 0xF87171)
    public static let criticalSoft = Color.adaptive(lightHex: 0xB91C1C, darkHex: 0xF87171, lightAlpha: 0.12, darkAlpha: 0.18)

    public static let idle = Color.adaptive(lightHex: 0x64748B, darkHex: 0x94A3B8)
    public static let idleSoft = Color.adaptive(lightHex: 0x64748B, darkHex: 0x94A3B8, lightAlpha: 0.12, darkAlpha: 0.15)
}

// MARK: - Curated Character Palette (6 Harbor Chartroom hues)

public enum HelmCharacterPalette {
    public static let hues: [Color] = [
        Color.adaptive(lightHex: 0x2454B8, darkHex: 0x60A5FA), // 0: Chart Cobalt
        Color.adaptive(lightHex: 0x0E7490, darkHex: 0x22D3EE), // 1: Harbor Teal
        Color.adaptive(lightHex: 0x8F6510, darkHex: 0xD4A64A), // 2: Maritime Brass
        Color.adaptive(lightHex: 0x4338CA, darkHex: 0x818CF8), // 3: Deep Indigo
        Color.adaptive(lightHex: 0x6D4C9E, darkHex: 0xA78BFA), // 4: Slate Plum
        Color.adaptive(lightHex: 0x1B7A50, darkHex: 0x34D399), // 5: Sea Jade
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
    public static let badge: CGFloat = 4
    public static let control: CGFloat = 6
    public static let panel: CGFloat = 10
    public static let card: CGFloat = 12
}

// MARK: - Motion Discipline

public enum HelmMotion {
    public static let micro = Animation.easeOut(duration: 0.12)
    public static let state = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.24)
    public static let settle = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.50)
    public static let exit = Animation.easeOut(duration: 0.15)
    public static let pulseSweep = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.40)
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

// MARK: - Native Control Styles (crisp in active & inactive windows)

public struct HelmPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.white : HelmInk.muted)
            .padding(.horizontal, HelmSpace.l)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .fill(isEnabled
                        ? (configuration.isPressed ? HelmAccent.primary.opacity(0.82) : HelmAccent.primary)
                        : HelmSurface.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .strokeBorder(isEnabled ? Color.clear : HelmSurface.line, lineWidth: 1)
            )
    }
}

public struct HelmSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? HelmInk.primary : HelmInk.muted)
            .padding(.horizontal, HelmSpace.l)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? HelmSurface.well : HelmSurface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .strokeBorder(HelmSurface.lineStrong, lineWidth: 1)
            )
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
}

public extension LLMBackendKind {
    var displayName: String {
        switch self {
        case .mock: return "Mock"
        case .claudeCLI: return "Claude"
        case .codexCLI: return "Codex"
        case .directHTTP: return "Direct HTTP"
        case .foundationModels: return "Apple FM"
        }
    }
}

public extension AgentCapability {
    var displayName: String {
        switch self {
        case .codeExec: return "Sandbox Exec"
        case .browser: return "Browser"
        case .ocr: return "Vision OCR"
        case .readSharedState: return "Read State"
        case .proposeSharedState: return "Propose State"
        case .delegateTasks: return "Delegate"
        case .requestHumanDecision: return "Ask Human"
        }
    }
}
