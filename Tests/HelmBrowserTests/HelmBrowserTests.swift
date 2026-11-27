import AppKit
import CoreGraphics
import CoreText
import Foundation
import HelmBrowser
import HelmCore
import ImageIO
import Network
import Testing
import UniformTypeIdentifiers

// MARK: - Embedded Local NWListener Fixture Server (127.0.0.1:0, never 9222)

private final class LocalBrowserFixtureServer: @unchecked Sendable {
    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)" }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "HelmBrowserTests.FixtureServer")

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LocalBrowserFixtureServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "HelmBrowserTests.FixtureServer")

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            Self.handleConnection(conn, queue: queue)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            final class Once: @unchecked Sendable { var resolved = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.resolved else { return }
                switch state {
                case .ready:
                    once.resolved = true
                    if let port = listener.port?.rawValue, port != 9222 {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: HelmBrowserError.cdpLaunchFailed("Invalid fixture server port"))
                    }
                case .failed(let err):
                    once.resolved = true
                    continuation.resume(throwing: err)
                case .cancelled:
                    once.resolved = true
                    continuation.resume(throwing: HelmBrowserError.cdpLaunchFailed("Fixture server cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        return LocalBrowserFixtureServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }

    private static func handleConnection(_ conn: NWConnection, queue: DispatchQueue) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            guard let data, let rawReq = String(data: data, encoding: .utf8),
                  let firstLine = rawReq.split(separator: "\r\n").first else {
                conn.cancel()
                return
            }
            let parts = firstLine.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            let path = components?.path ?? "/"
            let queryItems = components?.queryItems ?? []

            if path == "/slow" {
                let delaySec = Double(queryItems.first(where: { $0.name == "delay" })?.value ?? "6") ?? 6.0
                queue.asyncAfter(deadline: .now() + delaySec) {
                    let html = "<!doctype html><html><head><title>Slow</title></head><body><h1>SLOW DONE</h1></body></html>"
                    Self.sendHTML(conn, status: "200 OK", html: html)
                }
                return
            }

            let (status, html) = Self.routeResponse(path: path, queryItems: queryItems)
            Self.sendHTML(conn, status: status, html: html)
        }
    }

    private static func sendHTML(_ conn: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func routeResponse(path: String, queryItems: [URLQueryItem]) -> (String, String) {
        switch path {
        case "/":
            return ("200 OK", """
            <!doctype html><html><head><title>Helm Harbor Home</title>
            <style>body{font-family:sans-serif;padding:24px;background:#fff;color:#111;} .target-link{display:inline-block;padding:12px 20px;background:#111;color:#fff;text-decoration:none;font-weight:bold;}</style>
            </head><body>
            <h1>HELM HARBOR FIXTURE</h1>
            <p class="badge">STATUS: HARBOR READY</p>
            <a class="target-link" href="/form">OPEN FORM</a>
            </body></html>
            """)

        case "/form":
            return ("200 OK", """
            <!doctype html><html><head><title>Dispatch Form</title>
            <style>body{font-family:sans-serif;padding:24px;background:#fff;color:#111;} label,input,button{display:block;margin:10px 0;font-size:16px;} button{padding:12px 20px;background:#111;color:#fff;border:none;font-weight:bold;}</style>
            </head><body>
            <h1>DISPATCH FORM</h1>
            <form action="/result" method="get">
              <label for="code">CODE</label>
              <input id="code" name="code" type="text">
              <label for="note">NOTE</label>
              <input id="note" name="note" type="text">
              <button id="submit-btn" type="submit">SUBMIT ORDER</button>
            </form>
            </body></html>
            """)

        case "/form-nobutton":
            return ("200 OK", """
            <!doctype html><html><head><title>Buttonless Form</title>
            <style>body{font-family:sans-serif;padding:24px;background:#fff;color:#111;} label,input{display:block;margin:10px 0;font-size:16px;}</style>
            </head><body>
            <h1>BUTTONLESS FORM</h1>
            <form action="/result" method="get">
              <label for="code">CODE</label>
              <input id="code" name="code" type="text">
              <label for="note">NOTE</label>
              <input id="note" name="note" type="text">
            </form>
            </body></html>
            """)

        case "/form-spa":
            return ("200 OK", """
            <!doctype html><html><head><title>SPA Form</title>
            <style>body{font-family:sans-serif;padding:24px;background:#fff;color:#111;} label,input,button{display:block;margin:10px 0;font-size:16px;} button{padding:12px 20px;background:#111;color:#fff;border:none;font-weight:bold;}</style>
            </head><body>
            <h1>SPA FORM</h1>
            <form id="spa-form" onsubmit="event.preventDefault(); window.__submitCount = (window.__submitCount || 0) + 1; document.getElementById('spa-out').textContent = 'CNT=' + window.__submitCount + '|VAL=' + document.getElementById('q').value;">
              <label for="q">QUERY</label>
              <input id="q" name="q" type="text">
              <button id="spa-submit" type="submit">SEND SPA</button>
            </form>
            <p id="spa-out">CNT=0|VAL=</p>
            </body></html>
            """)

        case "/result":
            let code = queryItems.first(where: { $0.name == "code" })?.value ?? ""
            let note = queryItems.first(where: { $0.name == "note" })?.value ?? ""
            return ("200 OK", """
            <!doctype html><html><head><title>Order Confirmed</title></head>
            <body style="font-family:sans-serif;padding:24px;background:#fff;color:#111;">
            <h1>ORDER CONFIRMED</h1>
            <p id="result-code">CODE: \(code)</p>
            <p id="result-note">NOTE: \(note)</p>
            </body></html>
            """)

        case "/ocr-target":
            return ("200 OK", """
            <!doctype html><html><head><title>OCR Targets</title>
            <style>
              body{font-family:sans-serif;padding:24px;background:#fff;color:#111;}
              .btn{display:block;width:260px;height:56px;margin:36px 0;background:#111;color:#fff;font-size:22px;font-weight:bold;border:none;}
            </style></head><body>
            <button id="alpha-btn" class="btn" type="button">ALPHA TARGET</button>
            <button id="bravo-btn" class="btn" type="button" onclick="document.getElementById('ocr-status').textContent='STATE: BRAVO CLICKED OK'">BRAVO ACTION</button>
            <button id="charlie-btn" class="btn" type="button">CHARLIE VERIFY</button>
            <p id="ocr-status" style="font-size:20px;font-weight:bold;">STATE: IDLE</p>
            </body></html>
            """)

        case "/blank":
            return ("200 OK", "<!doctype html><html><body style=\"margin:0;background:#fff;\"></body></html>")

        case "/404":
            return ("404 Not Found", """
            <!doctype html><html><head><title>404</title></head>
            <body style="font-family:sans-serif;padding:24px;background:#fff;color:#111;">
            <h1>404 HARBOR MISSING</h1><p>RESOURCE NOT FOUND</p>
            </body></html>
            """)

        case "/passkey":
            return ("200 OK", """
            <!doctype html><html><head><title>Passkey Probe</title></head>
            <body style="font-family:sans-serif;padding:24px;background:#fff;color:#111;">
            <h1 id="passkey-status">PENDING</h1>
            <script>
            (async () => {
              const el = document.getElementById('passkey-status');
              try {
                if (!navigator.credentials || typeof navigator.credentials.create !== 'function') {
                  el.textContent = 'PASSKEY_REFUSED_CLEANLY';
                  return;
                }
                await navigator.credentials.create({
                  publicKey: {
                    challenge: new Uint8Array([1, 2, 3, 4]),
                    rp: { name: 'Helm' },
                    user: { id: new Uint8Array([1]), name: 'u', displayName: 'U' },
                    pubKeyCredParams: [{ type: 'public-key', alg: -7 }]
                  }
                });
                el.textContent = 'PASSKEY_UNEXPECTED_OK';
              } catch (_) {
                el.textContent = 'PASSKEY_REFUSED_CLEANLY';
              }
            })();
            </script>
            </body></html>
            """)

        case "/offscale":
            return ("200 OK", """
            <!doctype html><html><head><title>Offscale</title></head>
            <body style="font-family:sans-serif;padding:24px;background:#fff;color:#111;">
            <p style="font-size:18px;">OFFSCALE DIAGNOSTIC</p>
            <div id="origin-trap" style="position:fixed;left:0;top:0;width:20px;height:20px;" onclick="window.__originClicked = true;"></div>
            </body></html>
            """)

        case "/large-dom":
            let buttons = (1...500).map { i in
                let num = String(format: "%03d", i)
                return "<button class=\"item-btn\" id=\"item-\(num)\" type=\"button\">ITEM_\(num)</button>"
            }.joined(separator: "\n")
            return ("200 OK", """
            <!doctype html><html><head><title>Large DOM</title></head>
            <body style="font-family:sans-serif;padding:12px;">\(buttons)</body></html>
            """)

        default:
            return ("404 Not Found", "<!doctype html><html><body><h1>404 HARBOR MISSING</h1></body></html>")
        }
    }
}

// MARK: - Test Helpers

private func renderTextPNGData(_ lines: [(text: String, yFromBottom: CGFloat)], size: CGSize = CGSize(width: 640, height: 320)) -> Data {
    let w = Int(size.width)
    let h = Int(size.height)
    let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
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
    for entry in lines {
        let attr = CFAttributedStringCreate(nil, entry.text as CFString, attrs as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 32, y: entry.yFromBottom)
        CTLineDraw(ctLine, ctx)
    }

    let cgImage = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

private func chromeProcessesMatching(sessionID: UUID) -> [Int32] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-f", "helm_chrome_\(sessionID.uuidString)"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return []
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
}

private func tempHelmEntries(prefixes: [String]) -> Set<String> {
    let tmpDir = FileManager.default.temporaryDirectory
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path) else {
        return []
    }
    return Set(names.filter { name in
        prefixes.contains(where: { name.hasPrefix($0) })
    })
}

