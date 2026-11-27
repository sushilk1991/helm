import Foundation

public struct ParsedToolEnvelope: Sendable, Equatable {
    public let thought: String?
    public let toolCalls: [LLMToolCall]
    public let finalResponse: String?
    public let steadyOK: Bool?

    public init(
        thought: String? = nil,
        toolCalls: [LLMToolCall] = [],
        finalResponse: String? = nil,
        steadyOK: Bool? = nil
    ) {
        self.thought = thought
        self.toolCalls = toolCalls
        self.finalResponse = finalResponse
        self.steadyOK = steadyOK
    }
}

public enum LLMToolPromptCodec {
    public static func buildSystemPrompt(baseSystemPrompt: String, tools: [LLMToolSchema]) -> String {
        guard !tools.isEmpty else { return baseSystemPrompt }
        let toolLines = tools.map { tool in
            "- \(tool.name): \(tool.description) | schema: \(tool.parametersJSONSchema)"
        }.joined(separator: "\n")

        return """
        \(baseSystemPrompt)

        You MUST reply with a single valid JSON object matching this exact contract (no markdown prose outside JSON):
        {
          "thought": "brief reasoning",
          "tool_calls": [{"id": "call_1", "name": "<tool_name>", "arguments": { ... }}],
          "final_response": "<optional final summary when done>",
          "steady_ok": false
        }

        Available tools:
        \(toolLines)
        """
    }

    public static func parseEnvelope(from rawText: String) -> ParsedToolEnvelope {
        let candidates = extractJSONCandidates(from: rawText)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let thought = obj["thought"] as? String
            let finalResponse = obj["final_response"] as? String ?? obj["finalResponse"] as? String
            let steadyOK = obj["steady_ok"] as? Bool ?? obj["steadyOK"] as? Bool

            var calls: [LLMToolCall] = []
            let rawCalls = (obj["tool_calls"] as? [[String: Any]]) ?? (obj["toolCalls"] as? [[String: Any]]) ?? []
            for (idx, callObj) in rawCalls.enumerated() {
                guard let name = callObj["name"] as? String, !name.isEmpty else { continue }
                let id = (callObj["id"] as? String) ?? "call_\(idx + 1)"
                let argsJSON: String
                if let argString = callObj["arguments"] as? String {
                    argsJSON = argString
                } else if let argString = callObj["argumentsJSON"] as? String {
                    argsJSON = argString
                } else if let argDict = callObj["arguments"],
                          JSONSerialization.isValidJSONObject(argDict),
                          let argData = try? JSONSerialization.data(withJSONObject: argDict, options: [.sortedKeys]),
                          let str = String(data: argData, encoding: .utf8) {
                    argsJSON = str
                } else {
                    argsJSON = "{}"
                }
                calls.append(LLMToolCall(id: id, name: name, argumentsJSON: argsJSON))
            }

            if !calls.isEmpty || finalResponse != nil || steadyOK != nil || thought != nil {
                return ParsedToolEnvelope(
                    thought: thought,
                    toolCalls: calls,
                    finalResponse: finalResponse,
                    steadyOK: steadyOK
                )
            }
        }
        return ParsedToolEnvelope(thought: nil, toolCalls: [], finalResponse: rawText, steadyOK: nil)
    }

    private static func extractJSONCandidates(from raw: String) -> [String] {
        var results: [String] = []
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            results.append(trimmed)
        }

        // Fenced ```json ... ``` or ``` ... ```
        let pattern = #"```(?:json)?\s*([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                let inner = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty {
                    results.append(inner)
                }
            }
        }

        // First balanced {...} slice
        if let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first < last {
            results.append(String(raw[first...last]))
        }
        return results
    }
}
