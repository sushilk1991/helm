import CoreGraphics
import CoreText
import Foundation
@testable import HelmBrowser
@testable import HelmCore
import ImageIO
import Network
import Testing
import UniformTypeIdentifiers

private final class SlowFixtureServer: @unchecked Sendable {
    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)" }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HelmBrowserTier5Tests.SlowServer")

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> SlowFixtureServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "HelmBrowserTier5Tests.SlowQueue")
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                guard let data, let req = String(data: data, encoding: .utf8),
                      let first = req.split(separator: "\r\n").first else {
                    conn.cancel()
                    return
                }
                let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if path.hasPrefix("/slow") {
                    queue.asyncAfter(deadline: .now() + 8.0) {
                        let html = "<!doctype html><html><body><h1>LATE</h1></body></html>"
                        let body = Data(html.utf8)
                        let hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        var pkt = Data(hdr.utf8)
                        pkt.append(body)
                        conn.send(content: pkt, completion: .contentProcessed { _ in conn.cancel() })
                    }
                } else {
                    let html = "<!doctype html><html><body><h1>READY</h1></body></html>"
                    let body = Data(html.utf8)
                    let hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    var pkt = Data(hdr.utf8)
                    pkt.append(body)
                    conn.send(content: pkt, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    if let p = listener.port?.rawValue {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: HelmBrowserError.cdpLaunchFailed("No port"))
                    }
                case .failed(let err):
                    once.done = true
                    cont.resume(throwing: err)
                case .cancelled:
                    once.done = true
                    cont.resume(throwing: HelmBrowserError.cdpLaunchFailed("Cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return SlowFixtureServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}

private func renderAccurateTestPNG(_ text: String) -> Data {
    let size = CGSize(width: 480, height: 160)
    let ctx = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: Int(size.width) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    ctx.textPosition = CGPoint(x: 24, y: 64)
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

@Suite("HelmBrowser Tier 5 Adversarial Regression Tests", .serialized)
struct HelmBrowserTier5Tests {
    @Test("MAJOR-2a: VisionOCRService.warmUp() warms .accurate level so first .accurate OCR completes quickly")
    func warmUpWarmsAccurateLevel() async throws {
        let ocr = VisionOCRService()
        await ocr.warmUp()

        let png = renderAccurateTestPNG("TIER 5 ACCURATE OK")
        let start = ContinuousClock.now
        let lines = try await ocr.recognizeText(
            pngData: png,
            viewportSize: CGSize(width: 480, height: 160),
            recognitionLevel: .accurate
        )
        let elapsed = ContinuousClock.now - start
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        #expect(elapsedSec < 2.0)
        #expect(lines.map(\.text).joined(separator: " ").contains("TIER 5 ACCURATE OK"))
    }

    @Test("MAJOR-2b: BrowseReadActTool.perform returns timeout promptly within <= 2.5s on slow endpoint")
    func deadlineTimeoutReturnsPromptly() async throws {
        let server = try await SlowFixtureServer.start()
        defer { server.stop() }

        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())
        let start = ContinuousClock.now
        do {
            _ = try await tool.perform(.navigate(url: "\(server.baseURL)/slow"), sessionID: sid, timeoutSeconds: 1.0)
            Issue.record("Expected HelmBrowserError.timeout")
        } catch let err as HelmBrowserError {
            if case .timeout = err {
                // expected
            } else {
                Issue.record("Expected timeout error, got \(err)")
            }
        }
        let elapsed = ContinuousClock.now - start
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        await tool.closeSession(sid)

        #expect(elapsedSec <= 2.5)
    }
}