// MARK: - HelmBrowserTests

@Suite("HelmBrowser Headless Chrome CDP + Vision OCR", .serialized)
struct HelmBrowserTests {

    @Test("1. CoordinateMapper converts Vision bottom-left [0,1] to CSS top-left at DPR 1.0 and 2.0 and clamps cleanly")
    func coordinateMapperMathAndHitTest() async throws {
        // DPR 1.0: viewport 1280x800, image 1280x800
        let normTopLeft = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1) // bottom-left y=0.8..0.9 => top-left y=0.1..0.2
        let css1x = CoordinateMapper.visionNormalizedToCSSRect(
            normTopLeft,
            viewportSize: CGSize(width: 1280, height: 800),
            imagePixelSize: CGSize(width: 1280, height: 800)
        )
        #expect(abs(css1x.origin.x - 128.0) < 0.01)
        #expect(abs(css1x.origin.y - 80.0) < 0.01)
        #expect(abs(css1x.width - 256.0) < 0.01)
        #expect(abs(css1x.height - 80.0) < 0.01)

        // DPR 2.0: viewport 1280x800, image 2560x1600 -> identical CSS coordinates!
        let css2x = CoordinateMapper.visionNormalizedToCSSRect(
            normTopLeft,
            viewportSize: CGSize(width: 1280, height: 800),
            imagePixelSize: CGSize(width: 2560, height: 1600)
        )
        #expect(abs(css2x.origin.x - 128.0) < 0.01)
        #expect(abs(css2x.origin.y - 80.0) < 0.01)
        #expect(abs(css2x.width - 256.0) < 0.01)
        #expect(abs(css2x.height - 80.0) < 0.01)

