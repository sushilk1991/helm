import Foundation
import os

public struct LLMToolSchema: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

public struct LLMToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct LLMUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let costUSD: Double?

    public init(inputTokens: Int, outputTokens: Int, cachedTokens: Int = 0, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.costUSD = costUSD
    }
}

public struct LLMRequest: Sendable, Equatable {
    public let requestID: UUID
    public let agentID: UUID
    public let projectID: UUID
    public let stepIndex: Int
    public let systemPrompt: String
    public let digestChannels: [String: String]
    public let userPrompt: String
    public let tools: [LLMToolSchema]
    public let model: String?
    public let timeoutSeconds: TimeInterval
    public let maxTokens: Int?
    public let workingDirectory: URL?

    public init(
        requestID: UUID = UUID(),
        agentID: UUID,
        projectID: UUID,
        stepIndex: Int,
        systemPrompt: String,
        digestChannels: [String: String] = [:],
        userPrompt: String,
        tools: [LLMToolSchema] = [],
        model: String? = nil,
        timeoutSeconds: TimeInterval = 60,
        maxTokens: Int? = nil,
        workingDirectory: URL? = nil
    ) {
        self.requestID = requestID
        self.agentID = agentID
        self.projectID = projectID
        self.stepIndex = stepIndex
        self.systemPrompt = systemPrompt
        self.digestChannels = digestChannels
        self.userPrompt = userPrompt
        self.tools = tools
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.maxTokens = maxTokens
        self.workingDirectory = workingDirectory
    }

    internal var validatedWorkingDirectory: URL? {
        guard let url = workingDirectory, url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }
}

public struct LLMResponse: Sendable, Equatable {
    public let text: String
    public let toolCalls: [LLMToolCall]
    public let usage: LLMUsage?
    public let stopReason: String
    public let latencyMs: Double

    public init(
        text: String,
        toolCalls: [LLMToolCall] = [],
        usage: LLMUsage? = nil,
        stopReason: String = "end_turn",
        latencyMs: Double = 0
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
        self.latencyMs = latencyMs
    }
}

public enum LLMProviderError: Error, Sendable, LocalizedError, Equatable {
    case timeout(TimeInterval)
    case processFailed(exitCode: Int32, stderr: String)
    case missingCredential(String)
    case networkFailure(String)
    case invalidResponse(String)
    case modelUnavailable(String)
    case tokenBudgetExceeded(estimatedTokens: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .timeout(let s): return "LLM provider timed out after \(s)s"
        case .processFailed(let code, let err): return "LLM CLI failed (exit \(code)): \(err)"
        case .missingCredential(let msg): return "Missing LLM credential: \(msg)"
        case .networkFailure(let msg): return "LLM network failure: \(msg)"
        case .invalidResponse(let msg): return "Invalid LLM response: \(msg)"
        case .modelUnavailable(let msg): return "LLM model unavailable: \(msg)"
        case .tokenBudgetExceeded(let est, let lim): return "Prompt estimated \(est) tokens exceeds \(lim)-token limit"
        }
    }
}

public protocol LLMProvider: Sendable {
    var kind: LLMBackendKind { get }
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

public struct LLMProviderRegistry: Sendable {
    private let providers: [LLMBackendKind: any LLMProvider]

    public init(providers: [LLMBackendKind: any LLMProvider]) {
        self.providers = providers
    }

    public static func makeDefault(
        mockProvider: (any LLMProvider)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LLMProviderRegistry {
        let resolvedMock = mockProvider ?? MockLLMProvider(environment: environment)
        return LLMProviderRegistry(providers: [
            .mock: resolvedMock,
            .claudeCLI: ClaudeCLIProvider(),
            .codexCLI: CodexCLIProvider(),
            .agyCLI: AgyCLIProvider(),
            .piCLI: PiCLIProvider(),
            .directHTTP: DirectHTTPProvider(environment: environment),
            .foundationModels: FoundationModelsProvider(),
        ])
    }

    public func provider(for kind: LLMBackendKind) throws -> any LLMProvider {
        guard let p = providers[kind] else {
            throw LLMProviderError.modelUnavailable("No provider registered for backend '\(kind.rawValue)'")
        }
        return p
    }
}

public enum LLMTimeoutRace {
    private enum Phase<T: Sendable> {
        case awaitingContinuation
        case pending(CheckedContinuation<T, Error>)
        case cancelledBeforeInstall
        case finished
    }

    private final class State<T: Sendable>: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Phase<T>>(initialState: .awaitingContinuation)
        private var opTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?

        func installContinuation(_ cont: CheckedContinuation<T, Error>) -> Bool {
            lock.withLock { phase in
                switch phase {
                case .awaitingContinuation:
                    phase = .pending(cont)
                    return true
                case .cancelledBeforeInstall:
                    phase = .finished
                    return false
                case .pending, .finished:
                    return false
                }
            }
        }

        func attachTasks(opTask: Task<Void, Never>, timerTask: Task<Void, Never>) {
            let shouldCancel = lock.withLock { phase -> Bool in
                if case .pending = phase {
                    self.opTask = opTask
                    self.timerTask = timerTask
                    return false
                }
                return true
            }
            if shouldCancel {
                opTask.cancel()
                timerTask.cancel()
            }
        }

        func resolve(with result: Result<T, Error>) {
            let extracted: (CheckedContinuation<T, Error>?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock { phase in
                switch phase {
                case .awaitingContinuation:
                    if case .failure(let err) = result, err is CancellationError {
                        phase = .cancelledBeforeInstall
                    }
                    return (nil, nil, nil)
                case .pending(let cont):
                    phase = .finished
                    let o = self.opTask
                    let t = self.timerTask
                    self.opTask = nil
                    self.timerTask = nil
                    return (cont, o, t)
                case .cancelledBeforeInstall, .finished:
                    return (nil, nil, nil)
                }
            }
            extracted.1?.cancel()
            extracted.2?.cancel()
            extracted.0?.resume(with: result)
        }
    }

    public static func run<T: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let boundedTimeout = max(0.05, timeoutSeconds.isFinite ? timeoutSeconds : 60.0)
        let state = State<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.installContinuation(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let opTask = Task {
                    do {
                        let value = try await operation()
                        state.resolve(with: .success(value))
                    } catch {
                        state.resolve(with: .failure(error))
                    }
                }
                let timerTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(boundedTimeout))
                        state.resolve(with: .failure(LLMProviderError.timeout(boundedTimeout)))
                    } catch {
                        // Cancelled when operation finishes or parent task cancels
                    }
                }
                state.attachTasks(opTask: opTask, timerTask: timerTask)
            }
        } onCancel: {
            state.resolve(with: .failure(CancellationError()))
        }
    }

    public static func completeWithTimeout(
        provider: any LLMProvider,
        request: LLMRequest,
        timeoutSeconds: TimeInterval
    ) async throws -> LLMResponse {
        try await run(timeoutSeconds: timeoutSeconds) {
            try await provider.complete(request)
        }
    }
}
