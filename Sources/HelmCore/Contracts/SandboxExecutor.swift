import Foundation

public enum IsolationMode: String, Codable, Sendable {
    case virtualizationVM   // Primary: Alpine ARM64 VZLinuxBootLoader micro-VM
    case seatbeltSandbox    // Fallback / macOS-native: /usr/bin/sandbox-exec + /bin/zsh
}

public struct ExecutionRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public let workspacePath: URL
    public let command: String
    public let preferredMode: IsolationMode?
    public let timeoutSeconds: TimeInterval
    public let maxOutputBytes: Int
    public let environment: [String: String]

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        workspacePath: URL,
        command: String,
        preferredMode: IsolationMode? = nil,
        timeoutSeconds: TimeInterval = 60,
        maxOutputBytes: Int = 262_144,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.projectID = projectID
        self.workspacePath = workspacePath
        self.command = command
        self.preferredMode = preferredMode
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
        self.environment = environment
    }
}

public struct ExecutionResult: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let modeUsed: IsolationMode
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let truncatedOutput: Bool
    public let durationMs: Double

    public init(
        requestID: UUID,
        modeUsed: IsolationMode,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        truncatedOutput: Bool,
        durationMs: Double
    ) {
        self.requestID = requestID
        self.modeUsed = modeUsed
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncatedOutput = truncatedOutput
        self.durationMs = durationMs
    }
}

public protocol SandboxExecutor: Sendable {
    func execute(_ request: ExecutionRequest) async throws -> ExecutionResult
    func shutdownWorkspace(_ projectID: UUID) async
}
