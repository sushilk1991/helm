import CoreGraphics
import CoreText
import Foundation
import HelmCore
import ImageIO
import Vision

public actor VisionOCRService {
    private var warmUpTask: Task<Void, Never>?

    public init() {}

    /// Idempotently pre-warms Apple Vision / ANE off `@MainActor` (both `.accurate` and `.fast`) using a tiny synthetic CGImage.
    public func warmUp() async {
        if let existing = warmUpTask {
            await existing.value
            return
        }
        let task = Task.detached(priority: .utility) {
            Self.performWarmUp()
        }
        warmUpTask = task
        await task.value
    }

    /// Fires idempotent ANE warm-up without blocking the caller.
    public func warmUpInBackground() {
        guard warmUpTask == nil else { return }
        warmUpTask = Task.detached(priority: .utility) {
            Self.performWarmUp()
        }
    }

    private static func performWarmUp() {
        guard let cgImage = renderWarmUpCGImage() else { return }
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = (level == .accurate)
            request.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            try? handler.perform([request])
        }
    }

    public func recognizeText(
        pngData: Data,
        viewportSize: CGSize,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) async throws -> [OCRLine] {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw HelmBrowserError.cdpProtocolError("Unable to decode PNG screenshot data for Vision OCR.")
            }

            let imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            try handler.perform([request])

            guard let observations = request.results, !observations.isEmpty else {
                return []
            }

            var lines: [OCRLine] = []
            lines.reserveCapacity(observations.count)

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let clampedNorm = CoordinateMapper.clampNormalizedRect(observation.boundingBox)
                guard clampedNorm.width > 0, clampedNorm.height > 0 else { continue }

                let cssRect = CoordinateMapper.visionNormalizedToCSSRect(
                    clampedNorm,
                    viewportSize: viewportSize,
                    imagePixelSize: imagePixelSize
                )
                lines.append(
                    OCRLine(
                        text: text,
                        confidence: candidate.confidence,
                        normalizedRect: clampedNorm,
                        cssRect: cssRect
                    )
                )
            }

            lines.sort { lhs, rhs in
                if lhs.cssRect.minY != rhs.cssRect.minY {
                    return lhs.cssRect.minY < rhs.cssRect.minY
                }
                return lhs.cssRect.minX < rhs.cssRect.minX
            }

            return lines
        }.value
    }

    /// Matches an OCR query using exact trimmed case-insensitive -> case-insensitive substring -> token overlap.
    /// Returns `nil` if no match exists (never returns a fallback coordinate).
    public static func matchOCRLine(query: String, in lines: [OCRLine]) -> OCRLine? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !lines.isEmpty else {
            return nil
        }

        // 1. Exact trimmed case-insensitive match
        let exactMatches = lines.filter {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
        if let bestExact = exactMatches.max(by: { $0.confidence < $1.confidence }) {
            return bestExact
        }

        // 2. Case-insensitive substring match (prefer tighter match, then higher confidence)
        let substringMatches = lines.filter {
            $0.text.localizedCaseInsensitiveContains(trimmedQuery)
        }
        if let bestSub = substringMatches.max(by: { lhs, rhs in
            let ratioL = Double(trimmedQuery.count) / Double(max(1, lhs.text.count))
            let ratioR = Double(trimmedQuery.count) / Double(max(1, rhs.text.count))
            if abs(ratioL - ratioR) > 0.01 {
                return ratioL < ratioR
            }
            return lhs.confidence < rhs.confidence
        }) {
            return bestSub
        }

        // 3. Whitespace token overlap (only for multi-word queries or full-token match to avoid spurious single-word misses)
        let queryTokens = tokenizeWords(trimmedQuery)
        guard !queryTokens.isEmpty else { return nil }

        var bestTokenMatch: (line: OCRLine, score: Double)?
        for line in lines {
            let lineTokens = Set(tokenizeWords(line.text))
            guard !lineTokens.isEmpty else { continue }
            let matchedCount = queryTokens.filter { lineTokens.contains($0) }.count
            guard matchedCount > 0 else { continue }

            // Single-token query must match whole word exactly; multi-token query needs all tokens or >= 2/3 overlap.
            if queryTokens.count == 1 {
                if matchedCount == 1 {
                    let score = 1.0 + Double(line.confidence) * 0.1
                    if bestTokenMatch == nil || score > bestTokenMatch!.score {
                        bestTokenMatch = (line, score)
                    }
                }
            } else {
                let coverage = Double(matchedCount) / Double(queryTokens.count)
                if matchedCount == queryTokens.count || (matchedCount >= 2 && coverage >= 0.67) {
                    let score = coverage + Double(line.confidence) * 0.1
                    if bestTokenMatch == nil || score > bestTokenMatch!.score {
                        bestTokenMatch = (line, score)
                    }
                }
            }
        }

        return bestTokenMatch?.line
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func renderWarmUpCGImage() -> CGImage? {
        let width = 256
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        if let attrString = CFAttributedStringCreate(nil, "HELM OCR WARMUP" as CFString, attrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attrString)
            context.textPosition = CGPoint(x: 12, y: 22)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
