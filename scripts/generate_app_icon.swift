#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconSlot {
    let filename: String
    let sizeTag: String
    let scaleTag: String
    let pixels: Int
}

let slots: [IconSlot] = [
    IconSlot(filename: "icon_16x16.png", sizeTag: "16x16", scaleTag: "1x", pixels: 16),
    IconSlot(filename: "icon_16x16@2x.png", sizeTag: "16x16", scaleTag: "2x", pixels: 32),
    IconSlot(filename: "icon_32x32.png", sizeTag: "32x32", scaleTag: "1x", pixels: 32),
    IconSlot(filename: "icon_32x32@2x.png", sizeTag: "32x32", scaleTag: "2x", pixels: 64),
    IconSlot(filename: "icon_128x128.png", sizeTag: "128x128", scaleTag: "1x", pixels: 128),
    IconSlot(filename: "icon_128x128@2x.png", sizeTag: "128x128", scaleTag: "2x", pixels: 256),
    IconSlot(filename: "icon_256x256.png", sizeTag: "256x256", scaleTag: "1x", pixels: 256),
    IconSlot(filename: "icon_256x256@2x.png", sizeTag: "256x256", scaleTag: "2x", pixels: 512),
    IconSlot(filename: "icon_512x512.png", sizeTag: "512x512", scaleTag: "1x", pixels: 512),
    IconSlot(filename: "icon_512x512@2x.png", sizeTag: "512x512", scaleTag: "2x", pixels: 1024),
]

func srgbColor(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, alpha])!
}

func renderCompassHelmIcon(pixelSize: Int) -> CGImage? {
    let size = CGFloat(pixelSize)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to top-left origin and scale 100x100 normalized coordinate space.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: size / 100.0, y: -size / 100.0)

    // Squircle geometry (macOS standard padded canvas ~84x84 centered in 100x100)
    let squircleRect = CGRect(x: 6.0, y: 6.0, width: 88.0, height: 88.0)
    let cornerRadius: CGFloat = 19.5
    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Subtle soft shadow under squircle (at larger sizes)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -2.0),
        blur: 3.5,
        color: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.28])
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(srgbColor(0x0D131B))
    ctx.fillPath()
    ctx.restoreGState()

    // Deep Ocean Slate gradient fill (#16202C -> #0D131B)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    let gradColors = [srgbColor(0x16202C), srgbColor(0x0D131B)] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 50, y: 6),
            end: CGPoint(x: 50, y: 94),
            options: []
        )
    }

    // Subtle radial chartroom sheen from top-center
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [0.22, 0.34, 0.50, 0.20])!,
        CGColor(colorSpace: colorSpace, components: [0.05, 0.07, 0.11, 0.0])!,
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: 50, y: 26),
            startRadius: 2,
            endCenter: CGPoint(x: 50, y: 50),
            endRadius: 52,
            options: []
        )
    }
    ctx.restoreGState()

    // 1pt subtle inner rim highlight (white @ 12%)
    let rimInset = squircleRect.insetBy(dx: 0.75, dy: 0.75)
    let rimPath = CGPath(
        roundedRect: rimInset,
        cornerWidth: cornerRadius - 0.75,
        cornerHeight: cornerRadius - 0.75,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(rimPath)
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.12])!)
    ctx.setLineWidth(1.2)
    ctx.strokePath()
    ctx.restoreGState()

    // Compass-Helm geometry in (50, 50) center (spec §3.3 scaled slightly for crisp squircle margin)
    // Wheel scale 0.90 around (50, 50) keeps r=38 tips cleanly inside the 88pt squircle.
    ctx.saveGState()
    ctx.translateBy(x: 50.0, y: 50.0)
    ctx.scaleBy(x: 0.90, y: 0.90)
    ctx.translateBy(x: -50.0, y: -50.0)

    let ivory = srgbColor(0xF4F1EA)
    let brass = srgbColor(0xD4A64A)
    let center = CGPoint(x: 50.0, y: 50.0)

    // 1. Outer wheel ring: r=30, stroke=4.5, #F4F1EA
    ctx.setStrokeColor(ivory)
    ctx.setLineWidth(4.5)
    ctx.strokeEllipse(in: CGRect(x: 50 - 30, y: 50 - 30, width: 60, height: 60))

    // 2. Six radial spokes at 0, 60, 120, 180, 240, 300 degrees from r=11 to r=38 (.round caps)
    ctx.setLineCap(.round)
    ctx.setLineWidth(4.0)
    for idx in 0..<6 {
        let deg = Double(idx) * 60.0
        // 0 deg = 12 o'clock (top: -pi/2 in top-left coords)
        let rad = (deg - 90.0) * .pi / 180.0
        let x1 = center.x + CGFloat(cos(rad)) * 11.0
        let y1 = center.y + CGFloat(sin(rad)) * 11.0
        let x2 = center.x + CGFloat(cos(rad)) * 38.0
        let y2 = center.y + CGFloat(sin(rad)) * 38.0

        ctx.setStrokeColor(ivory)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
        ctx.strokePath()
    }

    // 3. Top 12-o'clock Maritime Brass (#D4A64A) course crown/needle cap
    ctx.saveGState()
    ctx.setFillColor(brass)
    let crown = CGMutablePath()
    crown.move(to: CGPoint(x: 50.0, y: 5.5))   // North tip
    crown.addLine(to: CGPoint(x: 54.4, y: 12.0))
    crown.addLine(to: CGPoint(x: 50.0, y: 18.2))
    crown.addLine(to: CGPoint(x: 45.6, y: 12.0))
    crown.closeSubpath()
    ctx.addPath(crown)
    ctx.fillPath()
    ctx.restoreGState()

    // 4. Central Orchestrator hub: circle r=10.5, stroke 3.5 (#F4F1EA)
    ctx.setStrokeColor(ivory)
    ctx.setLineWidth(3.5)
    ctx.strokeEllipse(in: CGRect(x: 50 - 10.5, y: 50 - 10.5, width: 21.0, height: 21.0))

    // 5. Solid r=4.0 core dot (#D4A64A)
    ctx.setFillColor(brass)
    ctx.fillEllipse(in: CGRect(x: 50 - 4.0, y: 50 - 4.0, width: 8.0, height: 8.0))

    ctx.restoreGState()
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "HelmIconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination for \(url.path)"])
    }
    let props: [CFString: Any] = [
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGInterlaceType: 0
        ]
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "HelmIconGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG at \(url.path)"])
    }
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = repoRoot.appendingPathComponent("Resources", isDirectory: true)
let xcassetsDir = resourcesDir.appendingPathComponent("Assets.xcassets", isDirectory: true)
let appIconSetDir = xcassetsDir.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let tempIconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

