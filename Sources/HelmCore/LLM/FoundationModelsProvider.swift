import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct FoundationModelsProvider: LLMProvider, Sendable {
    public let kind: LLMBackendKind = .foundationModels
    public static let maxTokenCeiling: Int = 4_096

    public init() {}

    public static func estimateTokenCount(for text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        #if canImport(FoundationModels)
        let start = CFAbsoluteTimeGetCurrent()
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw LLMProviderError.modelUnavailable("Apple FoundationModels unavailable: \(String(describing: model.availability))")
        }

        let systemPrompt = LLMToolPromptCodec.buildSystemPrompt(
            baseSystemPrompt: request.systemPrompt,
            tools: request.tools
        )

        let combinedTokens = Self.estimateTokenCount(for: systemPrompt) + Self.estimateTokenCount(for: request.userPrompt)
        let userPromptToUse: String
        if combinedTokens > Self.maxTokenCeiling - 512 {
            let availableChars = max(512, (Self.maxTokenCeiling - 512 - Self.estimateTokenCount(for: systemPrompt)) * 3)
            if request.userPrompt.count > availableChars {
                userPromptToUse = String(request.userPrompt.prefix(availableChars))
            } else {
                userPromptToUse = request.userPrompt
            }
        } else {
            userPromptToUse = request.userPrompt
        }

        let content: String = try await LLMTimeoutRace.run(timeoutSeconds: request.timeoutSeconds) {
            let session = LanguageModelSession(model: model, instructions: systemPrompt)
            let response = try await session.respond(to: userPromptToUse)
            return response.content
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let toolCalls = !request.tools.isEmpty ? LLMToolPromptCodec.parseEnvelope(from: content).toolCalls : []
        return LLMResponse(
            text: content,
            toolCalls: toolCalls,
            usage: LLMUsage(
                inputTokens: Self.estimateTokenCount(for: systemPrompt + userPromptToUse),
                outputTokens: Self.estimateTokenCount(for: content)
            ),
            stopReason: "end_turn",
            latencyMs: elapsedMs
        )
        #else
        throw LLMProviderError.modelUnavailable("FoundationModels framework not available on this platform")
        #endif
    }
}
