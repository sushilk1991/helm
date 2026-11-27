import CoreGraphics
import Foundation

public enum CoordinateMapper: Sendable {
    /// Clamps a Vision normalized bounding box (bottom-left origin) to `[0, 1]`.
    public static func clampNormalizedRect(_ normalizedRect: CGRect) -> CGRect {
        let nx = max(0.0, min(1.0, normalizedRect.origin.x))
        let ny = max(0.0, min(1.0, normalizedRect.origin.y))
        let nw = max(0.0, min(1.0 - nx, normalizedRect.size.width))
        let nh = max(0.0, min(1.0 - ny, normalizedRect.size.height))
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    /// Converts a Vision bottom-left `[0, 1]` normalized rect into a CDP top-left CSS viewport rect.
    /// Accounts for `imagePixelSize` vs `viewportSize` device pixel ratio (`1.0`, `2.0`, etc.) and clamps to viewport bounds.
    public static func visionNormalizedToCSSRect(
        _ normalizedRect: CGRect,
        viewportSize: CGSize,
        imagePixelSize: CGSize? = nil
    ) -> CGRect {
        let vpWidth = max(0.0, viewportSize.width)
        let vpHeight = max(0.0, viewportSize.height)
        guard vpWidth > 0, vpHeight > 0 else {
            return .zero
        }

        let clamped = clampNormalizedRect(normalizedRect)
        let imgWidth = (imagePixelSize?.width ?? 0) > 0 ? imagePixelSize!.width : vpWidth
        let imgHeight = (imagePixelSize?.height ?? 0) > 0 ? imagePixelSize!.height : vpHeight

        let dprX = imgWidth / vpWidth
        let dprY = imgHeight / vpHeight

        let pxX = clamped.origin.x * imgWidth
        let pxY = (1.0 - (clamped.origin.y + clamped.size.height)) * imgHeight
        let pxW = clamped.size.width * imgWidth
        let pxH = clamped.size.height * imgHeight

        let cssX = max(0.0, min(vpWidth, pxX / dprX))
        let cssY = max(0.0, min(vpHeight, pxY / dprY))
        let cssW = max(0.0, min(vpWidth - cssX, pxW / dprX))
        let cssH = max(0.0, min(vpHeight - cssY, pxH / dprY))

        return CGRect(x: cssX, y: cssY, width: cssW, height: cssH)
    }

    /// Returns the center point of a CSS rect, optionally clamped inside `viewportSize`.
    public static func centerPoint(of cssRect: CGRect, clampedTo viewportSize: CGSize? = nil) -> CGPoint {
        var x = cssRect.midX
        var y = cssRect.midY
        if let vp = viewportSize, vp.width > 0, vp.height > 0 {
            x = max(0.0, min(vp.width, x))
            y = max(0.0, min(vp.height, y))
        }
        return CGPoint(x: x, y: y)
    }
}
