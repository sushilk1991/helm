import SwiftUI

public enum CompassHelmStyle: Sendable {
    case emblem
    case inlineMark
    case monochromeTemplate
}

/// Precision geometric Compass-Helm mark on a normalized 100x100 grid (spec §3.3).
/// Supports full-color emblem, inline Harbor Chartroom mark, and MenuBarExtra monochrome template
/// with an optional 3pt amber badge dot strictly when an open exception exists.
public struct CompassHelmLogo: View {
    public let size: CGFloat
    public let style: CompassHelmStyle
    public let hasOpenException: Bool
    public let settleTrigger: Int

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion
    @Environment(\.helmWindowOccluded) private var isOccluded

    @State private var wheelAngleDegrees: Double = 0

    public init(
        size: CGFloat = 32,
        style: CompassHelmStyle = .emblem,
        hasOpenException: Bool = false,
        settleTrigger: Int = 0
    ) {
        self.size = size
        self.style = style
        self.hasOpenException = hasOpenException
        self.settleTrigger = settleTrigger
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    public var body: some View {
        ZStack {
            if style == .emblem {
                Canvas { context, canvasSize in
                    let dim = min(canvasSize.width, canvasSize.height)
                    let scale = dim / 100.0
                    let originX = (canvasSize.width - dim) / 2.0
                    let originY = (canvasSize.height - dim) / 2.0
                    context.translateBy(x: originX, y: originY)
                    context.scaleBy(x: scale, y: scale)

                    let squircle = RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .path(in: CGRect(x: 4, y: 4, width: 92, height: 92))
                    context.fill(
                        squircle,
                        with: .linearGradient(
                            Gradient(colors: [HelmAccent.iconDarkTop, HelmAccent.iconDarkBottom]),
                            startPoint: CGPoint(x: 50, y: 4),
                            endPoint: CGPoint(x: 50, y: 96)
                        )
                    )
                    let rim = RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .path(in: CGRect(x: 5, y: 5, width: 90, height: 90))
                    context.stroke(rim, with: .color(HelmAccent.iconRim), lineWidth: 1.5)
                }
            }

            Canvas { context, canvasSize in
                let dim = min(canvasSize.width, canvasSize.height)
                let scale = dim / 100.0
                let originX = (canvasSize.width - dim) / 2.0
                let originY = (canvasSize.height - dim) / 2.0

                context.translateBy(x: originX, y: originY)
                context.scaleBy(x: scale, y: scale)

                switch style {
                case .emblem:
                    drawWheel(in: &context, scaleFactor: 0.86, wheelColor: HelmAccent.iconIvory, accentColor: HelmAccent.iconBrass, isMonochrome: false)
                case .inlineMark:
                    drawWheel(in: &context, scaleFactor: 1.0, wheelColor: HelmInk.primary, accentColor: HelmAccent.brass, isMonochrome: false)
                case .monochromeTemplate:
                    drawWheel(in: &context, scaleFactor: 1.0, wheelColor: .primary, accentColor: .primary, isMonochrome: true)
                }
            }
            .rotationEffect(.degrees(wheelAngleDegrees))

            if style == .monochromeTemplate && hasOpenException {
                Canvas { context, canvasSize in
                    let dim = min(canvasSize.width, canvasSize.height)
                    let scale = dim / 100.0
                    let originX = (canvasSize.width - dim) / 2.0
                    let originY = (canvasSize.height - dim) / 2.0
                    context.translateBy(x: originX, y: originY)
                    context.scaleBy(x: scale, y: scale)

                    let badgeDiameter = max(16.0, 3.0 / max(scale, 0.01))
                    let badgeRect = CGRect(
                        x: 96.0 - badgeDiameter,
                        y: 4.0,
                        width: badgeDiameter,
                        height: badgeDiameter
                    )
                    context.fill(Path(ellipseIn: badgeRect), with: .color(HelmSemantic.attention))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(hasOpenException ? "Helm Control Plane (Attention Required)" : "Helm Control Plane")
        .onChange(of: settleTrigger) { _, _ in
            guard !effectiveReduceMotion, !isOccluded else {
                wheelAngleDegrees = 0
                return
            }
            wheelAngleDegrees = -30
            Task { @MainActor in
                await Task.yield()
                withAnimation(HelmMotion.settle) {
                    wheelAngleDegrees = 0
                }
            }
        }
    }

    private func drawWheel(
        in context: inout GraphicsContext,
        scaleFactor: CGFloat,
        wheelColor: Color,
        accentColor: Color,
        isMonochrome: Bool
    ) {
        var wheelCtx = context
        wheelCtx.translateBy(x: 50, y: 50)
        wheelCtx.scaleBy(x: scaleFactor, y: scaleFactor)
        wheelCtx.translateBy(x: -50, y: -50)

        // Outer wheel ring r=30, stroke 4.5
        let ringRect = CGRect(x: 20, y: 20, width: 60, height: 60)
        wheelCtx.stroke(Path(ellipseIn: ringRect), with: .color(wheelColor), lineWidth: 4.5)

        // Six radial spokes at 0, 60, 120, 180, 240, 300 degrees from r=11 to r=38
        let strokeStyle = StrokeStyle(lineWidth: 4.0, lineCap: .round)
        for idx in 0..<6 {
            let rad = (Double(idx) * 60.0 - 90.0) * .pi / 180.0
            let p1 = CGPoint(x: 50.0 + CGFloat(cos(rad)) * 11.0, y: 50.0 + CGFloat(sin(rad)) * 11.0)
            let p2 = CGPoint(x: 50.0 + CGFloat(cos(rad)) * 38.0, y: 50.0 + CGFloat(sin(rad)) * 38.0)
            var spoke = Path()
            spoke.move(to: p1)
            spoke.addLine(to: p2)
            wheelCtx.stroke(spoke, with: .color(wheelColor), style: strokeStyle)
        }

        // Top 12-o'clock crown / course needle cap
        if !isMonochrome {
            var crown = Path()
            crown.move(to: CGPoint(x: 50.0, y: 5.5))
            crown.addLine(to: CGPoint(x: 54.4, y: 12.0))
            crown.addLine(to: CGPoint(x: 50.0, y: 18.2))
            crown.addLine(to: CGPoint(x: 45.6, y: 12.0))
            crown.closeSubpath()
            wheelCtx.fill(crown, with: .color(accentColor))
        } else {
            var tip = Path()
            tip.move(to: CGPoint(x: 50.0, y: 6.5))
            tip.addLine(to: CGPoint(x: 53.5, y: 13.0))
            tip.addLine(to: CGPoint(x: 46.5, y: 13.0))
            tip.closeSubpath()
            wheelCtx.fill(tip, with: .color(wheelColor))
        }

        // Central Orchestrator hub: circle r=10.5, stroke 3.5
        let hubRect = CGRect(x: 50 - 10.5, y: 50 - 10.5, width: 21.0, height: 21.0)
        wheelCtx.stroke(Path(ellipseIn: hubRect), with: .color(wheelColor), lineWidth: 3.5)

        // Central core dot r=4.0 (hollow in monochrome mode per spec §3.3, solid brass in full color)
        if !isMonochrome {
            let coreRect = CGRect(x: 50 - 4.0, y: 50 - 4.0, width: 8.0, height: 8.0)
            wheelCtx.fill(Path(ellipseIn: coreRect), with: .color(accentColor))
        }
    }
}
