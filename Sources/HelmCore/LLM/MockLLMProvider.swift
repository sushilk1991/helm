import Foundation

public enum MockScenario: Sendable {
    case nominalSteadyOK
    case transientSelfCorrectingError
    case simulatedStallLoop(repeatCount: Int = 3)
    case simulatedDrift
    case simulatedCyclicDAG
    case simulatedHumanDecision(question: String, options: [String] = ["approve", "redirect", "abort"])
    case customHandler(@Sendable (LLMRequest) async throws -> LLMResponse)
}

public actor MockLLMProvider: LLMProvider {
    public nonisolated let kind: LLMBackendKind = .mock
    private var scenario: MockScenario
    private var callCounter: Int = 0
    private var agentAttemptCounts: [String: Int] = [:]

    public init(
        scenario: MockScenario? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let scenario {
            self.scenario = scenario
        } else if environment["HELM_MOCK_TRANSIENT_FAIL_ONCE"] == "1" {
            self.scenario = .transientSelfCorrectingError
        } else {
            self.scenario = .nominalSteadyOK
        }
    }

    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        callCounter += 1
        let attemptKey = "\(request.agentID.uuidString):\(request.stepIndex)"
        let seenCount = (agentAttemptCounts[attemptKey] ?? 0) + 1
        agentAttemptCounts[attemptKey] = seenCount

        switch scenario {
        case .customHandler(let handler):
            return try await handler(request)

        case .nominalSteadyOK:
            return handleNominal(request)

        case .transientSelfCorrectingError:
            if request.systemPrompt.contains("Role: orchestrator") || request.userPrompt.contains("DECOMPOSE_GOAL") {
                return handleNominal(request)
            }
            if callCounter == 2 || (seenCount == 1 && request.userPrompt.contains("TASK_EXECUTION") && !request.userPrompt.contains("[Self-Correction")) {
                // First worker execution returns malformed/transient JSON so Orchestrator self-corrects quietly
                return LLMResponse(
                    text: "{malformed_transient_json",
                    toolCalls: [],
                    usage: LLMUsage(inputTokens: 40, outputTokens: 12),
                    stopReason: "error_recoverable",
                    latencyMs: 2.0
                )
            }
            return handleNominal(request)

        case .simulatedStallLoop:
            if request.systemPrompt.contains("Role: orchestrator") || request.userPrompt.contains("DECOMPOSE_GOAL") {
                return handleNominal(request)
            }
            let payload = """
            {
              "thought": "Retrying failing workspace inspection command",
              "tool_calls": [
                {
                  "id": "loop_call",
                  "name": "failing_tool_probe",
                  "arguments": {"target": "locked_resource", "error": "EACCES_REPEAT"}
                }
              ]
            }
            """
            return LLMResponse(
                text: payload,
                toolCalls: [
                    LLMToolCall(
                        id: "loop_call_\(callCounter)",
                        name: "failing_tool_probe",
                        argumentsJSON: "{\"error\":\"EACCES_REPEAT\",\"target\":\"locked_resource\"}"
                    ),
                ],
                usage: LLMUsage(inputTokens: 45, outputTokens: 25),
                stopReason: "tool_use",
                latencyMs: 2.0
            )

        case .simulatedDrift:
            if request.systemPrompt.contains("Role: orchestrator") || request.userPrompt.contains("DECOMPOSE_GOAL") {
                return handleNominal(request)
            }
            let payload = """
            {
              "thought": "Attempting to access host path outside project workspace",
              "tool_calls": [
                {
                  "id": "drift_call",
                  "name": "write_workspace_file",
                  "arguments": {"path": "/etc/passwd", "content": "drift_probe"}
                }
              ]
            }
            """
            return LLMResponse(
                text: payload,
                toolCalls: [
                    LLMToolCall(
                        id: "drift_call_\(callCounter)",
                        name: "write_workspace_file",
                        argumentsJSON: "{\"content\":\"drift_probe\",\"path\":\"/etc/passwd\"}"
                    ),
                ],
                usage: LLMUsage(inputTokens: 42, outputTokens: 24),
                stopReason: "tool_use",
                latencyMs: 2.0
            )

        case .simulatedCyclicDAG:
            if request.userPrompt.contains("DECOMPOSE_GOAL") {
                let cyclicJSON = buildCyclicDecompositionPlanJSON(from: request.userPrompt)
                return LLMResponse(
                    text: cyclicJSON,
                    toolCalls: [],
                    usage: LLMUsage(inputTokens: 60, outputTokens: 48),
                    stopReason: "end_turn",
                    latencyMs: 2.0
                )
            }
            return handleNominal(request)

        case .simulatedHumanDecision(let question, let options):
            if request.systemPrompt.contains("Role: orchestrator") || request.userPrompt.contains("DECOMPOSE_GOAL") {
                return handleNominal(request)
            }
            let argsObj: [String: Any] = [
                "question": question,
                "options": options,
            ]
            let argsData = (try? JSONSerialization.data(withJSONObject: argsObj, options: [.sortedKeys])) ?? Data("{}".utf8)
            let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
            let payload = """
            {
              "thought": "Human authorization required before proceeding",
              "tool_calls": [
                {
                  "id": "human_gate",
                  "name": "ask_human",
                  "arguments": \(argsJSON)
                }
              ]
            }
            """
            return LLMResponse(
                text: payload,
                toolCalls: [
                    LLMToolCall(id: "human_gate_\(callCounter)", name: "ask_human", argumentsJSON: argsJSON),
                ],
                usage: LLMUsage(inputTokens: 38, outputTokens: 22),
                stopReason: "tool_use",
                latencyMs: 2.0
            )
        }
    }

    private func handleNominal(_ request: LLMRequest) -> LLMResponse {
        if request.userPrompt.contains("DECOMPOSE_GOAL") {
            let responseJSON = buildDecompositionPlanJSON(from: request.userPrompt)
            return LLMResponse(
                text: responseJSON,
                toolCalls: [],
                usage: LLMUsage(inputTokens: 80, outputTokens: 64),
                stopReason: "end_turn",
                latencyMs: 3.0
            )
        }

        if request.userPrompt.contains("STEADY_CHECK") {
            let json = """
            {"thought":"All delegated tasks progressing nominally","steady_ok":true,"final_response":"STEADY_OK"}
            """
            return LLMResponse(
                text: json,
                toolCalls: [],
                usage: LLMUsage(inputTokens: 30, outputTokens: 15),
                stopReason: "end_turn",
                latencyMs: 1.5
            )
        }

        let summary = "Completed task at step \(request.stepIndex) cleanly."
        let args: [String: Any] = [
            "summary": summary,
            "shared_key": "agent.\(request.agentID.uuidString.prefix(8)).step_\(request.stepIndex)",
            "shared_title": "Step \(request.stepIndex) Output",
            "shared_value": "Verified output for step \(request.stepIndex)",
        ]
        let argsData = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        let responseText = """
        {
          "thought": "Executing assigned task cleanly and recording shared state",
          "tool_calls": [
            {
              "id": "complete_\(callCounter)",
              "name": "complete_task",
              "arguments": \(argsJSON)
            }
          ],
          "final_response": "\(summary)",
          "steady_ok": true
        }
        """
        return LLMResponse(
            text: responseText,
            toolCalls: [
                LLMToolCall(id: "complete_\(callCounter)", name: "complete_task", argumentsJSON: argsJSON),
            ],
            usage: LLMUsage(inputTokens: 60, outputTokens: 48),
            stopReason: "end_turn",
            latencyMs: 2.5
        )
    }

    private func buildDecompositionPlanJSON(from userPrompt: String) -> String {
        // Parse lines formatted by OrchestratorActor: "AGENT|<uuid>|<name>|<role>|<goal>"
        var agentIDs: [(id: String, name: String, role: String)] = []
        for line in userPrompt.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 4, parts[0] == "AGENT" {
                agentIDs.append((String(parts[1]), String(parts[2]), String(parts[3])))
            }
        }

        var items: [[String: Any]] = []
        if agentIDs.isEmpty {
            return "{\"tasks\":[]}"
        }
        for (index, agent) in agentIDs.enumerated() {
            let tempID = "t\(index + 1)"
            let waiting: [String] = index == 0 ? [] : ["t\(index)"]
            items.append([
                "temp_id": tempID,
                "title": "\(agent.name) (\(agent.role)) milestone",
                "instructions": "Execute specialized \(agent.role) stage for project goal.",
                "assigned_agent_id": agent.id,
                "waiting_on_temp_ids": waiting,
            ])
        }
        let payload: [String: Any] = ["tasks": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"tasks\":[]}".utf8)
        return String(data: data, encoding: .utf8) ?? "{\"tasks\":[]}"
    }

    private func buildCyclicDecompositionPlanJSON(from userPrompt: String) -> String {
        var agentIDs: [(id: String, name: String, role: String)] = []
        for line in userPrompt.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 4, parts[0] == "AGENT" {
                agentIDs.append((String(parts[1]), String(parts[2]), String(parts[3])))
            }
        }
        guard !agentIDs.isEmpty else {
            return "{\"tasks\":[]}"
        }
        let first = agentIDs[0]
        let second = agentIDs.count > 1 ? agentIDs[1] : agentIDs[0]
        let items: [[String: Any]] = [
            [
                "temp_id": "t1",
                "title": "\(first.name) cycle stage 1",
                "instructions": "Wait on t2 (cyclic).",
                "assigned_agent_id": first.id,
                "waiting_on_temp_ids": ["t2"],
            ],
            [
                "temp_id": "t2",
                "title": "\(second.name) cycle stage 2",
                "instructions": "Wait on t1 (cyclic).",
                "assigned_agent_id": second.id,
                "waiting_on_temp_ids": ["t1"],
            ],
        ]
        let payload: [String: Any] = ["tasks": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"tasks\":[]}".utf8)
        return String(data: data, encoding: .utf8) ?? "{\"tasks\":[]}"
    }
}
