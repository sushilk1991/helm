import AppKit
import CoreGraphics
import Foundation

struct CursorDelta: Codable {
    let dx: Double
    let dy: Double
    let distance: Double
}

struct ProbeSample: Codable {
    let timestampMs: Int64
    let bundleIdentifier: String?
    let processIdentifier: Int32
    let localizedName: String?
    let cgX: Double
    let cgY: Double
    let nsX: Double
    let nsY: Double
    let cgAvailable: Bool
}

struct ActivationEvent: Codable {
    let timestampMs: Int64
    let bundleIdentifier: String?
    let processIdentifier: Int32
    let localizedName: String?
}

struct ProbeReport: Codable {
    let intervalMs: Int
    let sampleCount: Int
    let durationMs: Double
    let initial: ProbeSample
    let final: ProbeSample
    let cursorDeltaCG: CursorDelta
    let cursorDeltaNS: CursorDelta
    let maxCursorDeltaCG: CursorDelta
    let maxCursorDeltaNS: CursorDelta
    let cursorMoved: Bool
    let focusChanged: Bool
    let invarianceBroken: Bool
    let activationEvents: [ActivationEvent]
}

@inline(__always)
func nowEpochMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
}

@MainActor
func captureSample() -> ProbeSample {
    let front = NSWorkspace.shared.frontmostApplication
    let nsLoc = NSEvent.mouseLocation
    let cgEvent = CGEvent(source: nil)
    let cgLoc = cgEvent?.location ?? CGPoint(x: nsLoc.x, y: nsLoc.y)
    return ProbeSample(
        timestampMs: nowEpochMs(),
        bundleIdentifier: front?.bundleIdentifier,
        processIdentifier: front?.processIdentifier ?? -1,
        localizedName: front?.localizedName,
        cgX: Double(cgLoc.x),
        cgY: Double(cgLoc.y),
        nsX: Double(nsLoc.x),
        nsY: Double(nsLoc.y),
        cgAvailable: cgEvent != nil
    )
}

func writeAtomic(data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
    try data.write(to: tmpURL, options: .atomic)
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    } else {
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }
}

@MainActor
final class WatchRunner {
    let intervalMs: Int
    let outPath: String
    let readyFile: String?
    let maxSeconds: Double?
    let assertInvariant: Bool

    let startTime = ProcessInfo.processInfo.systemUptime
    let initialSample: ProbeSample
    var latestSample: ProbeSample
    var sampleCount: Int = 1

    var maxAbsDxCG: Double = 0.0
    var maxAbsDyCG: Double = 0.0
    var maxDistCG: Double = 0.0
    var maxAbsDxNS: Double = 0.0
    var maxAbsDyNS: Double = 0.0
    var maxDistNS: Double = 0.0
    var frontmostChangedDuringPoll: Bool = false
    var activationEvents: [ActivationEvent] = []

    private var shouldStop = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    init(
        intervalMs: Int,
        outPath: String,
        readyFile: String?,
        maxSeconds: Double?,
        assertInvariant: Bool
    ) {
        self.intervalMs = max(10, intervalMs)
        self.outPath = outPath
        self.readyFile = readyFile
        self.maxSeconds = maxSeconds
        self.assertInvariant = assertInvariant
        let initial = captureSample()
        self.initialSample = initial
        self.latestSample = initial
    }

    func recordSample(_ s: ProbeSample) {
        latestSample = s
        sampleCount += 1

        let dxCG = abs(s.cgX - initialSample.cgX)
        let dyCG = abs(s.cgY - initialSample.cgY)
        let distCG = hypot(dxCG, dyCG)
        if dxCG > maxAbsDxCG { maxAbsDxCG = dxCG }
        if dyCG > maxAbsDyCG { maxAbsDyCG = dyCG }
        if distCG > maxDistCG { maxDistCG = distCG }

        let dxNS = abs(s.nsX - initialSample.nsX)
        let dyNS = abs(s.nsY - initialSample.nsY)
        let distNS = hypot(dxNS, dyNS)
        if dxNS > maxAbsDxNS { maxAbsDxNS = dxNS }
        if dyNS > maxAbsDyNS { maxAbsDyNS = dyNS }
        if distNS > maxDistNS { maxDistNS = distNS }

        if s.processIdentifier != initialSample.processIdentifier ||
            s.bundleIdentifier != initialSample.bundleIdentifier
        {
            frontmostChangedDuringPoll = true
        }
    }

