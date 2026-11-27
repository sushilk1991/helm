import HelmCore
import SwiftUI

/// Deterministic pattern-assigned 5x5 dot-matrix agent character driven by `AgentCharacterSeed`.
/// Orchestrator renders a dedicated Compass Crest silhouette; workers render distinct
/// crown + eye/visor + symmetric 3x5->5x5 body silhouettes in curated Harbor Chartroom hues.
public struct AgentCharacterCanvas: View {
    public let seed: AgentCharacterSeed
    public let state: AgentActivityState
    public let size: CGFloat
    public let staticPhaseOverride: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion
    @Environment(\.helmWindowOccluded) private var isOccluded

    public init(
        seed: AgentCharacterSeed,
        state: AgentActivityState,
        size: CGFloat = 24,
        staticPhaseOverride: TimeInterval? = nil
    ) {
        self.seed = seed
        self.state = state
        self.size = size
        self.staticPhaseOverride = staticPhaseOverride
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    private var shouldAnimate: Bool {
        guard !effectiveReduceMotion, !isOccluded, staticPhaseOverride == nil else {
            return false
        }
        switch state {
        case .idle, .thinking, .browsing, .executing, .completed:
            return true
        case .exception, .waiting, .paused:
            return false
        }
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: !shouldAnimate)) { timeline in
            let elapsed = staticPhaseOverride ?? (shouldAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0)
            Canvas { context, canvasSize in
                renderCharacter(in: &context, size: canvasSize, time: elapsed)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel(seed.isOrchestrator ? "Orchestrator Agent (\(state.rawValue))" : "Agent (\(state.rawValue))")
    }

    // MARK: - Deterministic Sprite Renderer

    private func renderCharacter(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let dim = min(size.width, size.height)
        // Use a 7x7 logical grid where columns 1..5, rows 1..5 are the canonical 5x5 body,
        // row 0 holds the deterministic crown / Compass Crest, row 6 holds scanline/hand accents,
        // and col 6 row 0..3 holds the raised `!` alert glyph on exception.
        let gap: CGFloat = 0.5
        let cell = (dim - gap * 6.0) / 7.0
        guard cell > 0.5 else { return }

        let baseColor = resolvedInkColor()
        let eyeColor = resolvedEyeColor()
        let accentColor = resolvedAccentColor()

        // Helper to paint a single logical pip at (row: 0..<7, col: 0..<7)
        func paintPip(row: Int, col: Int, color: Color, opacity: Double = 1.0, scale: CGFloat = 1.0) {
            guard (0..<7).contains(row), (0..<7).contains(col) else { return }
            let x = CGFloat(col) * (cell + gap) + (cell * (1 - scale) * 0.5)
            let y = CGFloat(row) * (cell + gap) + (cell * (1 - scale) * 0.5)
            let w = cell * scale
            let rect = CGRect(x: x, y: y, width: w, height: w)
            let path = RoundedRectangle(cornerRadius: w * 0.28, style: .continuous).path(in: rect)
            context.fill(path, with: .color(color.opacity(opacity)))
        }

        // Compute animation phases
        let blinkCycle = 2.5 + Double(hashByte(at: 5) % 21) * 0.1 // 2.5s .. 4.5s staggered per agent
        let blinkOffset = Double(hashByte(at: 6)) * 0.03
        let blinkPhase = (time + blinkOffset).truncatingRemainder(dividingBy: blinkCycle)
        let isBlinking = (state == .idle && !effectiveReduceMotion && staticPhaseOverride == nil && blinkPhase < 0.16)

        let browStep = Int(floor(time * 2.5)) % 3 // 0, 1, 2 for thinking wave
        let scanCol = 1 + (Int(floor(time * 3.0)) % 5) // 1..5 across visor columns
        let execToggle = Int(floor(time * 2.5)) % 2 == 0

        let dimOpacity: Double = (state == .paused || state == .waiting) ? 0.65 : 1.0

        // 1. Crown / Orchestrator Compass Crest (row 0, cols 1..5)
        if seed.isOrchestrator {
            // Dedicated Helm Compass Crest silhouette
            paintPip(row: 0, col: 3, color: accentColor, opacity: dimOpacity)
            paintPip(row: 0, col: 2, color: baseColor, opacity: 0.75 * dimOpacity)
            paintPip(row: 0, col: 4, color: baseColor, opacity: 0.75 * dimOpacity)
        } else {
            for col in 0..<5 {
                if isCrownPipFilled(crownIndex: seed.crownIndex, col: col) {
                    paintPip(row: 0, col: col + 1, color: baseColor, opacity: 0.9 * dimOpacity)
                }
            }
        }

        // 2. Canonical 5x5 Body Matrix (mapped into logical rows 1..5, cols 1..5)
        for r in 0..<5 {
            for c in 0..<5 {
                // Row 1 (upper torso/head) always carries head frame + eyes on row 1/2
                let isEyeRow = (r == 1)
                if isEyeRow && isEyePosition(eyeIndex: seed.eyeIndex, col: c) {
                    continue
                }
                let bodyFilled = seed.isBodyPixelFilled(row: r, col: c) || (r == 1 && (c == 1 || c == 3 || c == 2)) || (r == 2 && c == 2)
                if bodyFilled {
                    var pipOpacity = dimOpacity
                    var pipColor = baseColor
                    if state == .thinking && r == 0 && c >= 1 && c <= 3 {
                        let waveIdx = c - 1
                        if waveIdx == browStep && !effectiveReduceMotion {
                            pipColor = accentColor
                            pipOpacity = 1.0
                        }
                    }
                    paintPip(row: r + 1, col: c + 1, color: pipColor, opacity: pipOpacity)
                }
            }
        }

        // 3. Eye / Visor Glyph (logical row 2, cols 1..5 -> seed row 1)
        if !isBlinking {
            for c in 0..<5 {
                if isEyePosition(eyeIndex: seed.eyeIndex, col: c) {
                    var currentEyeColor = eyeColor
                    if state == .browsing && !effectiveReduceMotion && (c + 1) == scanCol {
                        currentEyeColor = accentColor
                    }
                    paintPip(row: 2, col: c + 1, color: currentEyeColor, opacity: dimOpacity)
                }
            }
        } else {
            // Closed-eye horizontal slit during blink
            paintPip(row: 2, col: 2, color: baseColor, opacity: 0.45, scale: 0.75)
            paintPip(row: 2, col: 4, color: baseColor, opacity: 0.45, scale: 0.75)
        }

        // 4. State-Specific Micro-Animations & Static Poses (row 6 / col 6)
        switch state {
        case .thinking:
            // 3-pip brow wave above head or along bottom indicator
            for i in 0..<3 {
                let active = effectiveReduceMotion ? true : (i == browStep)
                paintPip(
                    row: 6,
                    col: 2 + i,
                    color: active ? accentColor : baseColor,
                    opacity: active ? 0.95 : 0.30,
                    scale: active ? 0.90 : 0.70
                )
            }

        case .browsing:
            // Bottom 1px scan shimmer (or full visor scan bar under reduce motion)
            if effectiveReduceMotion {
                for c in 1...5 {
                    paintPip(row: 6, col: c, color: accentColor, opacity: 0.75, scale: 0.75)
                }
            } else {
                paintPip(row: 6, col: scanCol, color: accentColor, opacity: 0.95, scale: 0.9)
                if scanCol < 5 {
                    paintPip(row: 6, col: scanCol + 1, color: accentColor, opacity: 0.55, scale: 0.8)
                } else {
                    paintPip(row: 6, col: scanCol - 1, color: accentColor, opacity: 0.55, scale: 0.8)
                }
            }

        case .executing:
            // Alternating 2-pip working hands / core heartbeat at bottom corners
            if effectiveReduceMotion || execToggle {
                paintPip(row: 6, col: 1, color: accentColor, opacity: 0.95, scale: 0.9)
                paintPip(row: 6, col: 5, color: baseColor, opacity: 0.45, scale: 0.8)
            } else {
                paintPip(row: 6, col: 1, color: baseColor, opacity: 0.45, scale: 0.8)
                paintPip(row: 6, col: 5, color: accentColor, opacity: 0.95, scale: 0.9)
            }

        case .exception:
            // Raised `!` glyph in col 6 (rows 0, 1, 3)
            paintPip(row: 0, col: 6, color: HelmSemantic.critical, opacity: 1.0)
            paintPip(row: 1, col: 6, color: HelmSemantic.critical, opacity: 1.0)
            paintPip(row: 3, col: 6, color: HelmSemantic.critical, opacity: 1.0)

        case .completed:
            paintPip(row: 6, col: 2, color: HelmSemantic.steady, opacity: 0.85, scale: 0.85)
            paintPip(row: 6, col: 3, color: HelmSemantic.steady, opacity: 1.0, scale: 0.9)
            paintPip(row: 6, col: 4, color: HelmSemantic.steady, opacity: 0.85, scale: 0.85)

        case .idle, .waiting, .paused:
            break
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

    private func isCrownPipFilled(crownIndex: Int, col: Int) -> Bool {
        switch crownIndex % 8 {
        case 0: return col == 1 || col == 3           // Twin antennae
        case 1: return col == 1 || col == 2 || col == 3 // Dome cap
        case 2: return col >= 0 && col <= 4           // Visor brow
        case 3: return col == 0 || col == 4           // Horned crest
        case 4: return col == 0 || col == 2 || col == 4 // Stepped crown
        case 5: return col == 2                       // Center spire
        case 6: return col == 1 || col == 2 || col == 3 // Halo bar
        default: return col == 0 || col == 1 || col == 3 || col == 4 // Notched helmet
        }
    }

    private func isEyePosition(eyeIndex: Int, col: Int) -> Bool {
        switch eyeIndex % 6 {
        case 0: return col == 1 || col == 3           // Twin dots
        case 1: return col == 1 || col == 2 || col == 3 // Wide visor
        case 2: return col == 0 || col == 4           // Wide-set eyes
        case 3: return col == 2                       // Cyclops lens
        case 4: return col == 0 || col == 1 || col == 3 || col == 4 // Bracket visor
        default: return col == 0 || col == 2 || col == 4          // Tri-sensor eyes
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