        let center = CoordinateMapper.centerPoint(of: css2x, clampedTo: CGSize(width: 1280, height: 800))
        #expect(abs(center.x - 256.0) < 0.01)
        #expect(abs(center.y - 120.0) < 0.01)

        // Out-of-range rect clamping
        let clamped = CoordinateMapper.visionNormalizedToCSSRect(
            CGRect(x: -0.2, y: -0.1, width: 1.5, height: 1.5),
            viewportSize: CGSize(width: 1280, height: 800)
        )
        #expect(clamped.minX >= 0 && clamped.minY >= 0)
        #expect(clamped.maxX <= 1280.001 && clamped.maxY <= 800.001)
    }

    @Test("2. VisionOCRService warmUp, deterministic ordering, matchOCRLine, and clean /blank handling")
    func visionOCRExtractsAndOrdersLines() async throws {
        let ocr = VisionOCRService()
        await ocr.warmUp()
        await ocr.warmUp() // idempotent

        let png = renderTextPNGData([
            ("ALPHA TARGET", 240),
            ("BRAVO ACTION", 140),
            ("CHARLIE VERIFY", 40),
        ])
        let unitLines = try await ocr.recognizeText(pngData: png, viewportSize: CGSize(width: 640, height: 320), recognitionLevel: .accurate)
        #expect(unitLines.count >= 3)
        let alpha = try #require(VisionOCRService.matchOCRLine(query: "alpha target", in: unitLines))
        let bravo = try #require(VisionOCRService.matchOCRLine(query: "BRAVO", in: unitLines))
        let charlie = try #require(VisionOCRService.matchOCRLine(query: "charlie verify", in: unitLines))
        #expect(alpha.cssRect.minY < bravo.cssRect.minY)
        #expect(bravo.cssRect.minY < charlie.cssRect.minY)
        #expect(alpha.normalizedRect.minY > charlie.normalizedRect.minY)
        #expect(VisionOCRService.matchOCRLine(query: "NONEXISTENT_BUTTON_XYZ", in: unitLines) == nil)

        // Live Chrome /blank + /ocr-target verification
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())
        defer { Task { await tool.closeSession(sid) } }

        let blankObs = try await tool.perform(.navigate(url: "\(server.baseURL)/blank"), sessionID: sid, timeoutSeconds: 30)
        #expect(blankObs.ocrLines.isEmpty)
        #expect(blankObs.domElements.isEmpty)

        let targetObs = try await tool.perform(.navigate(url: "\(server.baseURL)/ocr-target"), sessionID: sid, timeoutSeconds: 30)
        let a = try #require(VisionOCRService.matchOCRLine(query: "ALPHA TARGET", in: targetObs.ocrLines))
        let b = try #require(VisionOCRService.matchOCRLine(query: "BRAVO ACTION", in: targetObs.ocrLines))
        let c = try #require(VisionOCRService.matchOCRLine(query: "CHARLIE VERIFY", in: targetObs.ocrLines))
        #expect(a.cssRect.minY < b.cssRect.minY)
        #expect(b.cssRect.minY < c.cssRect.minY)
        #expect(a.normalizedRect.minY > c.normalizedRect.minY)

        await tool.closeSession(sid)
    }

    @Test("3. Separate sessions isolate localStorage and never bind or connect to port 9222")
    func sessionIsolationNoLocalStorageLeakAndNever9222() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()

        let sid1 = try await tool.openSession(projectID: UUID())
        let port1 = try #require(await tool.sessionDevToolsPort(sid1))
        #expect(port1 != 9222)
        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/"), sessionID: sid1, timeoutSeconds: 30)
        let obs1 = try await tool.perform(.evaluateJS(script: "localStorage.setItem('helm_iso_k','v1'); document.title='SET_OK';"), sessionID: sid1, timeoutSeconds: 30)
        #expect(obs1.title == "SET_OK")
        await tool.closeSession(sid1)

        let sid2 = try await tool.openSession(projectID: UUID())
        let port2 = try #require(await tool.sessionDevToolsPort(sid2))
        #expect(port2 != 9222)
        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/"), sessionID: sid2, timeoutSeconds: 30)
        let obs2 = try await tool.perform(.evaluateJS(script: "document.title = String(localStorage.getItem('helm_iso_k'));"), sessionID: sid2, timeoutSeconds: 30)
        #expect(obs2.title == "null")
        await tool.closeSession(sid2)
    }

    @Test("4. Browse-Read-Act closed loop: clickOCRText navigation, multi-typeText, form submit, and clickCSS")
    func browseClickOCRAndFormSubmitClosedLoop() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())

        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/"), sessionID: sid, timeoutSeconds: 30)
        let formObs = try await tool.perform(.clickOCRText(query: "OPEN FORM"), sessionID: sid, timeoutSeconds: 30)
        #expect(formObs.url.hasSuffix("/form"))
        #expect(formObs.domElements.contains(where: { $0.elementID == "code" }))

        _ = try await tool.perform(.typeText(selectorOrOCR: "code", text: "HLM42", submit: false), sessionID: sid, timeoutSeconds: 30)
        _ = try await tool.perform(.typeText(selectorOrOCR: "note", text: "ALPHA", submit: false), sessionID: sid, timeoutSeconds: 30)
        let resultObs = try await tool.perform(.clickOCRText(query: "SUBMIT ORDER"), sessionID: sid, timeoutSeconds: 30)
        #expect(resultObs.url.contains("/result"))
        let resultOCRText = resultObs.ocrLines.map(\.text).joined(separator: " ")
        #expect(resultOCRText.contains("ORDER CONFIRMED"))
        #expect(resultOCRText.contains("HLM42"))
        #expect(resultOCRText.contains("ALPHA"))

        // Also verify clickCSS on /ocr-target
        let ocrTargetObs = try await tool.perform(.navigate(url: "\(server.baseURL)/ocr-target"), sessionID: sid, timeoutSeconds: 30)
        let bravoLine = try #require(VisionOCRService.matchOCRLine(query: "BRAVO ACTION", in: ocrTargetObs.ocrLines))
        let clickPt = CoordinateMapper.centerPoint(of: bravoLine.cssRect, clampedTo: ocrTargetObs.viewportSize)
        let afterClick = try await tool.perform(.clickCSS(x: clickPt.x, y: clickPt.y), sessionID: sid, timeoutSeconds: 30)
        let afterText = afterClick.ocrLines.map(\.text).joined(separator: " ")
        #expect(afterText.contains("BRAVO CLICKED OK"))

        await tool.closeSession(sid)
    }

    @Test("5. Missing OCR target throws ocrTargetNotFound without clicking (0,0)")
    func missingOCRTargetThrowsWithoutClickingOrigin() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())

        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/offscale"), sessionID: sid, timeoutSeconds: 30)
        do {
            _ = try await tool.perform(.clickOCRText(query: "NONEXISTENT_BUTTON_XYZ"), sessionID: sid, timeoutSeconds: 15)
            Issue.record("Expected ocrTargetNotFound error")
        } catch let error as HelmBrowserError {
            if case .ocrTargetNotFound(let query, _) = error {
                #expect(query == "NONEXISTENT_BUTTON_XYZ")
            } else {
                Issue.record("Unexpected HelmBrowserError: \(error)")
            }
        }

        // Verify origin trap at (0,0) was NEVER clicked
        let checkReport = try await tool.performDetailed(.evaluateJS(script: "Boolean(window.__originClicked)"), sessionID: sid, timeoutSeconds: 15)
        #expect(checkReport.evalResult == "false")

        await tool.closeSession(sid)
    }

    @Test("6. Passkey endpoint suppresses WebAuthn cleanly without OS sheet and enforces trustTag == .untrustedData")
    func passkeyRejectedWithoutOSSheetAndTrustTagUntrusted() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())

        let report = try await tool.performDetailed(.navigate(url: "\(server.baseURL)/passkey"), sessionID: sid, timeoutSeconds: 30)
        #expect(report.passkeyRejected == true)
        #expect(report.observation.trustTag == .untrustedData)
        let ocrText = report.observation.ocrLines.map(\.text).joined(separator: " ")
        #expect(ocrText.contains("PASSKEY_REFUSED_CLEANLY"))
        #expect(!ocrText.contains("PASSKEY_UNEXPECTED_OK"))

        let cliOutput = report.toCLIOutput()
        #expect(cliOutput.passkeyRejected == true)
        #expect(!cliOutput.screenshotPNGPath.hasPrefix("file://"))
        #expect(FileManager.default.fileExists(atPath: cliOutput.screenshotPNGPath))

        await tool.closeSession(sid)
    }

    @Test("7. /large-dom caps domElements cleanly <= 200 and /404 renders HTTP 404 observation")
    func largeDOMCappedAnd404Clean() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())

        let largeObs = try await tool.perform(.navigate(url: "\(server.baseURL)/large-dom"), sessionID: sid, timeoutSeconds: 30)
        #expect(largeObs.domElements.count > 0)
        #expect(largeObs.domElements.count <= 200)
        #expect(largeObs.latencyMs < 30_000)

        let notFoundObs = try await tool.perform(.navigate(url: "\(server.baseURL)/404"), sessionID: sid, timeoutSeconds: 30)
        let ocrText = notFoundObs.ocrLines.map(\.text).joined(separator: " ")
        #expect(ocrText.contains("404 HARBOR MISSING"))

        await tool.closeSession(sid)
    }

    @Test("8. /slow endpoint deadline timeout and task cancellation clean up Chrome process group, profile dir, and artifact dir")
    func slowEndpointTimeoutKillsProcessGroupZeroOrphans() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let tmpDir = FileManager.default.temporaryDirectory
        let baselineDirs = tempHelmEntries(prefixes: ["helm_chrome_", "helm_browser_artifacts_"])

        // 8a. Deadline timeout path
        let sid = try await tool.openSession(projectID: UUID())
        let chromeDir = tmpDir.appendingPathComponent("helm_chrome_\(sid.uuidString)")
        let artifactDir = tmpDir.appendingPathComponent("helm_browser_artifacts_\(sid.uuidString)")

        let start = ContinuousClock.now
        do {
            _ = try await tool.perform(.navigate(url: "\(server.baseURL)/slow?delay=6"), sessionID: sid, timeoutSeconds: 2.0)
            Issue.record("Expected timeout error on /slow?delay=6 with 2s timeout")
        } catch let error as HelmBrowserError {
            if case .timeout = error {
                // expected
            } else {
                Issue.record("Expected HelmBrowserError.timeout, got \(error)")
            }
        }
        let elapsed = ContinuousClock.now - start
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(elapsedSec < 5.5)

        await tool.closeSession(sid)
        try? await Task.sleep(for: .milliseconds(250))
        let leftoverPIDs = chromeProcessesMatching(sessionID: sid)
        #expect(leftoverPIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: chromeDir.path))
        #expect(!FileManager.default.fileExists(atPath: artifactDir.path))

        // 8b. External Task cancellation path
        let sidCancel = try await tool.openSession(projectID: UUID())
        let cancelChromeDir = tmpDir.appendingPathComponent("helm_chrome_\(sidCancel.uuidString)")
        let cancelArtifactDir = tmpDir.appendingPathComponent("helm_browser_artifacts_\(sidCancel.uuidString)")

        let navTask = Task {
            try await tool.perform(.navigate(url: "\(server.baseURL)/slow?delay=6"), sessionID: sidCancel, timeoutSeconds: 30.0)
        }
        try await Task.sleep(for: .milliseconds(600))
        navTask.cancel()
        do {
            _ = try await navTask.value
            Issue.record("Expected CancellationError when cancelling perform task")
        } catch is CancellationError {
            // expected
        }
        await tool.closeSession(sidCancel)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(chromeProcessesMatching(sessionID: sidCancel).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cancelChromeDir.path))
        #expect(!FileManager.default.fileExists(atPath: cancelArtifactDir.path))

        let postDirs = tempHelmEntries(prefixes: ["helm_chrome_", "helm_browser_artifacts_"])
        #expect(postDirs.subtracting(baselineDirs).isEmpty)
    }

    @Test("9. Headless Chrome + OCR never moves host cursor or changes NSWorkspace frontmostApplication")
    func hostCursorAndFocusInvariance() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }

        let beforeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let beforeBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let beforeCursor = CGEvent(source: nil)?.location

        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())
        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/form"), sessionID: sid, timeoutSeconds: 30)
        _ = try await tool.perform(.typeText(selectorOrOCR: "code", text: "INV1", submit: false), sessionID: sid, timeoutSeconds: 30)
        _ = try await tool.perform(.clickOCRText(query: "SUBMIT ORDER"), sessionID: sid, timeoutSeconds: 30)
        await tool.closeSession(sid)

        let afterAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let afterBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let afterCursor = CGEvent(source: nil)?.location

        #expect(beforeAppPID == afterAppPID)
        #expect(beforeBundle == afterBundle)
        if let b = beforeCursor, let a = afterCursor {
            #expect(abs(b.x - a.x) < 0.001)
            #expect(abs(b.y - a.y) < 0.001)
        }
    }

    @Test("10. helmctl browser act CLI handles repeated --type, --click-ocr, plain screenshotPNGPath, passkeyRejected, and non-zero failure exits")
    func helmctlBrowserActCLIContract() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/helmctl"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/helmctl"),
        ]
        let helmctlURL = try #require(
            candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
            "Expected built helmctl binary at \(candidates.map(\.path).joined(separator: " or "))"
        )

        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HelmBrowserCLI_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func runCLI(_ args: [String]) throws -> (code: Int32, stdout: String, stderr: String) {
            let proc = Process()
            proc.executableURL = helmctlURL
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (proc.terminationStatus, stdout, stderr)
        }

        // 1. Repeated --type + --click-ocr + --screenshot-out
        let shotURL = tempDir.appendingPathComponent("form_submit.png")
        let formRes = try runCLI([
            "browser", "act",
            "--url", "\(server.baseURL)/form",
            "--type", "code=CLI77",
            "--type", "note=ORDERED",
            "--click-ocr", "SUBMIT ORDER",
            "--screenshot-out", shotURL.path,
        ])
        #expect(formRes.code == 0)
        let cliObs = try HelmJSON.makeDecoder().decode(BrowserObservationCLIOutput.self, from: Data(formRes.stdout.utf8))
        #expect(cliObs.url.contains("/result"))
        #expect(cliObs.trustTag == .untrustedData)
        #expect(cliObs.passkeyRejected == false)
        #expect(!cliObs.screenshotPNGPath.hasPrefix("file://"))
        #expect(cliObs.screenshotPNGPath == shotURL.path)
        #expect(FileManager.default.fileExists(atPath: shotURL.path))
        let ocrJoined = cliObs.ocrLines.map(\.text).joined(separator: " ")
        #expect(ocrJoined.contains("ORDER CONFIRMED"))
        #expect(ocrJoined.contains("CLI77"))
        #expect(ocrJoined.contains("ORDERED"))

        // 2. /passkey emits passkeyRejected == true
        let passkeyRes = try runCLI([
            "browser", "act",
            "--url", "\(server.baseURL)/passkey",
        ])
        #expect(passkeyRes.code == 0)
        let passkeyObs = try HelmJSON.makeDecoder().decode(BrowserObservationCLIOutput.self, from: Data(passkeyRes.stdout.utf8))
        #expect(passkeyObs.passkeyRejected == true)
        #expect(passkeyObs.trustTag == .untrustedData)
        #expect(passkeyObs.ocrLines.map(\.text).joined(separator: " ").contains("PASSKEY_REFUSED_CLEANLY"))
        try? FileManager.default.removeItem(atPath: passkeyObs.screenshotPNGPath)

        let preErrorEntries = tempHelmEntries(prefixes: ["helm_chrome_", "helm_browser_artifacts_", "helm_browser_shot_"])

        // 3. Missing OCR target exits non-zero (not 0 or 69) with JSON error on stderr
        let missingRes = try runCLI([
            "browser", "act",
            "--url", "\(server.baseURL)/offscale",
            "--click-ocr", "NONEXISTENT_BUTTON_XYZ",
        ])
        #expect(missingRes.code != 0 && missingRes.code != 69)
        #expect(missingRes.stderr.contains("error"))

        // 4. /slow?delay=6 with --timeout 2 exits non-zero < 6s
        let start = ContinuousClock.now
        let slowRes = try runCLI([
            "browser", "act",
            "--url", "\(server.baseURL)/slow?delay=6",
            "--timeout", "2",
        ])
        let elapsed = ContinuousClock.now - start
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(slowRes.code != 0 && slowRes.code != 69)
        #expect(elapsedSec < 5.5)
        #expect(slowRes.stderr.contains("error"))

        // 5. Tight mid-launch/mid-flight timeout without --screenshot-out must not leak helm_browser_shot_*.png or temp dirs
        for _ in 0..<3 {
            let tightRes = try runCLI([
                "browser", "act",
                "--url", "\(server.baseURL)/slow?delay=6",
                "--timeout", "0.4",
            ])
            #expect(tightRes.code != 0 && tightRes.code != 69)
            #expect(tightRes.stderr.contains("error"))
        }

        let postErrorEntries = tempHelmEntries(prefixes: ["helm_chrome_", "helm_browser_artifacts_", "helm_browser_shot_"])
        #expect(postErrorEntries.subtracting(preErrorEntries).isEmpty)
    }

    @Test("11. typeText with submit: true submits /form, /form-nobutton, and /form-spa (preventDefault) exactly once per call")
    func typeTextWithSubmitTrueSubmitsForm() async throws {
        let server = try await LocalBrowserFixtureServer.start()
        defer { server.stop() }
        let tool = BrowseReadActTool()
        let sid = try await tool.openSession(projectID: UUID())
        let tmpDir = FileManager.default.temporaryDirectory

        // 11a. Standard GET form submission
        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/form"), sessionID: sid, timeoutSeconds: 30)
        _ = try await tool.perform(.typeText(selectorOrOCR: "code", text: "SUB99", submit: false), sessionID: sid, timeoutSeconds: 30)
        let resultObs = try await tool.perform(.typeText(selectorOrOCR: "note", text: "ENTER_OK", submit: true), sessionID: sid, timeoutSeconds: 30)

        #expect(resultObs.url.contains("/result"))
        let ocrText = resultObs.ocrLines.map(\.text).joined(separator: " ")
        #expect(ocrText.contains("ORDER CONFIRMED"))
        #expect(ocrText.contains("SUB99"))
        #expect(ocrText.contains("ENTER_OK"))

        // 11b. Buttonless multi-input form fallback (requestSubmit)
        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/form-nobutton"), sessionID: sid, timeoutSeconds: 30)
        _ = try await tool.perform(.typeText(selectorOrOCR: "code", text: "NB77", submit: false), sessionID: sid, timeoutSeconds: 30)
        let nbResultObs = try await tool.perform(.typeText(selectorOrOCR: "note", text: "FALLBACK_OK", submit: true), sessionID: sid, timeoutSeconds: 30)
        #expect(nbResultObs.url.contains("/result"))
        let nbOCRText = nbResultObs.ocrLines.map(\.text).joined(separator: " ")
        #expect(nbOCRText.contains("ORDER CONFIRMED"))
        #expect(nbOCRText.contains("NB77"))
        #expect(nbOCRText.contains("FALLBACK_OK"))

        // 11c. SPA preventDefault() form must submit exactly once per typeText(..., submit: true)
        _ = try await tool.perform(.navigate(url: "\(server.baseURL)/form-spa"), sessionID: sid, timeoutSeconds: 30)
        let spaObs1 = try await tool.perform(.typeText(selectorOrOCR: "q", text: "HELLO_SPA", submit: true), sessionID: sid, timeoutSeconds: 30)
        #expect(spaObs1.url.hasSuffix("/form-spa"))
        let spaCheck1 = try await tool.performDetailed(
            .evaluateJS(script: "document.getElementById('spa-out').textContent + '|CLEAN=' + (!('__helmSawFormSubmit' in window) && !('__helmSubmitCleanup' in window))"),
            sessionID: sid,
            timeoutSeconds: 30
        )
        #expect(spaCheck1.evalResult == "CNT=1|VAL=HELLO_SPA|CLEAN=true")

        // Second submission on the same SPA form must increment once more to CNT=2
        let spaObs2 = try await tool.perform(.typeText(selectorOrOCR: "q", text: "HELLO_TWO", submit: true), sessionID: sid, timeoutSeconds: 30)
        #expect(spaObs2.url.hasSuffix("/form-spa"))
        let spaCheck2 = try await tool.performDetailed(
            .evaluateJS(script: "document.getElementById('spa-out').textContent + '|CLEAN=' + (!('__helmSawFormSubmit' in window) && !('__helmSubmitCleanup' in window))"),
            sessionID: sid,
            timeoutSeconds: 30
        )
        #expect(spaCheck2.evalResult == "CNT=2|VAL=HELLO_TWO|CLEAN=true")

        await tool.closeSession(sid)
        #expect(!FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("helm_chrome_\(sid.uuidString)").path))
        #expect(!FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("helm_browser_artifacts_\(sid.uuidString)").path))
    }
}