let fm = FileManager.default
try fm.createDirectory(at: appIconSetDir, withIntermediateDirectories: true)
try? fm.removeItem(at: tempIconsetDir)
try fm.createDirectory(at: tempIconsetDir, withIntermediateDirectories: true)
defer {
    try? fm.removeItem(at: tempIconsetDir)
}

var imageEntries: [[String: String]] = []

for slot in slots {
    guard let cgImage = renderCompassHelmIcon(pixelSize: slot.pixels) else {
        fputs("Error: failed to render \(slot.pixels)px icon\n", stderr)
        exit(1)
    }
    let assetURL = appIconSetDir.appendingPathComponent(slot.filename)
    try writePNG(cgImage, to: assetURL)

    let iconsetURL = tempIconsetDir.appendingPathComponent(slot.filename)
    try writePNG(cgImage, to: iconsetURL)

    imageEntries.append([
        "filename": slot.filename,
        "idiom": "mac",
        "scale": slot.scaleTag,
        "size": slot.sizeTag,
    ])
}

let rootContents: [String: Any] = [
    "info": [
        "author": "xcode",
        "version": 1,
    ]
]
let rootContentsData = try JSONSerialization.data(withJSONObject: rootContents, options: [.prettyPrinted, .sortedKeys])
try rootContentsData.write(to: xcassetsDir.appendingPathComponent("Contents.json"))

let appIconContents: [String: Any] = [
    "images": imageEntries,
    "info": [
        "author": "xcode",
        "version": 1,
    ],
]
let appIconContentsData = try JSONSerialization.data(withJSONObject: appIconContents, options: [.prettyPrinted, .sortedKeys])
try appIconContentsData.write(to: appIconSetDir.appendingPathComponent("Contents.json"))

// Also emit Resources/AppIcon.icns via iconutil for reliable bundling & verification
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
try? fm.removeItem(at: icnsURL)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tempIconsetDir.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("Error: iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}

let icnsSize = (try? fm.attributesOfItem(atPath: icnsURL.path)[.size] as? NSNumber)?.intValue ?? 0
print("Generated AppIcon.appiconset (10 PNGs) + AppIcon.icns (\(icnsSize) bytes)")
