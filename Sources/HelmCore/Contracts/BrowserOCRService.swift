import CoreGraphics
import Foundation

public struct OCRLine: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Float
    public let normalizedRect: CGRect   // Vision bottom-left [0,1]
    public let cssRect: CGRect          // Converted CDP top-left viewport px

    public init(text: String, confidence: Float, normalizedRect: CGRect, cssRect: CGRect) {
        self.text = text
        self.confidence = confidence
        self.normalizedRect = normalizedRect
        self.cssRect = cssRect
    }
}

public struct DOMInteractiveElement: Codable, Sendable, Equatable {
    public let ref: String              // e.g. "@e1"
    public let tagName: String
    public let role: String?
    public let text: String
    public let elementID: String?
    public let cssRect: CGRect
    public let isInteractive: Bool

    public init(
        ref: String,
        tagName: String,
        role: String? = nil,
        text: String,
        elementID: String? = nil,
        cssRect: CGRect,
        isInteractive: Bool = true
    ) {
        self.ref = ref
        self.tagName = tagName
        self.role = role
        self.text = text
        self.elementID = elementID
        self.cssRect = cssRect
        self.isInteractive = isInteractive
    }
}

public struct BrowserObservation: Codable, Sendable, Equatable {
    public let url: String
    public let title: String
    public let viewportSize: CGSize
    public let screenshotPNGPath: URL
    public let ocrLines: [OCRLine]
    public let domElements: [DOMInteractiveElement]
    public let trustTag: TrustLevel     // Always .untrustedData for external web content
    public let latencyMs: Double

    public init(
        url: String,
        title: String,
        viewportSize: CGSize,
        screenshotPNGPath: URL,
        ocrLines: [OCRLine],
        domElements: [DOMInteractiveElement],
        trustTag: TrustLevel = .untrustedData,
        latencyMs: Double
    ) {
        self.url = url
        self.title = title
        self.viewportSize = viewportSize
        self.screenshotPNGPath = screenshotPNGPath
        self.ocrLines = ocrLines
        self.domElements = domElements
        self.trustTag = .untrustedData  // Enforce invariant regardless of caller argument
        self.latencyMs = latencyMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        self.viewportSize = try container.decode(CGSize.self, forKey: .viewportSize)
        self.screenshotPNGPath = try container.decode(URL.self, forKey: .screenshotPNGPath)
        self.ocrLines = try container.decode([OCRLine].self, forKey: .ocrLines)
        self.domElements = try container.decode([DOMInteractiveElement].self, forKey: .domElements)
        _ = try container.decodeIfPresent(TrustLevel.self, forKey: .trustTag)
        self.trustTag = .untrustedData
        self.latencyMs = try container.decode(Double.self, forKey: .latencyMs)
    }
}

public enum BrowserAction: Codable, Sendable, Equatable {
    case navigate(url: String)
    case clickCSS(x: Double, y: Double)
    case clickOCRText(query: String)
    case typeText(selectorOrOCR: String, text: String, submit: Bool)
    case evaluateJS(script: String)
}

public protocol BrowserOCRService: Sendable {
    func openSession(projectID: UUID) async throws -> UUID
    func perform(_ action: BrowserAction, sessionID: UUID, timeoutSeconds: TimeInterval) async throws -> BrowserObservation
    func closeSession(_ sessionID: UUID) async
}