    func run() -> Int32 {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let event = ActivationEvent(
                timestampMs: nowEpochMs(),
                bundleIdentifier: app?.bundleIdentifier,
                processIdentifier: app?.processIdentifier ?? -1,
                localizedName: app?.localizedName
            )
            MainActor.assumeIsolated {
                self?.activationEvents.append(event)
            }
        }

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shouldStop = true
            }
            source.resume()
            signalSources.append(source)
        }

        let intervalSec = Double(intervalMs) / 1000.0
        timer = Timer.scheduledTimer(withTimeInterval: intervalSec, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordSample(captureSample())
                if let maxSec = self.maxSeconds,
                   ProcessInfo.processInfo.systemUptime - self.startTime >= maxSec
                {
                    self.shouldStop = true
                }
            }
        }

        if let readyFile {
            let readyPayload = Data("\(initialSample.timestampMs)\n".utf8)
            do {
                try writeAtomic(data: readyPayload, to: readyFile)
            } catch {
                fputs("focus_probe error writing ready-file: \(error)\n", stderr)
                return 1
            }
        }
        print("READY")
        fflush(stdout)

        while !shouldStop {
            let stepUntil = Date(timeIntervalSinceNow: min(intervalSec, 0.05))
            RunLoop.main.run(mode: .default, before: stepUntil)
            if let maxSec = maxSeconds,
               ProcessInfo.processInfo.systemUptime - startTime >= maxSec
            {
                shouldStop = true
            }
        }

        timer?.invalidate()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()

        let finalSample = captureSample()
        recordSample(finalSample)

        let durationMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
        let finalDxCG = finalSample.cgX - initialSample.cgX
        let finalDyCG = finalSample.cgY - initialSample.cgY
        let finalDxNS = finalSample.nsX - initialSample.nsX
        let finalDyNS = finalSample.nsY - initialSample.nsY

        let cursorMoved = maxAbsDxCG > 0.0 || maxAbsDyCG > 0.0 || maxAbsDxNS > 0.0 || maxAbsDyNS > 0.0
        let focusChanged = (finalSample.processIdentifier != initialSample.processIdentifier) ||
            (finalSample.bundleIdentifier != initialSample.bundleIdentifier) ||
            frontmostChangedDuringPoll ||
            !activationEvents.isEmpty
        let invarianceBroken = cursorMoved || focusChanged

        let report = ProbeReport(
            intervalMs: intervalMs,
            sampleCount: sampleCount,
            durationMs: durationMs,
            initial: initialSample,
            final: finalSample,
            cursorDeltaCG: CursorDelta(dx: finalDxCG, dy: finalDyCG, distance: hypot(finalDxCG, finalDyCG)),
            cursorDeltaNS: CursorDelta(dx: finalDxNS, dy: finalDyNS, distance: hypot(finalDxNS, finalDyNS)),
            maxCursorDeltaCG: CursorDelta(dx: maxAbsDxCG, dy: maxAbsDyCG, distance: maxDistCG),
            maxCursorDeltaNS: CursorDelta(dx: maxAbsDxNS, dy: maxAbsDyNS, distance: maxDistNS),
            cursorMoved: cursorMoved,
            focusChanged: focusChanged,
            invarianceBroken: invarianceBroken,
            activationEvents: activationEvents
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try writeAtomic(data: data, to: outPath)
        } catch {
            fputs("focus_probe error writing output JSON: \(error)\n", stderr)
            return 1
        }

        if assertInvariant && invarianceBroken {
            return 2
        }
        return 0
    }
}

func printUsage() {
    let usage = """
    Usage:
      focus_probe --once
      focus_probe --watch --out <path> [--interval-ms <N>] [--ready-file <path>] [--max-seconds <N>] [--assert-invariant]
    """
    fputs(usage + "\n", stderr)
}

@MainActor
enum FocusProbeCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(args.isEmpty ? 1 : 0)
        }

        if args.contains("--once") {
            let sample = captureSample()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(sample)
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                    exit(0)
                }
            } catch {
                fputs("focus_probe encode error: \(error)\n", stderr)
            }
            exit(1)
        }

        guard args.contains("--watch") else {
            printUsage()
            exit(1)
        }

        var intervalMs = 50
        var outPath: String?
        var readyFile: String?
        var maxSeconds: Double?
        var assertInvariant = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--watch":
                idx += 1
            case "--assert-invariant":
                assertInvariant = true
                idx += 1
            case "--interval-ms":
                guard idx + 1 < args.count, let val = Int(args[idx + 1]), val > 0 else {
                    fputs("Invalid --interval-ms\n", stderr)
                    exit(1)
                }
                intervalMs = val
                idx += 2
            case "--out":
                guard idx + 1 < args.count else {
                    fputs("Missing --out value\n", stderr)
                    exit(1)
                }
                outPath = args[idx + 1]
                idx += 2
            case "--ready-file":
                guard idx + 1 < args.count else {
                    fputs("Missing --ready-file value\n", stderr)
                    exit(1)
                }
                readyFile = args[idx + 1]
                idx += 2
            case "--max-seconds":
                guard idx + 1 < args.count, let val = Double(args[idx + 1]), val > 0 else {
                    fputs("Invalid --max-seconds\n", stderr)
                    exit(1)
                }
                maxSeconds = val
                idx += 2
            default:
                fputs("Unknown argument: \(arg)\n", stderr)
                exit(1)
            }
        }

        guard let resolvedOutPath = outPath else {
            fputs("--out <path> is required in --watch mode\n", stderr)
            exit(1)
        }

        let outURL = URL(fileURLWithPath: resolvedOutPath).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        if resolvedOutPath.hasSuffix("/") ||
            (FileManager.default.fileExists(atPath: outURL.path, isDirectory: &isDir) && isDir.boolValue)
        {
            fputs("--out <path> must be a file path, not a directory: \(resolvedOutPath)\n", stderr)
            exit(1)
        }

        let runner = WatchRunner(
            intervalMs: intervalMs,
            outPath: resolvedOutPath,
            readyFile: readyFile,
            maxSeconds: maxSeconds,
            assertInvariant: assertInvariant
        )
        let code = runner.run()
        exit(code)
    }
}

MainActor.assumeIsolated {
    FocusProbeCLI.main()
}
