import HelmCore
import SwiftUI

/// Luminous dot-matrix companion bot driven deterministically by `AgentCharacterSeed`.
/// Renders a crisp circular LED-dot silhouette on a 9x9 grid with subtle breathing bob,
/// natural staggered eye blinks, glances, and state-specific micro-animations
/// (thinking wave, browsing radar scan, coding hand bounce, completed happy eyes, exception alert).
public struct AgentCharacterCanvas: View {
    public let seed: AgentCharacterSeed
    public let state: AgentActivityState
    public let size: CGFloat
    public let staticPhaseOverride: TimeInterval?
    public let showStageBacking: Bool
    public let interactive: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion
    @Environment(\.helmWindowOccluded) private var isOccluded

    @State private var hopOffset: CGFloat = 0
    @State private var hopScale: CGFloat = 1.0
    @State private var isHovering: Bool = false

    public init(
        seed: AgentCharacterSeed,
        state: AgentActivityState,
        size: CGFloat = 44,
        staticPhaseOverride: TimeInterval? = nil,
        showStageBacking: Bool = false,
        interactive: Bool = false
    ) {
        self.seed = seed
        self.state = state
        self.size = size
        self.staticPhaseOverride = staticPhaseOverride
        self.showStageBacking = showStageBacking
        self.interactive = interactive
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    private var shouldAnimate: Bool {
        guard !effectiveReduceMotion, !isOccluded, staticPhaseOverride == nil else {
            return false
        }
        switch state {
        case .idle, .thinking, .browsing, .executing, .completed, .exception:
            return true
        case .waiting, .paused:
            return false
        }
    }

    public var body: some View {
        let baseColor = resolvedInkColor()
        let auraColor = resolvedAccentColor()

        ZStack {
            if showStageBacking {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                baseColor.opacity(isHovering ? 0.24 : 0.14),
                                baseColor.opacity(0.03),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: size * 0.65
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(
                                (state == .exception ? HelmSemantic.attention : baseColor).opacity(isHovering ? 0.42 : 0.20),
                                lineWidth: 1.0
                            )
                    )
                    .frame(width: size, height: size)
            }

            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !shouldAnimate)) { timeline in
                let elapsed = staticPhaseOverride ?? (shouldAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0)
                let botSize = showStageBacking ? size * 0.74 : size
                Canvas { context, canvasSize in
                    renderBot(
                        in: &context,
                        size: canvasSize,
                        time: elapsed,
                        baseColor: baseColor,
                        accentColor: auraColor
                    )
                }
                .frame(width: botSize, height: botSize)
            }
            .offset(y: hopOffset)
            .scaleEffect(hopScale * (isHovering && interactive ? 1.06 : 1.0))
        }
        .frame(width: size, height: size)
        .animation(HelmMotion.bouncy, value: isHovering)
        .onHover { hovering in
            guard interactive else { return }
            isHovering = hovering
        }
        .onTapGesture {
            guard interactive else { return }
            triggerHop()
        }
        .accessibilityLabel(seed.isOrchestrator ? "Orchestrator Bot (\(state.rawValue))" : "Agent Bot (\(state.rawValue))")
    }

    private func triggerHop() {
        guard !effectiveReduceMotion else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
            hopOffset = -5
            hopScale = 1.08
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.spring(response: 0.30, dampingFraction: 0.60)) {
                hopOffset = 0
                hopScale = 1.0
            }
        }
    }

    // MARK: - 9x9 Expressive Dot-Matrix Bot Renderer

    private func renderBot(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        baseColor: Color,
        accentColor: Color
    ) {
        let dim = min(size.width, size.height)
        let gridCount: CGFloat = 9.0
        let cell = dim / gridCount
        guard cell > 0.6 else { return }

        // Subtle organic vertical bob (paused in reduce motion / static snapshots / waiting / paused)
        let phaseOffset = Double(hashByte(at: 4)) * 0.05
        let bobAmount: CGFloat
        if effectiveReduceMotion || staticPhaseOverride != nil || state == .paused || state == .waiting {
            bobAmount = 0
        } else {
            let speed: Double = (state == .executing || state == .thinking) ? 3.8 : 2.1
            let amplitude: CGFloat = (state == .executing) ? cell * 0.24 : cell * 0.14
            bobAmount = CGFloat(sin((time + phaseOffset) * speed)) * amplitude
        }

        let dimOpacity: Double = (state == .paused || state == .waiting) ? 0.58 : 1.0
        let eyeColor = resolvedEyeColor()

        // Helper to draw a luminous circular/squircle LED dot at logical (row: 0..<9, col: 0..<9)
        func drawDot(
            row: Int,
            col: Int,
            color: Color,
            opacity: Double = 1.0,
            diameterScale: CGFloat = 0.78,
            glow: Bool = false,
            yShift: CGFloat = 0
        ) {
            guard (0..<9).contains(row), (0..<9).contains(col) else { return }
            let cx = (CGFloat(col) + 0.5) * cell
            let cy = (CGFloat(row) + 0.5) * cell + bobAmount + yShift
            let d = cell * diameterScale
            let rect = CGRect(x: cx - d * 0.5, y: cy - d * 0.5, width: d, height: d)

            if glow && dim >= 28 {
                let glowD = d * 1.9
                let glowRect = CGRect(x: cx - glowD * 0.5, y: cy - glowD * 0.5, width: glowD, height: glowD)
                context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(opacity * 0.22)))
            }

            let dotPath = RoundedRectangle(cornerRadius: d * 0.42, style: .continuous).path(in: rect)
            context.fill(dotPath, with: .color(color.opacity(opacity)))
        }

        // Animation timings (staggered per agent via hash bytes)
        let blinkPeriod = 2.8 + Double(hashByte(at: 5) % 24) * 0.1
        let blinkPhase = (time + phaseOffset * 2.0).truncatingRemainder(dividingBy: blinkPeriod)
        let isBlinking = !effectiveReduceMotion && staticPhaseOverride == nil && (state == .idle || state == .thinking) && blinkPhase < 0.14

        // Subtle glance shift (-0.18 .. +0.18 cell) while idle/browsing
        let glancePeriod = 5.4 + Double(hashByte(at: 7) % 15) * 0.15
        let glanceCycle = (time + phaseOffset).truncatingRemainder(dividingBy: glancePeriod) / glancePeriod
        let glanceX: CGFloat = (!effectiveReduceMotion && staticPhaseOverride == nil && state == .idle)
            ? (glanceCycle > 0.72 && glanceCycle < 0.86 ? cell * 0.14 : (glanceCycle > 0.86 && glanceCycle < 0.96 ? -cell * 0.14 : 0))
            : 0

        let waveIndex = Int(floor((time + phaseOffset) * 3.4)) % 5 // 0..4
        let scanCol = 2 + (Int(floor((time + phaseOffset) * 4.0)) % 5) // 2..6
        let execBeat = Int(floor((time + phaseOffset) * 3.6)) % 2 == 0
        let alertPulse = 0.65 + 0.35 * sin(time * 5.0)

        // 1. Crown / Antennae (Row 0 & Row 1, cols 2..6)
        if seed.isOrchestrator {
            // Iconic Orchestrator Compass Crest (luminous brass diamond tip + wings)
            drawDot(row: 0, col: 4, color: accentColor, opacity: dimOpacity, diameterScale: 0.88, glow: true)
            drawDot(row: 1, col: 3, color: baseColor, opacity: 0.85 * dimOpacity, diameterScale: 0.76)
            drawDot(row: 1, col: 4, color: accentColor, opacity: 0.95 * dimOpacity, diameterScale: 0.82, glow: true)
            drawDot(row: 1, col: 5, color: baseColor, opacity: 0.85 * dimOpacity, diameterScale: 0.76)
        } else {
            let crownStyle = seed.crownIndex % 8
            for c in 0..<5 {
                if isCrownTopFilled(style: crownStyle, col: c) {
                    let isLit = (state == .thinking && !effectiveReduceMotion && c == waveIndex)
                    drawDot(
                        row: 0,
                        col: c + 2,
                        color: isLit ? accentColor : baseColor,
                        opacity: (isLit ? 1.0 : 0.82) * dimOpacity,
                        diameterScale: isLit ? 0.86 : 0.72,
                        glow: isLit || state == .executing
                    )
                }
            }
            // Head crown bar (row 1, cols 2..6)
            for c in 0..<5 {
                if isHeadTopFilled(style: crownStyle, col: c) {
                    drawDot(row: 1, col: c + 2, color: baseColor, opacity: 0.92 * dimOpacity, diameterScale: 0.78)
                }
            }
        }

        // 2. Rounded Bot Head & Chassis (Rows 2..6, cols 1..7)
        // Map the deterministic 5x5 body mask into cols 2..6, rows 2..6 with solid head silhouette so it ALWAYS reads as a charming bot
        for r in 0..<5 {
            let gridRow = r + 2
            for c in 0..<5 {
                let gridCol = c + 2
                // Reserve face window on row 2..3 for eyes/visor
                let isFaceInterior = (r == 1) && (c >= 1 && c <= 3)
                if isFaceInterior {
                    // Subtle dark visor backing dot so bright eyes pop!
                    drawDot(row: gridRow, col: gridCol, color: baseColor, opacity: 0.18 * dimOpacity, diameterScale: 0.72)
                    continue
                }

                // Head frame (r == 0, 1, 2) + torso (r == 3, 4) blending deterministic seed pixels
                let structural: Bool
                switch r {
                case 0: structural = (c >= 1 && c <= 3) || seed.isBodyPixelFilled(row: 0, col: c)
                case 1: structural = (c == 0 || c == 4) // side cheeks around visor
                case 2: structural = (c >= 0 && c <= 4) // chin/jawline
                case 3: structural = (c >= 1 && c <= 3) || seed.isBodyPixelFilled(row: 3, col: c)
                default: structural = seed.isBodyPixelFilled(row: 4, col: c) || (c == 1 || c == 3)
                }

                if structural {
                    let isCoreDot = (r == 3 && c == 2)
                    let isWaveLit = (state == .thinking && r == 0 && c == waveIndex && !effectiveReduceMotion)
                    let dotColor: Color
                    let dotOpacity: Double
                    let glow: Bool

                    if isWaveLit {
                        dotColor = accentColor
                        dotOpacity = 1.0
                        glow = true
                    } else if isCoreDot && (state == .executing || state == .thinking || seed.isOrchestrator) {
                        dotColor = accentColor
                        dotOpacity = 0.95 * dimOpacity
                        glow = true
                    } else {
                        dotColor = baseColor
                        dotOpacity = (r >= 3 ? 0.84 : 0.94) * dimOpacity
                        glow = false
                    }

                    drawDot(row: gridRow, col: gridCol, color: dotColor, opacity: dotOpacity, diameterScale: 0.80, glow: glow)
                }
            }
        }

        // Cute side ear-nubs / arms (cols 1 and 7)
        let earRow = (seed.crownIndex % 2 == 0) ? 3 : 4
        drawDot(row: earRow, col: 1, color: baseColor, opacity: 0.65 * dimOpacity, diameterScale: 0.68)
        drawDot(row: earRow, col: 7, color: baseColor, opacity: 0.65 * dimOpacity, diameterScale: 0.68)

        // 3. Expressive Eyes / Visor (gridRow = 3, cols 3, 4, 5)
        func drawEye(col: Int, color: Color, scale: CGFloat = 0.84, glow: Bool = true, yShift: CGFloat = 0) {
            let cx = (CGFloat(col) + 0.5) * cell + glanceX
            let cy = 3.5 * cell + bobAmount + yShift
            let d = cell * scale
            let rect = CGRect(x: cx - d * 0.5, y: cy - d * 0.5, width: d, height: d)
            if glow && dim >= 28 {
                let glowD = d * 1.95
                let glowRect = CGRect(x: cx - glowD * 0.5, y: cy - glowD * 0.5, width: glowD, height: glowD)
                context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(0.28 * dimOpacity)))
            }
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(dimOpacity)))
        }

        if state == .completed {
            // Cheerful happy raised eyes
            drawEye(col: 3, color: HelmSemantic.steady, scale: 0.78, glow: true, yShift: -cell * 0.12)
            drawEye(col: 5, color: HelmSemantic.steady, scale: 0.78, glow: true, yShift: -cell * 0.12)
        } else if isBlinking {
            // Soft closed-eye horizontal slits
            for eyeCol in [3, 5] {
                let cx = (CGFloat(eyeCol) + 0.5) * cell
                let cy = 3.55 * cell + bobAmount
                let w = cell * 0.82
                let h = max(1.2, cell * 0.24)
                let rect = CGRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h)
                context.fill(RoundedRectangle(cornerRadius: h * 0.5).path(in: rect), with: .color(eyeColor.opacity(0.55)))
            }
        } else {
            switch seed.eyeIndex % 6 {
            case 0, 2: // Classic expressive twin eyes
                drawEye(col: 3, color: eyeColor)
                drawEye(col: 5, color: eyeColor)
            case 1: // Wide glowing visor bar (3 dots)
                for c in 3...5 {
                    let lit = (state == .browsing && !effectiveReduceMotion && c == scanCol)
                    drawEye(col: c, color: lit ? accentColor : eyeColor, scale: lit ? 0.90 : 0.76)
                }
            case 3: // Friendly cyclops lens
                drawEye(col: 4, color: eyeColor, scale: 0.96)
            case 4: // Twin bright dots + subtle center bridge
                drawEye(col: 3, color: eyeColor, scale: 0.86)
                drawEye(col: 4, color: accentColor.opacity(0.65), scale: 0.45, glow: false)
                drawEye(col: 5, color: eyeColor, scale: 0.86)
            default: // Tri-sensor eyes
                drawEye(col: 3, color: eyeColor, scale: 0.72)
                drawEye(col: 4, color: accentColor, scale: 0.72)
                drawEye(col: 5, color: eyeColor, scale: 0.72)
            }
        }

        // 4. Feet & State-Specific Micro-Animations (Row 7 & Row 8 / Col 8)
        switch state {
        case .thinking:
            // Orbiting 3-dot reasoning pulse below feet
            for i in 0..<3 {
                let isActive = effectiveReduceMotion ? true : (i == waveIndex % 3)
                drawDot(
                    row: 8,
                    col: 3 + i,
                    color: isActive ? accentColor : baseColor,
                    opacity: isActive ? 0.95 : 0.28,
                    diameterScale: isActive ? 0.76 : 0.52,
                    glow: isActive
                )
            }

        case .browsing:
            // Sweeping cyan radar shimmer across row 8
            if effectiveReduceMotion {
                for c in 2...6 {
                    drawDot(row: 8, col: c, color: accentColor, opacity: 0.70, diameterScale: 0.60)
                }
            } else {
                drawDot(row: 8, col: scanCol, color: accentColor, opacity: 0.98, diameterScale: 0.78, glow: true)
                if scanCol > 2 {
                    drawDot(row: 8, col: scanCol - 1, color: accentColor, opacity: 0.42, diameterScale: 0.58)
                }
                if scanCol < 6 {
                    drawDot(row: 8, col: scanCol + 1, color: accentColor, opacity: 0.42, diameterScale: 0.58)
                }
            }

        case .executing:
            // Lively alternating coding sparks at left/right hands (row 5 cols 0/8) + feet bounce
            let leftActive = effectiveReduceMotion || execBeat
            drawDot(row: 5, col: 0, color: leftActive ? accentColor : baseColor, opacity: leftActive ? 0.95 : 0.30, diameterScale: leftActive ? 0.76 : 0.52, glow: leftActive)
            drawDot(row: 5, col: 8, color: !leftActive ? accentColor : baseColor, opacity: !leftActive ? 0.95 : 0.30, diameterScale: !leftActive ? 0.76 : 0.52, glow: !leftActive)
            drawDot(row: 7, col: 3, color: baseColor, opacity: 0.85, diameterScale: 0.68, yShift: leftActive ? -cell * 0.2 : 0)
            drawDot(row: 7, col: 5, color: baseColor, opacity: 0.85, diameterScale: 0.68, yShift: !leftActive ? -cell * 0.2 : 0)

        case .exception:
            // Crisp pulsing `!` alert badge in top-right (col 8, rows 0..3)
            let p = effectiveReduceMotion ? 1.0 : alertPulse
            drawDot(row: 0, col: 8, color: HelmSemantic.critical, opacity: p, diameterScale: 0.84, glow: true)
            drawDot(row: 1, col: 8, color: HelmSemantic.critical, opacity: p, diameterScale: 0.84, glow: true)
            drawDot(row: 3, col: 8, color: HelmSemantic.critical, opacity: p, diameterScale: 0.84, glow: true)
            drawDot(row: 7, col: 3, color: baseColor, opacity: 0.80, diameterScale: 0.68)
            drawDot(row: 7, col: 5, color: baseColor, opacity: 0.80, diameterScale: 0.68)

        case .completed:
            // Steady emerald ground halo
            drawDot(row: 7, col: 3, color: baseColor, opacity: 0.82, diameterScale: 0.68)
            drawDot(row: 7, col: 5, color: baseColor, opacity: 0.82, diameterScale: 0.68)
            drawDot(row: 8, col: 3, color: HelmSemantic.steady, opacity: 0.65, diameterScale: 0.52)
            drawDot(row: 8, col: 4, color: HelmSemantic.steady, opacity: 0.95, diameterScale: 0.64, glow: true)
            drawDot(row: 8, col: 5, color: HelmSemantic.steady, opacity: 0.65, diameterScale: 0.52)

        case .idle, .waiting, .paused:
            // Calm grounded feet
            drawDot(row: 7, col: 3, color: baseColor, opacity: 0.78 * dimOpacity, diameterScale: 0.66)
            drawDot(row: 7, col: 5, color: baseColor, opacity: 0.78 * dimOpacity, diameterScale: 0.66)
        }
    }

    private func resolvedInkColor() -> Color {
        if state == .exception {
            return HelmSemantic.attention
        }
        if seed.isOrchestrator {
            return HelmAccent.brass
        }
        return HelmCharacterPalette.color(for: seed.hueIndex)
    }

    private func resolvedAccentColor() -> Color {
        switch state {
        case .exception: return HelmSemantic.critical
        case .browsing: return HelmSemantic.browsing
        case .executing: return HelmSemantic.executing
        case .thinking: return HelmSemantic.thinking
        case .completed: return HelmSemantic.steady
        default: return HelmAccent.brass
        }
    }

    private func resolvedEyeColor() -> Color {
        switch state {
        case .exception: return HelmSemantic.critical
        case .paused, .waiting: return HelmInk.muted
        default: return HelmInk.primary
        }
    }

    private func isCrownTopFilled(style: Int, col: Int) -> Bool {
        switch style {
        case 0: return col == 1 || col == 3           // Twin antennae
        case 1: return col == 2                       // Center antenna spire
        case 2: return col == 0 || col == 4           // Cat-bot ears
        case 3: return col == 1 || col == 2 || col == 3 // Crown halo
        case 4: return col == 0 || col == 2 || col == 4 // Triple crest
        case 5: return col == 2                       // Beacon nub
        case 6: return col == 0 || col == 4           // Horned crest
        default: return col == 1 || col == 3          // Twin sensors
        }
    }

    private func isHeadTopFilled(style: Int, col: Int) -> Bool {
        switch style {
        case 0, 1, 5: return col >= 1 && col <= 3
        case 2, 6: return col >= 0 && col <= 4
        default: return col >= 1 && col <= 3
        }
    }

    private func hashByte(at byteIndex: Int) -> UInt8 {
        let hex = seed.hexDigest
        let startIdx = byteIndex * 2
        guard startIdx + 2 <= hex.count else { return 128 }
        let start = hex.index(hex.startIndex, offsetBy: startIdx)
        let end = hex.index(start, offsetBy: 2)
        return UInt8(hex[start..<end], radix: 16) ?? 128
    }
}
