import AppKit
import CoreGraphics
import Foundation
import HelmBrowser
import HelmCore
import HelmIsolation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public enum HeadlessSnapshotRunner {
    public enum SnapshotDirArgument: Sendable, Equatable {
        case notRequested
        case valid(String)
        case invalid(String)
    }

    public static func parseSnapshotDir(arguments: [String]) -> SnapshotDirArgument {
        if let idx = arguments.firstIndex(of: "--snapshot-dir") {
            guard idx + 1 < arguments.count else {
                return .invalid("--snapshot-dir requires a directory path.")
            }
            let value = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return .invalid("--snapshot-dir requires a non-empty directory path.")
            }
            return .valid(value)
        }
        for arg in arguments where arg.hasPrefix("--snapshot-dir=") {
            let value = String(arg.dropFirst("--snapshot-dir=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return .invalid("--snapshot-dir= requires a non-empty directory path.")
            }
            return .valid(value)
        }
        return .notRequested
    }

    private static let fixedEpoch = Date(timeIntervalSince1970: 1_764_180_000)

    private static let proj1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private static let proj2ID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!

    private static let agentOrchID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private static let agentResearcherID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    private static let agentCoderID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
    private static let agentBrowserID = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!

    private static let task1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    private static let task2ID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
    private static let task3ID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!

    private static let state1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    private static let state2ID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
    private static let state3ID = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
    private static let privMem1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!

    private static let exc1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!

    public static func run(snapshotDirectory: URL, reduceMotion: Bool) async throws {
        // Initialize AppKit without activating or stealing macOS focus
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let steadyStore = try await buildSeededStore(withException: false, reduceMotion: reduceMotion)
        let exceptionStore = try await buildSeededStore(withException: true, reduceMotion: reduceMotion)

        let suffix = reduceMotion ? "_reduce_motion" : ""
        let variants: [(filename: String, store: HelmWorkspaceStore, isDark: Bool, ping: Bool)] = [
            ("helm_light_steady\(suffix).png", steadyStore, false, true),
            ("helm_dark_steady\(suffix).png", steadyStore, true, true),
            ("helm_light_exception\(suffix).png", exceptionStore, false, false),
            ("helm_dark_exception\(suffix).png", exceptionStore, true, false),
        ]

        for variant in variants {
            let view = HarborSnapshotShellView(store: variant.store, horizonPingOverride: variant.ping)
                .environment(\.helmReduceMotion, reduceMotion)
                .environment(\.helmWindowOccluded, false)
                .preferredColorScheme(variant.isDark ? .dark : .light)

            let outputURL = snapshotDirectory.appendingPathComponent(variant.filename)
            try renderOffscreenPNG(
                rootView: view,
                size: CGSize(width: 1280, height: 800),
                isDark: variant.isDark,
                to: outputURL
            )
        }

        // Optional Settings (Accounts & CLIs) snapshots for visual QA (opt-in so standard E2E width checks stay >= 900)
        if ProcessInfo.processInfo.environment["HELM_SNAPSHOT_SETTINGS"] == "1" {
            for isDark in [true, false] {
                let settingsView = SettingsSheetView(store: steadyStore)
                    .environment(\.helmReduceMotion, reduceMotion)
                    .environment(\.helmWindowOccluded, false)
                    .preferredColorScheme(isDark ? .dark : .light)
                let name = isDark ? "helm_dark_settings\(suffix).png" : "helm_light_settings\(suffix).png"
                try renderOffscreenPNG(
                    rootView: settingsView,
                    size: CGSize(width: 720, height: 660),
                    isDark: isDark,
                    to: snapshotDirectory.appendingPathComponent(name)
                )
            }
        }

        // Optional M3 extra visual QA captures (1-on-1 direct chat + editable System Prompt inspector; navigable Tasks detail)
        if ProcessInfo.processInfo.environment["HELM_SNAPSHOT_EXTRA"] == "1" {
            let inspectorDirectStore = try await buildSeededStore(withException: false, reduceMotion: reduceMotion)
            inspectorDirectStore.selectAgent(agentCoderID, openDirectChat: true, openInspector: true)

            let tasksStore = try await buildSeededStore(withException: false, reduceMotion: reduceMotion)
            tasksStore.openTaskInWorkspace(task2ID)

            let extras: [(filename: String, store: HelmWorkspaceStore, isDark: Bool)] = [
                ("helm_dark_inspector_direct\(suffix).png", inspectorDirectStore, true),
                ("helm_light_inspector_direct\(suffix).png", inspectorDirectStore, false),
                ("helm_dark_tasks_navigable\(suffix).png", tasksStore, true),
                ("helm_light_tasks_navigable\(suffix).png", tasksStore, false),
            ]
            for extra in extras {
                let view = HarborSnapshotShellView(store: extra.store, horizonPingOverride: true)
                    .environment(\.helmReduceMotion, reduceMotion)
                    .environment(\.helmWindowOccluded, false)
                    .preferredColorScheme(extra.isDark ? .dark : .light)
                try renderOffscreenPNG(
                    rootView: view,
                    size: CGSize(width: 1280, height: 800),
                    isDark: extra.isDark,
                    to: snapshotDirectory.appendingPathComponent(extra.filename)
                )
            }
        }
    }

    private static func buildSeededStore(withException: Bool, reduceMotion: Bool) async throws -> HelmWorkspaceStore {
        let db = try HelmDatabase(path: ":memory:")
        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = HelmControlPlane(
            database: db,
            providerRegistry: .makeDefault(),
            sandboxExecutor: router,
            browserService: browser
        )
        let notif = NotificationCoordinator(
            arguments: ["--headless"],
            environment: ["HELM_DISABLE_NOTIFICATIONS": "1", "HELM_NO_ACTIVATE": "1"]
        )
        let store = HelmWorkspaceStore(
            controlPlane: cp,
            ocrService: ocr,
            sandboxExecutor: router,
            browserService: browser,
            notificationCoordinator: notif,
            forcedReduceMotion: reduceMotion
        )

        // Prime boot reconciliation on empty store so seeded .running/.thinking/.executing/.browsing states
        // are preserved intact for steady-watch visual snapshots.
        try await cp.reloadFromStore()

        let wsRoot1 = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-telemetry-pipeline", isDirectory: true)
        let wsRoot2 = FileManager.default.temporaryDirectory.appendingPathComponent("api-contract-verifier", isDirectory: true)

        let p1 = Project(
            id: proj1ID,
            name: "Harbor Telemetry Pipeline",
            goal: "Build local diagnostics pipeline, verify sandbox tests, and validate staging dashboard via Vision OCR.",
            workspaceRoot: wsRoot1,
            status: withException ? .held : .running,
            sandboxTrustPolicy: .standardWorkspace,
            createdAt: fixedEpoch,
            updatedAt: fixedEpoch
        )
        let p2 = Project(
            id: proj2ID,
            name: "API Contract Verifier",
            goal: "Verify staging REST schemas and error handling silently in background.",
            workspaceRoot: wsRoot2,
            status: .idle,
            sandboxTrustPolicy: .sandboxed,
            createdAt: fixedEpoch.addingTimeInterval(60),
            updatedAt: fixedEpoch.addingTimeInterval(60)
        )
        try await db.insertProject(p1)
        try await db.insertProject(p2)

        let orchPrompt = """
        Role: orchestrator
        Style (Calm Commander): Lead decisively, keep work moving in parallel, and summarize verified outcomes.
        Mission: Coordinate crew turns directly from harbor-telemetry-pipeline without stalling for routine confirmations.
        """
        let coderPrompt = """
        Role: coder
        Style (Pragmatic Builder): Inspect source files first, implement minimal diffs, and run unit suites before reporting.
        Mission: Implement TelemetryCollector tests and verify pipeline benchmarks inside harbor-telemetry-pipeline.
        """

        let orch = AgentProfile(
            id: agentOrchID,
            projectID: proj1ID,
            name: "Compass",
            role: .orchestrator,
            goal: AgentProfile.RolePreset.orchestrator.goal,
            personality: .calmCommander,
            systemPrompt: orchPrompt,
            capabilities: AgentProfile.RolePreset.orchestrator.capabilities,
            backend: .claudeCLI,
            activityState: withException ? .waiting : .thinking,
            createdAt: fixedEpoch,
            updatedAt: fixedEpoch
        )
        let researcher = AgentProfile(
            id: agentResearcherID,
            projectID: proj1ID,
            name: "Chart",
            role: .researcher,
            goal: AgentProfile.RolePreset.researcher.goal,
            personality: .methodicalArchitect,
            capabilities: AgentProfile.RolePreset.researcher.capabilities,
            backend: .claudeCLI,
            activityState: .completed,
            createdAt: fixedEpoch.addingTimeInterval(5),
            updatedAt: fixedEpoch.addingTimeInterval(5)
        )
        let coder = AgentProfile(
            id: agentCoderID,
            projectID: proj1ID,
            name: "Forge",
            role: .coder,
            goal: AgentProfile.RolePreset.coder.goal,
            personality: .pragmaticBuilder,
            systemPrompt: coderPrompt,
            capabilities: AgentProfile.RolePreset.coder.capabilities,
            backend: .codexCLI,
            activityState: withException ? .exception : .executing,
            createdAt: fixedEpoch.addingTimeInterval(10),
            updatedAt: fixedEpoch.addingTimeInterval(10)
        )
        let browserAgent = AgentProfile(
            id: agentBrowserID,
            projectID: proj1ID,
            name: "Lookout",
            role: .browserAnalyst,
            goal: AgentProfile.RolePreset.browserAnalyst.goal,
            personality: .rapidOperator,
            capabilities: AgentProfile.RolePreset.browserAnalyst.capabilities,
            backend: .foundationModels,
            activityState: withException ? .waiting : .browsing,
            createdAt: fixedEpoch.addingTimeInterval(15),
            updatedAt: fixedEpoch.addingTimeInterval(15)
        )
        for agent in [orch, researcher, coder, browserAgent] {
            try await db.insertAgent(agent)
        }

        let t1 = DelegatedTask(
            id: task1ID,
            projectID: proj1ID,
            assignedAgentID: agentResearcherID,
            createdByAgentID: agentOrchID,
            title: "Extract pipeline schema requirements",
            instructions: "Inspect Sources/Telemetry/Schema.swift and publish verified telemetry field invariants to shared memory.",
            status: .done,
            resultSummary: "Published 3 schema invariants to shared state.",
            artifactPaths: ["docs/telemetry-schema.md"],
            createdAt: fixedEpoch,
            updatedAt: fixedEpoch.addingTimeInterval(30)
        )
        let t2 = DelegatedTask(
            id: task2ID,
            projectID: proj1ID,
            assignedAgentID: agentCoderID,
            createdByAgentID: agentOrchID,
            title: withException ? "Update host-level launchd plist" : "Run isolated sandbox benchmark suite",
            instructions: withException
                ? "Attempted to write outside harbor-telemetry-pipeline into ~/Library/LaunchAgents; halted by boundary guard."
                : "Implement benchmark fixtures in Tests/TelemetryTests.swift and run swift test inside the project workspace.",
            status: withException ? .needsHuman : .running,
            waitingOn: [task1ID],
            attemptCount: 1,
            errorSummary: withException ? "Blocked write outside attached project folder (~/Library/LaunchAgents/com.helm.agent.plist)." : nil,
            artifactPaths: ["Tests/TelemetryTests.swift"],
            createdAt: fixedEpoch.addingTimeInterval(15),
            updatedAt: fixedEpoch.addingTimeInterval(45)
        )
        let t3 = DelegatedTask(
            id: task3ID,
            projectID: proj1ID,
            assignedAgentID: agentBrowserID,
            createdByAgentID: agentOrchID,
            title: "Read staging health dashboard via Vision OCR",
            instructions: "Navigate to staging portal and verify confirmation banner after benchmarks finish.",
            status: withException ? .blocked : .running,
            waitingOn: [task2ID],
            createdAt: fixedEpoch.addingTimeInterval(20),
            updatedAt: fixedEpoch.addingTimeInterval(45)
        )
        for task in [t1, t2, t3] {
            try await db.insertTask(task)
        }

        let chatMessages: [ChatMessage] = [
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
                projectID: proj1ID,
                channelKind: .crew,
                senderKind: .user,
                senderName: "You",
                content: "Audit Sources/Telemetry, run the benchmark suite, and verify the staging health portal.",
                referencedFiles: ["Sources/Telemetry/Schema.swift", "Package.swift"],
                createdAt: fixedEpoch.addingTimeInterval(5)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
                projectID: proj1ID,
                channelKind: .crew,
                senderKind: .orchestrator,
                senderAgentID: agentOrchID,
                senderName: "Compass",
                content: "Chart verified 3 schema invariants in docs/telemetry-schema.md. Forge is executing the benchmark suite now, with Lookout queued next.",
                referencedFiles: ["docs/telemetry-schema.md"],
                relatedTaskID: task1ID,
                createdAt: fixedEpoch.addingTimeInterval(22)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000803")!,
                projectID: proj1ID,
                channelKind: .crew,
                senderKind: .agent,
                senderAgentID: agentCoderID,
                senderName: "Forge",
                content: withException
                    ? "Paused at boundary check: writing outside harbor-telemetry-pipeline requires your explicit redirect or approval."
                    : "62/62 core tests passed in 148 ms. Finishing throughput assertions in Tests/TelemetryTests.swift.",
                referencedFiles: ["Tests/TelemetryTests.swift"],
                relatedTaskID: task2ID,
                createdAt: fixedEpoch.addingTimeInterval(42)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000804")!,
                projectID: proj1ID,
                channelKind: .direct(agentID: agentCoderID),
                senderKind: .user,
                senderName: "You",
                content: "Keep the benchmark fixtures deterministic with fixed seeds and report p95 latency.",
                referencedFiles: ["Tests/TelemetryTests.swift"],
                relatedTaskID: task2ID,
                createdAt: fixedEpoch.addingTimeInterval(30)
            ),
            ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000805")!,
                projectID: proj1ID,
                channelKind: .direct(agentID: agentCoderID),
                senderKind: .agent,
                senderAgentID: agentCoderID,
                senderName: "Forge",
                content: "Locked deterministic fixture seeds and added p95 latency assertions to TelemetryTests.swift.",
                referencedFiles: ["Tests/TelemetryTests.swift"],
                relatedTaskID: task2ID,
                createdAt: fixedEpoch.addingTimeInterval(44)
            ),
        ]
        for msg in chatMessages {
            try await db.insertChatMessage(msg)
        }

        let workEntries: [AgentWorkEntry] = [
            AgentWorkEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
                projectID: proj1ID,
                agentID: agentResearcherID,
                agentName: "Chart",
                taskID: task1ID,
                taskTitle: t1.title,
                stepNumber: 1,
                phase: .completed,
                summary: "Read Sources/Telemetry/Schema.swift and documented 3 telemetry field invariants.",
                toolName: "read_workspace_file",
                toolInputSummary: "Sources/Telemetry/Schema.swift",
                toolOutputSummary: "Parsed TelemetryEnvelope v3 fields (48 lines)",
                touchedFiles: ["Sources/Telemetry/Schema.swift"],
                artifactPaths: ["docs/telemetry-schema.md"],
                createdAt: fixedEpoch.addingTimeInterval(18)
            ),
            AgentWorkEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
                projectID: proj1ID,
                agentID: agentCoderID,
                agentName: "Forge",
                taskID: task2ID,
                taskTitle: t2.title,
                stepNumber: 2,
                phase: .fileEdit,
                summary: "Added deterministic p95 throughput benchmark assertions.",
                toolName: "write_workspace_file",
                toolInputSummary: "Tests/TelemetryTests.swift (+34 lines)",
                toolOutputSummary: "Updated Tests/TelemetryTests.swift",
                touchedFiles: ["Tests/TelemetryTests.swift"],
                createdAt: fixedEpoch.addingTimeInterval(34)
            ),
            AgentWorkEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
                projectID: proj1ID,
                agentID: agentCoderID,
                agentName: "Forge",
                taskID: task2ID,
                taskTitle: t2.title,
                stepNumber: 3,
                phase: withException ? .failed : .toolCall,
                summary: withException
                    ? "Boundary drift guard blocked out-of-workspace file write."
                    : "Executing isolated test suite and collecting p95 timing metrics.",
                toolName: withException ? "write_workspace_file" : "run_command",
                toolInputSummary: withException ? "~/Library/LaunchAgents/com.helm.agent.plist" : "swift test --filter TelemetryTests",
                toolOutputSummary: withException ? "Blocked: path escapes workspaceRoot" : "62/62 tests passed (148 ms)",
                touchedFiles: ["Tests/TelemetryTests.swift"],
                createdAt: fixedEpoch.addingTimeInterval(46)
            ),
        ]
        for entry in workEntries {
            try await db.insertAgentWorkEntry(entry)
        }

        let s1 = SharedStateEntry(
            id: state1ID,
            projectID: proj1ID,
            scope: .projectShared,
            ownerAgentID: nil,
            category: .rule,
            key: "policy.isolation.mode",
            title: "Isolation Policy",
            content: "All code execution must remain strictly inside the project folder without touching host focus.",
            trustLevel: .humanAuthoritative,
            provenance: ProvenanceRecord(source: .humanOwner),
            pinned: true,
            createdAt: fixedEpoch,
            updatedAt: fixedEpoch
        )
        let s2 = SharedStateEntry(
            id: state2ID,
            projectID: proj1ID,
            scope: .projectShared,
            ownerAgentID: agentOrchID,
            category: .fact,
            key: "sandbox.unit_suite",
            title: "Unit Suite Verification",
            content: "62/62 isolated tests passed in 148 ms (zero regressions).",
            trustLevel: .orchestratorVerified,
            provenance: ProvenanceRecord(source: .orchestrator, authorAgentID: agentOrchID),
            createdAt: fixedEpoch.addingTimeInterval(20),
            updatedAt: fixedEpoch.addingTimeInterval(20)
        )
        let s3 = SharedStateEntry(
            id: state3ID,
            projectID: proj1ID,
            scope: .projectShared,
            ownerAgentID: agentBrowserID,
            category: .observation,
            key: "browser.staging.banner",
            title: "Staging Portal Observation",
            content: "Staging health banner reads: BUILD GREEN · 4 WORKER NODES ACTIVE.",
            trustLevel: .untrustedData,
            provenance: ProvenanceRecord(source: .ocrResult, authorAgentID: agentBrowserID, sourceURI: "https://staging.helm.local/status"),
            createdAt: fixedEpoch.addingTimeInterval(35),
            updatedAt: fixedEpoch.addingTimeInterval(35)
        )
        let privMem = SharedStateEntry(
            id: privMem1ID,
            projectID: proj1ID,
            scope: .agentPrivate,
            ownerAgentID: agentCoderID,
            category: .continuity,
            key: "coder.last_checkpoint",
            title: "Coder Checkpoint",
            content: "Compiled release binary cleanly; p95 latency 14.2 ms.",
            trustLevel: .agentGenerated,
            provenance: ProvenanceRecord(source: .workerAgent, authorAgentID: agentCoderID),
            createdAt: fixedEpoch.addingTimeInterval(40),
            updatedAt: fixedEpoch.addingTimeInterval(40)
        )
        for entry in [s1, s2, s3, privMem] {
            _ = try await db.upsertSharedState(entry)
        }

        try await db.appendEvent(RunEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            projectID: proj1ID,
            agentID: agentOrchID,
            kind: .heartbeatSteadyOK,
            summary: "STEADY_OK: 3 tasks active, 0 policy violations",
            trustLevel: .orchestratorVerified,
            createdAt: fixedEpoch.addingTimeInterval(40)
        ))

        if withException {
            let alert = ExceptionAlert(
                id: exc1ID,
                projectID: proj1ID,
                taskID: task2ID,
                agentID: agentCoderID,
                kind: .drift,
                severity: .attention,
                title: "Boundary Drift: Out-of-Workspace Write Blocked",
                summary: "Forge attempted to write outside the attached project folder.",
                diagnosticSummary: "Blocked write to ~/Library/LaunchAgents/com.helm.agent.plist. Redirect Forge to keep config artifacts inside harbor-telemetry-pipeline.",
                suggestedOptions: ["redirect", "retry", "abort"],
                dedupKey: "demo-boundary-drift-001",
                status: .open,
                createdAt: fixedEpoch.addingTimeInterval(50)
            )
            _ = try await db.upsertOpenException(alert)
            try await db.appendEvent(RunEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
                projectID: proj1ID,
                agentID: agentCoderID,
                taskID: task2ID,
                kind: .exceptionRaised,
                summary: "[drift] Boundary Drift: Out-of-Workspace Write Blocked",
                trustLevel: .orchestratorVerified,
                createdAt: fixedEpoch.addingTimeInterval(50)
            ))
        }

        await store.reloadAll()
        store.selectProject(proj1ID)
        store.selectedAgentID = withException ? agentCoderID : agentOrchID
        store.isInspectorVisible = false
        store.secondaryTab = .liveWork

        store.latestExecutionResultByProject[proj1ID] = ExecutionResult(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            modeUsed: .virtualizationVM,
            exitCode: 0,
            stdout: "$ swift test --filter TelemetryTests\nTest Suite 'All tests' passed (62 tests, 0 failures)\nworkspace: /workspace (isolated)",
            stderr: "",
            timedOut: false,
            truncatedOutput: false,
            durationMs: 148.0
        )

        store.latestBrowserObservationByProject[proj1ID] = BrowserObservation(
            url: "https://staging.helm.local/status",
            title: "Staging Telemetry Portal",
            viewportSize: CGSize(width: 1440, height: 900),
            screenshotPNGPath: URL(fileURLWithPath: "/tmp/helm_demo_frame.png"),
            ocrLines: [
                OCRLine(text: "HARBOR STAGING TELEMETRY", confidence: 0.99, normalizedRect: CGRect(x: 0.1, y: 0.85, width: 0.4, height: 0.05), cssRect: CGRect(x: 144, y: 90, width: 576, height: 45)),
                OCRLine(text: "STATUS: STEADY WATCH OK", confidence: 0.98, normalizedRect: CGRect(x: 0.1, y: 0.78, width: 0.35, height: 0.04), cssRect: CGRect(x: 144, y: 162, width: 504, height: 36)),
                OCRLine(text: "VERIFY DEPLOYMENT", confidence: 0.96, normalizedRect: CGRect(x: 0.1, y: 0.65, width: 0.25, height: 0.04), cssRect: CGRect(x: 144, y: 279, width: 360, height: 36)),
            ],
            domElements: [],
            trustTag: .untrustedData,
            latencyMs: 42.0
        )

        return store
    }

    private static func renderOffscreenPNG<V: View>(
        rootView: V,
        size: CGSize,
        isDark: Bool,
        to url: URL
    ) throws {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.appearance = appearance

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        window.contentView = hosting

        // Allow SwiftUI layout & Canvas drawing to settle completely offscreen without ordering front
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "HeadlessSnapshotRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmapImageRep"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let rawImage = rep.cgImage else {
            throw NSError(domain: "HeadlessSnapshotRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing CGImage from bitmapImageRep"])
        }

        // Normalize into an exact 1280x800 8-bit non-interlaced RGBA sRGB bitmap for consistent E2E inspection
        let pixelWidth = Int(size.width)
        let pixelHeight = Int(size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw NSError(domain: "HeadlessSnapshotRunner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create sRGB CGContext"])
        }

        ctx.interpolationQuality = .high
        ctx.draw(rawImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        guard let finalImage = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "HeadlessSnapshotRunner", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination at \(url.path)"])
        }

        let pngProps: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGInterlaceType: 0
            ]
        ]
        CGImageDestinationAddImage(dest, finalImage, pngProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "HeadlessSnapshotRunner", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG to \(url.path)"])
        }

        window.contentView = nil
        window.close()
    }
}
