import Foundation
@testable import HelmCore
import Network
import Testing

@Suite("LLM Providers & BatonPreflight")
struct LLMAndBatonTests {
    @Test("LLMToolPromptCodec extracts JSON tool calls from fenced and raw responses")
    func toolPromptCodecParsing() {
        let raw = """
        Here is my plan:
        ```json
        {
          "thought": "Need to run command",
          "tool_calls": [
            {"id": "c1", "name": "run_command", "arguments": {"command": "echo hi"}}
          ],
          "steady_ok": false
        }
        ```
        """
        let parsed = LLMToolPromptCodec.parseEnvelope(from: raw)
        #expect(parsed.thought == "Need to run command")
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls[0].name == "run_command")
        #expect(parsed.toolCalls[0].argumentsJSON.contains("echo hi"))
        #expect(parsed.steadyOK == false)
    }

    @Test("ClaudeCLIProvider and CodexCLIProvider parse verified empirical JSON/JSONL schemas")
    func cliProvidersParseSchemas() throws {
        let claudeSample = """
        {
          "type": "result",
          "subtype": "success",
          "is_error": false,
          "result": "{\\"thought\\":\\"done\\",\\"final_response\\":\\"OK\\",\\"steady_ok\\":true}",
          "stop_reason": "end_turn",
          "total_cost_usd": 0.01,
          "usage": {
            "input_tokens": 10,
            "cache_creation_input_tokens": 5,
            "cache_read_input_tokens": 2,
            "output_tokens": 8
          }
        }
        """
        let claudeRes = try ClaudeCLIProvider.parseClaudeJSON(Data(claudeSample.utf8), hasTools: true)
        #expect(claudeRes.usage?.inputTokens == 10)
        #expect(claudeRes.usage?.cachedTokens == 7)
        #expect(claudeRes.usage?.costUSD == 0.01)

        let codexSample = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"final_response\\":\\"CODEX_OK\\",\\"steady_ok\\":true}"}}
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":12}}
        """
        let codexRes = try CodexCLIProvider.parseCodexJSONL(codexSample, hasTools: true)
        #expect(codexRes.text.contains("CODEX_OK"))
        #expect(codexRes.usage?.inputTokens == 100)
        #expect(codexRes.usage?.cachedTokens == 40)
        #expect(codexRes.usage?.outputTokens == 12)
    }

    @Test("BatonPreflight decodes empirical baton JSON and live host baton status")
    func batonPreflightDecodeAndLiveCheck() async throws {
        let fixture = """
        {
          "time": "2026-11-26T19:26:21.297069Z",
          "lanes": [
            {"name": "build", "used": 0, "total": 4, "configured_total": 4}
          ],
          "memory": {
            "pressure": "normal",
            "total_bytes": 68719476736,
            "available_bytes": 39603978240,
            "swap_total_bytes": 1073741824,
            "swap_used_bytes": 246677504,
            "some_avg10": 0
          }
        }
        """
        let snapshot = try BatonPreflight.decodeSnapshot(from: Data(fixture.utf8))
        #expect(snapshot.lanes.first?.configuredTotal == 4)
        let verdict = BatonPreflight.evaluate(snapshot: snapshot)
        #expect(verdict == .proceed(availableBytes: 39_603_978_240, pressure: "normal"))

        let critSnapshot = BatonStatusSnapshot(
            time: "now",
            lanes: [],
            memory: .init(pressure: "critical", totalBytes: 1000, availableBytes: 100, swapTotalBytes: 0, swapUsedBytes: 0)
        )
        let critVerdict = BatonPreflight.evaluate(snapshot: critSnapshot)
        if case .hold = critVerdict {
            // expected
        } else {
            Issue.record("Expected .hold verdict on critical memory pressure")
        }

        // Live baton probe (gracefully unavailable if baton binary absent)
        let liveVerdict = await BatonPreflight().checkPreflight()
        switch liveVerdict {
        case .proceed, .warn, .hold, .unavailable:
            break
        }
    }

    @Test("DirectHTTPProvider honors HELM_DIRECT_HTTP_URL and HELM_HTTP_ENDPOINT env overrides and works against local NWListener")
    func directHTTPProviderEnvOverridesAndLocalListener() async throws {
        let p1 = DirectHTTPProvider(environment: ["HELM_DIRECT_HTTP_URL": "http://127.0.0.1:41234/v1/chat/completions"])
        #expect(p1.endpointURL.absoluteString == "http://127.0.0.1:41234/v1/chat/completions")

        let p2 = DirectHTTPProvider(environment: ["HELM_HTTP_ENDPOINT": "http://127.0.0.1:41235/v1/chat/completions"])
        #expect(p2.endpointURL.absoluteString == "http://127.0.0.1:41235/v1/chat/completions")

        let pInvalid = DirectHTTPProvider(environment: ["HELM_DIRECT_HTTP_URL": "   ", "HELM_HTTP_ENDPOINT": "not a url"])
        #expect(pInvalid.endpointURL.absoluteString == "https://api.openai.com/v1/chat/completions")

        // Spin up real local NWListener HTTP fixture server
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "DirectHTTPTestListener")
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let jsonBody = #"{"choices":[{"message":{"content":"{\"final_response\":\"LOCAL_HTTP_OK\",\"steady_ok\":true}"}}],"usage":{"prompt_tokens":12,"completion_tokens":6}}"#
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(jsonBody.utf8.count)\r\nConnection: close\r\n\r\n\(jsonBody)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        let port = try await startListenerAndGetPort(listener, queue: queue)
        defer { listener.cancel() }

        let urlString = "http://127.0.0.1:\(port)/v1/chat/completions"
        let registry = LLMProviderRegistry.makeDefault(environment: ["HELM_DIRECT_HTTP_URL": urlString])
        let httpProvider = try registry.provider(for: .directHTTP)
        let res = try await httpProvider.complete(LLMRequest(
            agentID: UUID(),
            projectID: UUID(),
            stepIndex: 1,
            systemPrompt: "Test",
            userPrompt: "Ping"
        ))
        #expect(res.text.contains("LOCAL_HTTP_OK"))
        #expect(res.usage?.inputTokens == 12)

        // Unreachable local port via HelmCLIRunner transitions gracefully to held with providerFailure
        let deadListener = try NWListener(using: .tcp, on: .any)
        deadListener.newConnectionHandler = { $0.cancel() }
        let closedPort = try await startListenerAndGetPort(deadListener, queue: queue)
        deadListener.cancel()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DeadHTTP_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("http.sqlite").path
        let projOut = await HelmCLIRunner.run(arguments: [
            "project", "create", "--name", "DeadHTTP", "--goal", "G", "--workspace", tempDir.appendingPathComponent("ws").path, "--db", dbPath,
        ])
        let proj = try HelmJSON.makeDecoder().decode(Project.self, from: Data(projOut.stdout.utf8))
        _ = await HelmCLIRunner.run(arguments: [
            "agent", "add", "--project", proj.id.uuidString, "--name", "HTTPWorker", "--role", "researcher", "--goal", "G", "--backend", "http", "--db", dbPath,
        ])
        let deadOut = await HelmCLIRunner.run(
            arguments: ["run", "--project", proj.id.uuidString, "--max-steps", "3", "--db", dbPath],
            environment: ["HELM_DIRECT_HTTP_URL": "http://127.0.0.1:\(closedPort)/v1/chat/completions"]
        )
        #expect(deadOut.exitCode == 0)
        let deadRep = try HelmJSON.makeDecoder().decode(ProjectRunReport.self, from: Data(deadOut.stdout.utf8))
        #expect(deadRep.status == .held)
        #expect(deadRep.exceptions.contains(where: { $0.kind == .providerFailure }))
    }

    private func startListenerAndGetPort(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            final class Once: @unchecked Sendable {
                var resolved = false
            }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.resolved else { return }
                switch state {
                case .ready:
                    once.resolved = true
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: LLMProviderError.networkFailure("Missing listener port"))
                    }
                case .failed(let err):
                    once.resolved = true
                    continuation.resume(throwing: err)
                case .cancelled:
                    once.resolved = true
                    continuation.resume(throwing: LLMProviderError.networkFailure("Listener cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}
