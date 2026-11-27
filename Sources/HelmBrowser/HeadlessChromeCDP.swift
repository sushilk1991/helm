import CoreGraphics
import Darwin
import Foundation
import HelmCore
import os

// MARK: - Lightweight Sendable JSON Value for Swift 6 CDP Messaging

enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
        } else if let objectVal = try? container.decode([String: JSONValue].self) {
            self = .object(objectVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self {
            return dict[key]
        }
        return nil
    }

    var displayString: String? {
        switch self {
        case .null: return nil
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

private struct CDPRequestPayload: Encodable, Sendable {
    let id: Int
    let method: String
    let params: [String: JSONValue]
}

// MARK: - Snapshot & Hit-Test Models

struct CDPSnapshotState: Sendable {
    let url: String
    let title: String
    let viewportSize: CGSize
    let pngData: Data
    let domElements: [DOMInteractiveElement]
    let passkeyRejected: Bool
}

public struct HitTestResult: Sendable, Equatable {
    public let found: Bool
    public let tagName: String?
    public let elementID: String?
    public let isInteractive: Bool

    public init(found: Bool, tagName: String?, elementID: String?, isInteractive: Bool) {
        self.found = found
        self.tagName = tagName
        self.elementID = elementID
        self.isInteractive = isInteractive
    }
}

// MARK: - Thread-Safe Continuation Store (Avoids actor-isolation races in withCheckedThrowingContinuation)

private final class CDPContinuationStore: @unchecked Sendable {
    private struct State {
        var commands: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var cancelledCommandIDs: Set<Int> = []
        var loadWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var cancelledLoadWaiterIDs: Set<UUID> = []
        var closedError: Error?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func registerCommand(id: Int, continuation: CheckedContinuation<JSONValue, Error>) -> Bool {
        let immediateError = lock.withLock { state -> Error? in
            if state.cancelledCommandIDs.remove(id) != nil {
                return CancellationError()
            }
            if let closedError = state.closedError {
                return closedError
            }
            state.commands[id] = continuation
            return nil
        }
        if let immediateError {
            continuation.resume(throwing: immediateError)
            return false
        }
        return true
    }

    func completeCommand(id: Int, result: Result<JSONValue, Error>) {
        let cont = lock.withLock { $0.commands.removeValue(forKey: id) }
        cont?.resume(with: result)
    }

    func cancelCommand(id: Int) {
        let cont = lock.withLock { state -> CheckedContinuation<JSONValue, Error>? in
            if let existing = state.commands.removeValue(forKey: id) {
                return existing
            }
            if state.closedError == nil {
                state.cancelledCommandIDs.insert(id)
            }
            return nil
        }
        cont?.resume(throwing: CancellationError())
    }

    func clearCancelledCommand(id: Int) {
        _ = lock.withLock { $0.cancelledCommandIDs.remove(id) }
    }

    func registerLoadWaiter(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        let immediateError = lock.withLock { state -> Error? in
            if state.cancelledLoadWaiterIDs.remove(id) != nil {
                return CancellationError()
            }
            if let closedError = state.closedError {
                return closedError
            }
            state.loadWaiters[id] = continuation
            return nil
        }
        if let immediateError {
            continuation.resume(throwing: immediateError)
        }
    }

    func completeAllLoadWaiters() {
        let waiters = lock.withLock { state -> [CheckedContinuation<Void, Error>] in
            let vals = Array(state.loadWaiters.values)
            state.loadWaiters.removeAll()
            return vals
        }
        for cont in waiters {
            cont.resume(returning: ())
        }
    }

    func failLoadWaiter(id: UUID, error: Error) {
        let cont = lock.withLock { $0.loadWaiters.removeValue(forKey: id) }
        cont?.resume(throwing: error)
    }

    func cancelLoadWaiter(id: UUID) {
        let cont = lock.withLock { state -> CheckedContinuation<Void, Error>? in
            if let existing = state.loadWaiters.removeValue(forKey: id) {
                return existing
            }
            if state.closedError == nil {
                state.cancelledLoadWaiterIDs.insert(id)
            }
            return nil
        }
        cont?.resume(throwing: CancellationError())
    }

    func clearCancelledLoadWaiter(id: UUID) {
        _ = lock.withLock { $0.cancelledLoadWaiterIDs.remove(id) }
    }

    func failAllAndClose(error: Error, markClosed: Bool) {
        let (cmds, waiters) = lock.withLock { state -> ([CheckedContinuation<JSONValue, Error>], [CheckedContinuation<Void, Error>]) in
            if markClosed {
                state.closedError = error
                state.cancelledCommandIDs.removeAll()
                state.cancelledLoadWaiterIDs.removeAll()
            }
            let c = Array(state.commands.values)
            let w = Array(state.loadWaiters.values)
            state.commands.removeAll()
            state.loadWaiters.removeAll()
            return (c, w)
        }
        for cont in cmds {
            cont.resume(throwing: error)
        }
        for cont in waiters {
            cont.resume(throwing: error)
        }
    }
}

// MARK: - Process-Group & Temp-Profile Guard

private final class ChromeProcessBox: @unchecked Sendable {
    struct State {
        var process: Process?
        var pgid: pid_t = 0
        var profileDir: URL
        var stderrData = Data()
        var stderrHandle: FileHandle?
        var terminated = false
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(profileDir: URL) {
        self.lock = OSAllocatedUnfairLock(initialState: State(profileDir: profileDir))
    }

    deinit {
        terminateAndCleanupSync()
    }

    func attach(process: Process, pgid: pid_t, stderrHandle: FileHandle) {
        lock.withLock { state in
            state.process = process
            state.pgid = pgid
            state.stderrHandle = stderrHandle
        }
        stderrHandle.readabilityHandler = { [lock] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                lock.withLock { $0.stderrData.append(chunk) }
            } else {
                handle.readabilityHandler = nil
            }
        }
    }

    func stderrString() -> String {
        let data = lock.withLock { $0.stderrData }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func isProcessRunning() -> Bool {
        lock.withLock { $0.process?.isRunning ?? false }
    }

    func terminationStatus() -> Int32? {
        lock.withLock { state in
            guard let proc = state.process, !proc.isRunning else { return nil }
            return proc.terminationStatus
        }
    }

    func terminateAndCleanupSync() {
        let snapshot = lock.withLock { state -> (Process?, pid_t, URL, FileHandle?, Bool) in
            let wasTerminated = state.terminated
            state.terminated = true
            let handle = state.stderrHandle
            state.stderrHandle = nil
            return (state.process, state.pgid, state.profileDir, handle, wasTerminated)
        }

        snapshot.3?.readabilityHandler = nil
        if snapshot.4 { return }

        if let proc = snapshot.0 {
            let pid = proc.processIdentifier
            let pgid = snapshot.1 > 0 ? snapshot.1 : pid
            if proc.isRunning {
                if pgid > 0 {
                    _ = Darwin.kill(-pgid, SIGTERM)
                }
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGTERM)
                }
                let deadline = Date().addingTimeInterval(0.25)
                while proc.isRunning && Date() < deadline {
                    usleep(15_000)
                }
                if proc.isRunning {
                    if pgid > 0 {
                        _ = Darwin.kill(-pgid, SIGKILL)
                    }
                    if pid > 0 {
                        _ = Darwin.kill(pid, SIGKILL)
                    }
                }
            }
            if proc.isRunning {
                proc.waitUntilExit()
            }
        }

        try? FileManager.default.removeItem(at: snapshot.2)
    }
}

// MARK: - HeadlessChromeCDP

public actor HeadlessChromeCDP {
    public static let defaultChromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    public static let defaultViewportSize = CGSize(width: 1280, height: 800)
    private static let maxDOMElements = 200

    public let sessionID: UUID
    public private(set) var devToolsPort: Int = 0

    private let chromeExecutableURL: URL
    private let profileDir: URL
    private let processBox: ChromeProcessBox

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?

    private var nextCommandID: Int = 0
    private let continuationStore = CDPContinuationStore()
    private var loadGeneration: Int = 0
    private var frameStartedGeneration: Int = 0
    private var isClosed = false

    public init(sessionID: UUID = UUID(), chromePath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.sessionID = sessionID
        let resolvedPath = Self.resolveChromePath(override: chromePath, environment: environment)
        guard FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            throw HelmBrowserError.chromeNotFound(resolvedPath)
        }
        self.chromeExecutableURL = URL(fileURLWithPath: resolvedPath)
        self.profileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm_chrome_\(sessionID.uuidString)", isDirectory: true)
        self.processBox = ChromeProcessBox(profileDir: profileDir)
    }

    deinit {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        readerTask?.cancel()
        processBox.terminateAndCleanupSync()
    }

    public static func resolveChromePath(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        if let envPath = environment["HELM_CHROME_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            return envPath
        }
        return defaultChromePath
    }

    public func start(timeoutSeconds: TimeInterval = 30.0) async throws {
        guard !isClosed else {
            throw HelmBrowserError.sessionNotFound(sessionID)
        }
        if webSocketTask != nil {
            return
        }

        let deadline = ContinuousClock.now + .seconds(max(1.0, timeoutSeconds))
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = chromeExecutableURL
        process.arguments = [
            "--headless=new",
            "--remote-debugging-port=0",
            "--user-data-dir=\(profileDir.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-sync",
            "--disable-extensions",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-popup-blocking",
            "--disable-notifications",
            "--mute-audio",
            "--password-store=basic",
            "--use-mock-keychain",
            "--disable-features=WebAuthentication,WebAuthnRemoteDesktopSupport",
            "--window-size=1280,800",
            "about:blank",
        ]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            processBox.terminateAndCleanupSync()
            throw HelmBrowserError.cdpLaunchFailed("Unable to run Chrome: \(error.localizedDescription)")
        }

        let pid = process.processIdentifier
        if pid > 0 {
            _ = Darwin.setpgid(pid, pid)
        }
        processBox.attach(process: process, pgid: pid, stderrHandle: stderrPipe.fileHandleForReading)

        do {
            let port = try await waitForEphemeralPort(deadline: deadline)
            guard port > 0, port != 9222 else {
                throw HelmBrowserError.cdpLaunchFailed("Refusing invalid or reserved DevTools port \(port).")
            }
            self.devToolsPort = port

            let session = URLSession(configuration: .ephemeral)
            self.urlSession = session

            let pageWSURL = try await discoverPageWebSocketURL(port: port, session: session, deadline: deadline)
            if pageWSURL.port == 9222 {
                throw HelmBrowserError.cdpLaunchFailed("Refusing connection to reserved port 9222.")
            }

            let wsTask = session.webSocketTask(with: pageWSURL)
            wsTask.maximumMessageSize = 32 * 1024 * 1024
            wsTask.resume()
            self.webSocketTask = wsTask

            self.readerTask = Task { [weak self] in
                await self?.receiveLoop(wsTask: wsTask)
            }

            _ = try await sendCDP("Page.enable")
            _ = try await sendCDP("Runtime.enable")
            _ = try await sendCDP("DOM.enable")
            _ = try await sendCDP("Emulation.setDeviceMetricsOverride", params: [
                "width": .int(Int(Self.defaultViewportSize.width)),
                "height": .int(Int(Self.defaultViewportSize.height)),
                "deviceScaleFactor": .int(1),
                "mobile": .bool(false),
            ])
            _ = try await sendCDP("Page.addScriptToEvaluateOnNewDocument", params: [
                "source": .string(Self.passkeySuppressorScript),
            ])
        } catch {
            await terminate()
            throw error
        }
    }

    public func navigate(url: String) async throws {
        guard !isClosed else { throw HelmBrowserError.sessionNotFound(sessionID) }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https", "about", "data"].contains(scheme)
        else {
            throw HelmBrowserError.invalidArgument("Unsupported or malformed URL '\(url)'.")
        }
        if parsed.port == 9222 {
            throw HelmBrowserError.invalidArgument("Refusing navigation to reserved port 9222.")
        }

        let startGen = loadGeneration
        let result = try await sendCDP("Page.navigate", params: ["url": .string(url)])
        if let errorText = result["errorText"]?.stringValue, !errorText.isEmpty {
            throw HelmBrowserError.cdpProtocolError("Navigation failed for '\(url)': \(errorText)")
        }

        if loadGeneration == startGen {
            let ready = try await evaluateReadyState()
            if ready != "complete" && loadGeneration == startGen {
                try await waitForLoadGeneration(greaterThan: startGen)
            }
        }
        try await settlePaintAndMicrotasks()
    }

    public func clickCSS(x: Double, y: Double) async throws {
        guard !isClosed else { throw HelmBrowserError.sessionNotFound(sessionID) }
        guard x.isFinite, y.isFinite,
              x >= 0, x <= Self.defaultViewportSize.width,
              y >= 0, y <= Self.defaultViewportSize.height
        else {
            throw HelmBrowserError.invalidArgument("CSS coordinates (\(x), \(y)) are out of bounds.")
        }

        let hit = try await hitTestElement(x: x, y: y)
        guard hit.found else {
            throw HelmBrowserError.elementNotInteractive(x: x, y: y, tagName: nil)
        }

        let preURL = try await currentDocumentURL()
        let preLoadGen = loadGeneration
        let preFrameGen = frameStartedGeneration

        try await dispatchClick(x: x, y: y)
        try await waitForPostActionSettle(preURL: preURL, preLoadGen: preLoadGen, preFrameGen: preFrameGen)
    }

    public func hitTestElement(x: Double, y: Double) async throws -> HitTestResult {
        let js = """
        ((x, y) => {
          const el = document.elementFromPoint(x, y);
          if (!el) return { found: false, tagName: null, id: null, isInteractive: false };
          const interactive = el.closest('a,button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[onclick],[tabindex]');
          const target = interactive || el;
          const tag = (target.tagName || '').toLowerCase();
          return {
            found: true,
            tagName: tag,
            id: target.id || null,
            isInteractive: Boolean(interactive) || ['a','button','input','select','textarea','label','option'].includes(tag)
          };
        })(\(x), \(y));
        """
        let value = try await evaluateRawJS(js)
        let found = value["found"]?.boolValue ?? false
        let tagName = value["tagName"]?.stringValue
        let id = value["id"]?.stringValue
        let isInteractive = value["isInteractive"]?.boolValue ?? false
        return HitTestResult(found: found, tagName: tagName, elementID: id, isInteractive: isInteractive)
    }

    public func typeText(
        selectorOrOCR: String,
        text: String,
        submit: Bool,
        ocrLines: [OCRLine]
    ) async throws {
        guard !isClosed else { throw HelmBrowserError.sessionNotFound(sessionID) }
        let trimmedTarget = selectorOrOCR.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            throw HelmBrowserError.invalidArgument("typeText target selector/label cannot be empty.")
        }

        let targetJSON = try encodeStringLiteral(trimmedTarget)
        let resolveJS = """
        ((target) => {
          const interactiveSelector = 'a[href],button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[onclick],[tabindex]:not([tabindex="-1"])';
          const inputSelector = 'input,textarea,select,[contenteditable="true"],[contenteditable=""]';
          const isTypeable = (el) => {
            if (!el) return false;
            const tag = (el.tagName || '').toLowerCase();
            if (tag === 'textarea' || tag === 'select') return true;
            if (tag === 'input') {
              const t = (el.getAttribute('type') || 'text').toLowerCase();
              return !['hidden','submit','button','reset','image'].includes(t);
            }
            return el.isContentEditable === true;
          };
          const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
          const tNorm = norm(target);

          let el = null;
          if (/^@e\\d+$/.test(target)) {
            const idx = parseInt(target.slice(2), 10) - 1;
            const all = Array.from(document.querySelectorAll(interactiveSelector)).filter((node) => {
              const r = node.getBoundingClientRect();
              const st = getComputedStyle(node);
              return r.width > 0 && r.height > 0 && st.display !== 'none' && st.visibility !== 'hidden';
            });
            if (idx >= 0 && idx < all.length) el = all[idx];
          }
          if (!el) {
            const byId = document.getElementById(target);
            if (isTypeable(byId)) el = byId;
          }
          if (!el) {
            const safeAttr = target.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"');
            const byName = document.querySelector(`[name="${safeAttr}"]`);
            if (isTypeable(byName)) el = byName;
          }
          if (!el) {
            try {
              const bySel = document.querySelector(target);
              if (isTypeable(bySel)) el = bySel;
            } catch (_) {}
          }
          if (!el) {
            const labels = Array.from(document.querySelectorAll('label'));
            for (const lbl of labels) {
              if (norm(lbl.innerText) === tNorm) {
                const ctrl = lbl.control || (lbl.htmlFor ? document.getElementById(lbl.htmlFor) : null) || lbl.querySelector(inputSelector);
                if (isTypeable(ctrl)) { el = ctrl; break; }
              }
            }
            if (!el) {
              for (const lbl of labels) {
                if (norm(lbl.innerText).includes(tNorm)) {
                  const ctrl = lbl.control || (lbl.htmlFor ? document.getElementById(lbl.htmlFor) : null) || lbl.querySelector(inputSelector);
                  if (isTypeable(ctrl)) { el = ctrl; break; }
                }
              }
            }
          }
          if (!el) {
            const inputs = Array.from(document.querySelectorAll(inputSelector)).filter(isTypeable);
            el = inputs.find((inp) =>
              norm(inp.getAttribute('placeholder')) === tNorm ||
              norm(inp.getAttribute('aria-label')) === tNorm ||
              norm(inp.getAttribute('name')) === tNorm ||
              norm(inp.id) === tNorm
            ) || inputs.find((inp) =>
              norm(inp.getAttribute('placeholder')).includes(tNorm) ||
              norm(inp.getAttribute('aria-label')).includes(tNorm)
            ) || null;
          }
          if (!el) return { found: false };
          el.scrollIntoView({ block: 'center', inline: 'center' });
          const rect = el.getBoundingClientRect();
          return {
            found: true,
            x: rect.left + rect.width / 2,
            y: rect.top + rect.height / 2,
            tagName: (el.tagName || '').toLowerCase()
          };
        })(\(targetJSON));
        """

        var resolved = try await evaluateRawJS(resolveJS)
        if !(resolved["found"]?.boolValue ?? false),
           let ocrMatch = VisionOCRService.matchOCRLine(query: trimmedTarget, in: ocrLines) {
            let pt = CoordinateMapper.centerPoint(of: ocrMatch.cssRect, clampedTo: Self.defaultViewportSize)
            let ocrResolveJS = """
            ((ox, oy) => {
              const hit = document.elementFromPoint(ox, oy);
              const isTypeable = (el) => el && (['textarea','select'].includes((el.tagName||'').toLowerCase()) || ((el.tagName||'').toLowerCase()==='input' && !['hidden','submit','button'].includes((el.type||'text').toLowerCase())) || el.isContentEditable);
              let el = isTypeable(hit) ? hit : null;
              if (!el && hit && hit.closest) {
                const lbl = hit.closest('label');
                if (lbl) el = lbl.control || (lbl.htmlFor ? document.getElementById(lbl.htmlFor) : null) || lbl.querySelector('input,textarea,select');
              }
              if (!el) {
                let bestDist = Infinity;
                for (const inp of document.querySelectorAll('input,textarea,select')) {
                  if (!isTypeable(inp)) continue;
                  const r = inp.getBoundingClientRect();
                  if (r.width <= 0 || r.height <= 0) continue;
                  const dx = (r.left + r.width / 2) - ox;
                  const dy = (r.top + r.height / 2) - oy;
                  const dist = Math.hypot(dx, dy);
                  if (dist < bestDist) { bestDist = dist; el = inp; }
                }
              }
              if (!el) return { found: false };
              el.scrollIntoView({ block: 'center', inline: 'center' });
              const rect = el.getBoundingClientRect();
              return { found: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, tagName: (el.tagName || '').toLowerCase() };
            })(\(pt.x), \(pt.y));
            """
            resolved = try await evaluateRawJS(ocrResolveJS)
        }

        guard resolved["found"]?.boolValue == true,
              let clickX = resolved["x"]?.doubleValue,
              let clickY = resolved["y"]?.doubleValue
        else {
            throw HelmBrowserError.ocrTargetNotFound(
                query: trimmedTarget,
                availableTexts: ocrLines.map(\.text)
            )
        }

        let clampedX = max(0.0, min(Self.defaultViewportSize.width, clickX))
        let clampedY = max(0.0, min(Self.defaultViewportSize.height, clickY))
        try await dispatchClick(x: clampedX, y: clampedY)

        // Focus & clear existing value cleanly on the active element
        _ = try await evaluateRawJS("""
        (() => {
          const el = document.activeElement;
          if (!el) return false;
          if ('value' in el && typeof el.value === 'string') {
            el.value = '';
          } else if (el.isContentEditable) {
            el.textContent = '';
          }
          return true;
        })();
        """)

        _ = try await sendCDP("Input.insertText", params: ["text": .string(text)])

        // Ensure value matches and input/change events propagate for non-text inputs/forms
        let textLiteral = try encodeStringLiteral(text)
        _ = try await evaluateRawJS("""
        ((expected) => {
          const el = document.activeElement;
          if (!el) return false;
          if ('value' in el && el.value !== expected) {
            el.value = expected;
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })(\(textLiteral));
        """)

        if submit {
            let preURL = try await currentDocumentURL()
            let preLoadGen = loadGeneration
            let preFrameGen = frameStartedGeneration

            _ = try? await evaluateRawJS("""
            (() => {
              if (typeof window.__helmSubmitCleanup === 'function') {
                window.__helmSubmitCleanup();
              }
              window.__helmSawFormSubmit = false;
              const onSubmit = () => {
                window.__helmSawFormSubmit = true;
              };
              window.addEventListener('submit', onSubmit, { capture: true, once: true });
              window.__helmSubmitCleanup = () => {
                window.removeEventListener('submit', onSubmit, { capture: true });
                delete window.__helmSawFormSubmit;
                delete window.__helmSubmitCleanup;
              };
              return true;
            })();
            """)

            _ = try await sendCDP("Input.dispatchKeyEvent", params: [
                "type": .string("keyDown"),
                "key": .string("Enter"),
                "code": .string("Enter"),
                "windowsVirtualKeyCode": .int(13),
                "nativeVirtualKeyCode": .int(13),
                "text": .string("\r"),
            ])
            _ = try await sendCDP("Input.dispatchKeyEvent", params: [
                "type": .string("keyUp"),
                "key": .string("Enter"),
                "code": .string("Enter"),
                "windowsVirtualKeyCode": .int(13),
                "nativeVirtualKeyCode": .int(13),
            ])

            try? await Task.sleep(for: .milliseconds(60))
            if frameStartedGeneration == preFrameGen && loadGeneration == preLoadGen {
                _ = try? await evaluateRawJS("""
                (() => {
                  const sawSubmit = Boolean(window.__helmSawFormSubmit);
                  if (typeof window.__helmSubmitCleanup === 'function') {
                    window.__helmSubmitCleanup();
                  } else {
                    delete window.__helmSawFormSubmit;
                  }
                  if (sawSubmit) {
                    return false;
                  }
                  const el = document.activeElement;
                  const form = el && el.form ? el.form : document.querySelector('form');
                  if (form) {
                    if (typeof form.requestSubmit === 'function') form.requestSubmit();
                    else form.submit();
                    return true;
                  }
                  return false;
                })();
                """)
                try await waitForPostActionSettle(preURL: preURL, preLoadGen: preLoadGen, preFrameGen: preFrameGen)
            } else {
                try await waitForPostActionSettle(preURL: preURL, preLoadGen: preLoadGen, preFrameGen: preFrameGen)
                _ = try? await evaluateRawJS("""
                (() => {
                  if (typeof window.__helmSubmitCleanup === 'function') {
                    window.__helmSubmitCleanup();
                  } else if ('__helmSawFormSubmit' in window) {
                    delete window.__helmSawFormSubmit;
                  }
                })();
                """)
            }
        } else {
            try await settlePaintAndMicrotasks()
        }
    }

    public func evaluateJS(script: String) async throws -> String? {
        guard !isClosed else { throw HelmBrowserError.sessionNotFound(sessionID) }
        let preURL = try await currentDocumentURL()
        let preLoadGen = loadGeneration
        let preFrameGen = frameStartedGeneration

        let result = try await sendCDP("Runtime.evaluate", params: [
            "expression": .string(script),
            "awaitPromise": .bool(true),
            "returnByValue": .bool(true),
        ])
        if let exception = result["exceptionDetails"] {
            let msg = exception["exception"]?["description"]?.stringValue
                ?? exception["text"]?.stringValue
                ?? "JavaScript evaluation error"
            throw HelmBrowserError.cdpProtocolError(msg)
        }
        try await waitForPostActionSettle(preURL: preURL, preLoadGen: preLoadGen, preFrameGen: preFrameGen)
        return result["result"]?["value"]?.displayString
    }

    func captureSnapshotState() async throws -> CDPSnapshotState {
        guard !isClosed else { throw HelmBrowserError.sessionNotFound(sessionID) }
        let shotResult = try await sendCDP("Page.captureScreenshot", params: [
            "format": .string("png"),
            "fromSurface": .bool(true),
        ])
        guard let base64 = shotResult["data"]?.stringValue,
              let pngData = Data(base64Encoded: base64)
        else {
            throw HelmBrowserError.cdpProtocolError("Page.captureScreenshot returned missing or invalid PNG base64 data.")
        }

        let metaValue = try await evaluateRawJS(Self.snapshotMetadataJS)
        let url = metaValue["url"]?.stringValue ?? "about:blank"
        let title = metaValue["title"]?.stringValue ?? ""
        let width = metaValue["width"]?.doubleValue ?? Self.defaultViewportSize.width
        let height = metaValue["height"]?.doubleValue ?? Self.defaultViewportSize.height
        let passkeyRejected = metaValue["passkeyRejected"]?.boolValue ?? false

        var domElements: [DOMInteractiveElement] = []
        if let rawElements = metaValue["domElements"]?.arrayValue {
            domElements.reserveCapacity(min(Self.maxDOMElements, rawElements.count))
            for item in rawElements.prefix(Self.maxDOMElements) {
                guard let ref = item["ref"]?.stringValue,
                      let tagName = item["tagName"]?.stringValue
                else { continue }
                let role = item["role"]?.stringValue
                let text = item["text"]?.stringValue ?? ""
                let elementID = item["elementID"]?.stringValue
                let x = item["x"]?.doubleValue ?? 0
                let y = item["y"]?.doubleValue ?? 0
                let w = item["w"]?.doubleValue ?? 0
                let h = item["h"]?.doubleValue ?? 0
                let isInteractive = item["isInteractive"]?.boolValue ?? true
                domElements.append(
                    DOMInteractiveElement(
                        ref: ref,
                        tagName: tagName,
                        role: role,
                        text: text,
                        elementID: elementID,
                        cssRect: CGRect(x: x, y: y, width: w, height: h),
                        isInteractive: isInteractive
                    )
                )
            }
        }

        return CDPSnapshotState(
            url: url,
            title: title,
            viewportSize: CGSize(width: width > 0 ? width : Self.defaultViewportSize.width, height: height > 0 ? height : Self.defaultViewportSize.height),
            pngData: pngData,
            domElements: domElements,
            passkeyRejected: passkeyRejected
        )
    }

    public func terminate() async {
        guard !isClosed else { return }
        isClosed = true

        if let wsTask = webSocketTask {
            let closePayload = #"{"id":999999,"method":"Browser.close","params":{}}"#
            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await wsTask.send(.string(closePayload))
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(120))
                }
                _ = try? await group.next()
                group.cancelAll()
            }
            wsTask.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        readerTask?.cancel()
        readerTask = nil

        continuationStore.failAllAndClose(error: HelmBrowserError.sessionNotFound(sessionID), markClosed: true)
        processBox.terminateAndCleanupSync()
    }

    // MARK: - Private CDP Transport

    private func sendCDP(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard !isClosed, let wsTask = webSocketTask else {
            throw HelmBrowserError.sessionNotFound(sessionID)
        }

        nextCommandID += 1
        let commandID = nextCommandID
        let payload = CDPRequestPayload(id: commandID, method: method, params: params)
        let encoded = try JSONEncoder().encode(payload)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw HelmBrowserError.cdpProtocolError("Failed to encode CDP request '\(method)'.")
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        let store = self.continuationStore
        defer { store.clearCancelledCommand(id: commandID) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard store.registerCommand(id: commandID, continuation: continuation) else {
                    return
                }
                Task {
                    do {
                        try await wsTask.send(.string(text))
                    } catch {
                        store.completeCommand(
                            id: commandID,
                            result: .failure(HelmBrowserError.cdpProtocolError("WebSocket send failed for '\(method)': \(error.localizedDescription)"))
                        )
                    }
                }
            }
        } onCancel: {
            store.cancelCommand(id: commandID)
        }
    }

    private func receiveLoop(wsTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled && !isClosed {
            do {
                let message = try await wsTask.receive()
                let data: Data
                switch message {
                case .string(let str):
                    data = Data(str.utf8)
                case .data(let d):
                    data = d
                @unknown default:
                    continue
                }
                guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    continue
                }
                handleIncomingCDPMessage(root)
            } catch {
                if !isClosed {
                    continuationStore.failAllAndClose(
                        error: HelmBrowserError.cdpProtocolError("CDP WebSocket closed: \(error.localizedDescription)"),
                        markClosed: false
                    )
                }
                break
            }
        }
    }

    private func handleIncomingCDPMessage(_ root: JSONValue) {
        if let id = root["id"]?.intValue {
            if let errorObj = root["error"] {
                let msg = errorObj["message"]?.stringValue ?? "Unknown CDP error"
                continuationStore.completeCommand(id: id, result: .failure(HelmBrowserError.cdpProtocolError(msg)))
            } else {
                continuationStore.completeCommand(id: id, result: .success(root["result"] ?? .object([:])))
            }
            return
        }

        if let method = root["method"]?.stringValue {
            switch method {
            case "Page.frameStartedLoading":
                frameStartedGeneration += 1
            case "Page.loadEventFired":
                loadGeneration += 1
                continuationStore.completeAllLoadWaiters()
            case "Page.javascriptDialogOpening":
                Task { [weak self] in
                    _ = try? await self?.sendCDP("Page.handleJavaScriptDialog", params: ["accept": .bool(false)])
                }
            default:
                break
            }
        }
    }

    private func waitForLoadGeneration(greaterThan targetGen: Int) async throws {
        if loadGeneration > targetGen {
            return
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        let waiterID = UUID()
        let store = self.continuationStore
        defer { store.clearCancelledLoadWaiter(id: waiterID) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                store.registerLoadWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            store.cancelLoadWaiter(id: waiterID)
        }
    }

    private func waitForPostActionSettle(preURL: String, preLoadGen: Int, preFrameGen: Int) async throws {
        try await Task.sleep(for: .milliseconds(80))
        let postURL = (try? await currentDocumentURL()) ?? preURL
        let ready = (try? await evaluateReadyState()) ?? "complete"
        if (frameStartedGeneration > preFrameGen || postURL != preURL || ready != "complete"),
           loadGeneration == preLoadGen,
           ready != "complete" {
            try await waitForLoadGeneration(greaterThan: preLoadGen)
        }
        try await settlePaintAndMicrotasks()
    }

    private func settlePaintAndMicrotasks() async throws {
        _ = try await sendCDP("Runtime.evaluate", params: [
            "expression": .string("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 40))))"),
            "awaitPromise": .bool(true),
            "returnByValue": .bool(true),
        ])
    }

    private func evaluateReadyState() async throws -> String {
        let val = try await evaluateRawJS("document.readyState")
        return val.stringValue ?? "complete"
    }

    private func currentDocumentURL() async throws -> String {
        let val = try await evaluateRawJS("window.location.href")
        return val.stringValue ?? ""
    }

    private func evaluateRawJS(_ expression: String) async throws -> JSONValue {
        let result = try await sendCDP("Runtime.evaluate", params: [
            "expression": .string(expression),
            "awaitPromise": .bool(true),
            "returnByValue": .bool(true),
        ])
        if let exception = result["exceptionDetails"] {
            let msg = exception["exception"]?["description"]?.stringValue
                ?? exception["text"]?.stringValue
                ?? "JS evaluation failed"
            throw HelmBrowserError.cdpProtocolError(msg)
        }
        return result["result"]?["value"] ?? .null
    }

    private func dispatchClick(x: Double, y: Double) async throws {
        _ = try await sendCDP("Input.dispatchMouseEvent", params: [
            "type": .string("mouseMoved"),
            "x": .double(x),
            "y": .double(y),
        ])
        _ = try await sendCDP("Input.dispatchMouseEvent", params: [
            "type": .string("mousePressed"),
            "x": .double(x),
            "y": .double(y),
            "button": .string("left"),
            "clickCount": .int(1),
        ])
        _ = try await sendCDP("Input.dispatchMouseEvent", params: [
            "type": .string("mouseReleased"),
            "x": .double(x),
            "y": .double(y),
            "button": .string("left"),
            "clickCount": .int(1),
        ])
    }

    // MARK: - Chrome Startup Discovery

    private func waitForEphemeralPort(deadline: ContinuousClock.Instant) async throws -> Int {
        let activePortFile = profileDir.appendingPathComponent("DevToolsActivePort")
        let marker = "DevTools listening on ws://127.0.0.1:"

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            if let activeStr = try? String(contentsOf: activePortFile, encoding: .utf8),
               let firstLine = activeStr.split(separator: "\n").first,
               let port = Int(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)),
               port > 0 {
                return port
            }

            let stderr = processBox.stderrString()
            if let range = stderr.range(of: marker) {
                let tail = stderr[range.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                if let port = Int(digits), port > 0 {
                    return port
                }
            }

            if let exitStatus = processBox.terminationStatus() {
                throw HelmBrowserError.cdpLaunchFailed(
                    "Chrome exited prematurely with status \(exitStatus). stderr: \(stderr.prefix(400))"
                )
            }

            try await Task.sleep(for: .milliseconds(20))
        }

        throw HelmBrowserError.cdpLaunchFailed("Timed out waiting for Chrome DevTools ephemeral port.")
    }

    private func discoverPageWebSocketURL(
        port: Int,
        session: URLSession,
        deadline: ContinuousClock.Instant
    ) async throws -> URL {
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw HelmBrowserError.cdpLaunchFailed("Invalid /json/list URL for port \(port).")
        }

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var req = URLRequest(url: listURL)
            req.timeoutInterval = 2.0

            if let (data, response) = try? await session.data(for: req),
               let httpResp = response as? HTTPURLResponse,
               (200..<300).contains(httpResp.statusCode),
               let targets = try? JSONDecoder().decode([JSONValue].self, from: data) {
                for target in targets {
                    guard target["type"]?.stringValue == "page" else { continue }
                    let urlStr = target["url"]?.stringValue ?? ""
                    if urlStr.hasPrefix("chrome://") { continue }
                    if let wsStr = target["webSocketDebuggerUrl"]?.stringValue,
                       let wsURL = URL(string: wsStr) {
                        return wsURL
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(25))
        }

        throw HelmBrowserError.cdpLaunchFailed("Timed out discovering CDP 'page' target on port \(port).")
    }

    private func encodeStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    // MARK: - Injected Scripts

    private static let passkeySuppressorScript = """
    (() => {
      try {
        window.__helmPasskeyRejected = false;
        const rejectPasskey = () => {
          window.__helmPasskeyRejected = true;
          return Promise.reject(new DOMException("Passkeys disabled in HelmBrowser", "NotAllowedError"));
        };
        if (typeof navigator !== "undefined") {
          if (navigator.credentials) {
            try {
              Object.defineProperty(navigator.credentials, "create", { value: rejectPasskey, configurable: true, writable: true });
              Object.defineProperty(navigator.credentials, "get", { value: rejectPasskey, configurable: true, writable: true });
            } catch (_) {
              navigator.credentials.create = rejectPasskey;
              navigator.credentials.get = rejectPasskey;
            }
          } else {
            try {
              Object.defineProperty(navigator, "credentials", {
                value: { create: rejectPasskey, get: rejectPasskey },
                configurable: true
              });
            } catch (_) {}
          }
        }
        if (typeof window.PublicKeyCredential !== "undefined") {
          try {
            window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
            if (typeof window.PublicKeyCredential.isConditionalMediationAvailable === "function") {
              window.PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
            }
          } catch (_) {}
        }
      } catch (_) {}
    })();
    """

    private static let snapshotMetadataJS = """
    (() => {
      const selector = 'a[href],button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[onclick],[tabindex]:not([tabindex="-1"])';
      const nodes = Array.from(document.querySelectorAll(selector));
      const domElements = [];
      for (const el of nodes) {
        if (domElements.length >= \(maxDOMElements)) break;
        const rect = el.getBoundingClientRect();
        const style = window.getComputedStyle(el);
        if (rect.width <= 0 || rect.height <= 0 || style.display === 'none' || style.visibility === 'hidden') {
          continue;
        }
        const tag = (el.tagName || '').toLowerCase();
        const rawText = el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.id || '';
        const text = String(rawText).replace(/\\s+/g, ' ').trim().slice(0, 160);
        domElements.push({
          ref: '@e' + (domElements.length + 1),
          tagName: tag,
          role: el.getAttribute('role') || null,
          text,
          elementID: el.id || null,
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          isInteractive: true
        });
      }
      return {
        url: window.location.href || 'about:blank',
        title: document.title || '',
        width: window.innerWidth || 1280,
        height: window.innerHeight || 800,
        passkeyRejected: Boolean(window.__helmPasskeyRejected),
        domElements
      };
    })();
    """
}
