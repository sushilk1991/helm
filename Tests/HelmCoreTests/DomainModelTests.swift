import Foundation
@testable import HelmCore
import Testing

@Suite("Domain Models & Locked Contracts")
struct DomainModelTests {
    @Test("TrustLevel and ExceptionKind rawValues match camelCase E2E contract")
    func enumRawValuesMatchContract() {
        #expect(TrustLevel.untrustedData.rawValue == "untrustedData")
        #expect(TrustLevel.agentGenerated.rawValue == "agentGenerated")
        #expect(TrustLevel.orchestratorVerified.rawValue == "orchestratorVerified")
        #expect(TrustLevel.humanAuthoritative.rawValue == "humanAuthoritative")

        #expect(ExceptionKind.stall.rawValue == "stall")
        #expect(ExceptionKind.loop.rawValue == "loop")
        #expect(ExceptionKind.drift.rawValue == "drift")
        #expect(ExceptionKind.budget.rawValue == "budget")
        #expect(ExceptionKind.humanDecision.rawValue == "humanDecision")
        #expect(ExceptionKind.coordinatorStalled.rawValue == "coordinatorStalled")
        #expect(ExceptionKind.providerFailure.rawValue == "providerFailure")
    }

    @Test("AgentCharacterSeed is deterministic per UUID, symmetric, non-zero, and distinct across agents")
    func characterSeedDeterminismAndUniqueness() {
        let id1 = UUID()
        let id2 = UUID()

        let seed1a = AgentCharacterSeed(agentID: id1, isOrchestrator: false)
        let seed1b = AgentCharacterSeed(agentID: id1, isOrchestrator: false)
        let seed2 = AgentCharacterSeed(agentID: id2, isOrchestrator: false)
        let orchSeed = AgentCharacterSeed(agentID: id1, isOrchestrator: true)

        #expect(seed1a == seed1b)
        #expect(seed1a.hexDigest.count == 64)
        #expect((0..<8).contains(seed1a.crownIndex))
        #expect((0..<6).contains(seed1a.eyeIndex))
        #expect((0..<6).contains(seed1a.hueIndex))
        #expect(seed1a.bodyMask != 0)
        #expect(seed1a.hexDigest != seed2.hexDigest)
        #expect(orchSeed.isOrchestrator == true)

        // Verify bilateral symmetry across col 2 (0==4, 1==3)
        for row in 0..<5 {
            #expect(seed1a.isBodyPixelFilled(row: row, col: 0) == seed1a.isBodyPixelFilled(row: row, col: 4))
            #expect(seed1a.isBodyPixelFilled(row: row, col: 1) == seed1a.isBodyPixelFilled(row: row, col: 3))
        }
    }

    @Test("BrowserObservation unconditionally enforces untrustedData trustTag")
    func browserObservationEnforcesUntrustedTag() throws {
        let obs = BrowserObservation(
            url: "http://127.0.0.1:8080/",
            title: "Fixture",
            viewportSize: CGSize(width: 1440, height: 900),
            screenshotPNGPath: URL(fileURLWithPath: "/tmp/shot.png"),
            ocrLines: [
                OCRLine(
                    text: "HELLO",
                    confidence: 0.99,
                    normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    cssRect: CGRect(x: 144, y: 630, width: 432, height: 90)
                ),
            ],
            domElements: [
                DOMInteractiveElement(
                    ref: "@e1",
                    tagName: "button",
                    role: "button",
                    text: "Submit",
                    elementID: "submit-btn",
                    cssRect: CGRect(x: 100, y: 200, width: 120, height: 44)
                ),
            ],
            trustTag: .humanAuthoritative,
            latencyMs: 42.5
        )
        #expect(obs.trustTag == .untrustedData)

        // Also test JSON tampering on decode
        let encoder = HelmJSON.makeEncoder()
        let data = try encoder.encode(obs)
        let rawStr = try #require(String(data: data, encoding: .utf8))
        let tamperedStr = rawStr.replacingOccurrences(of: "untrustedData", with: "humanAuthoritative")
        let decoded = try HelmJSON.makeDecoder().decode(BrowserObservation.self, from: Data(tamperedStr.utf8))
        #expect(decoded.trustTag == .untrustedData)
    }

    @Test("All domain models round-trip cleanly via JSON Codable")
    func codableRoundTrips() throws {
        let encoder = HelmJSON.makeEncoder()
        let decoder = HelmJSON.makeDecoder()

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Harbor Alpha",
            goal: "Ship v1",
            workspaceRoot: URL(fileURLWithPath: "/tmp/harbor_alpha"),
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let decodedProj = try decoder.decode(Project.self, from: encoder.encode(project))
        #expect(decodedProj == project)

        let agent = AgentProfile(
            projectID: project.id,
            name: "Scout",
            role: .researcher,
            goal: "Gather docs",
            capabilities: [.browser, .ocr, .readSharedState],
            backend: .mock,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let decodedAgent = try decoder.decode(AgentProfile.self, from: encoder.encode(agent))
        #expect(decodedAgent == agent)

        let alert = ExceptionAlert(
            projectID: project.id,
            kind: .humanDecision,
            title: "Approval Needed",
            summary: "Confirm deploy",
            dedupKey: "k1",
            resolution: .redirect(note: "Use staging first")
        )
        let alertData = try encoder.encode(alert)
        let decodedAlert = try decoder.decode(ExceptionAlert.self, from: alertData)
        #expect(decodedAlert.summary == "Confirm deploy")
        #expect(decodedAlert.resolution == .redirect(note: "Use staging first"))

        let execReq = ExecutionRequest(
            projectID: project.id,
            workspacePath: project.workspaceRoot,
            command: "echo ok",
            preferredMode: .seatbeltSandbox
        )
        let decodedReq = try decoder.decode(ExecutionRequest.self, from: encoder.encode(execReq))
        #expect(decodedReq == execReq)

        let execRes = ExecutionResult(
            requestID: execReq.id,
            modeUsed: .seatbeltSandbox,
            exitCode: 0,
            stdout: "ok",
            stderr: "",
            timedOut: false,
            truncatedOutput: false,
            durationMs: 12.3
        )
        let decodedRes = try decoder.decode(ExecutionResult.self, from: encoder.encode(execRes))
        #expect(decodedRes == execRes)
    }
}
