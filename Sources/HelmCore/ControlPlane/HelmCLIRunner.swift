import Foundation

public struct CLIExecutionOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum HelmCLIRunner {
    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandboxExecutorFactory: (@Sendable () -> (any SandboxExecutor)?)? = nil,
        browserServiceFactory: (@Sendable () -> (any BrowserOCRService)?)? = nil
    ) async -> CLIExecutionOutput {
        do {
            return try await dispatch(
                arguments: arguments,
                environment: environment,
                sandboxExecutorFactory: sandboxExecutorFactory,
                browserServiceFactory: browserServiceFactory
            )
        } catch {
            return CLIExecutionOutput(
                exitCode: 1,
                stdout: "",
                stderr: encodeErrorJSON(error.localizedDescription)
            )
        }
    }

    private static func dispatch(
        arguments: [String],
        environment: [String: String],
        sandboxExecutorFactory: (@Sendable () -> (any SandboxExecutor)?)?,
        browserServiceFactory: (@Sendable () -> (any BrowserOCRService)?)?
    ) async throws -> CLIExecutionOutput {
        guard !arguments.isEmpty else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON(usageText()))
        }

        if arguments.first == "--help" || arguments.first == "-h" || arguments.first == "help" {
            return CLIExecutionOutput(exitCode: 0, stdout: "{\"help\":true}", stderr: usageText())
        }

        let (dbPath, rest) = extractDBPath(from: arguments, environment: environment)
        guard let group = rest.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing subcommand.\n\(usageText())"))
        }

        let tail = Array(rest.dropFirst())
        switch group {
        case "project":
            return try await handleProject(args: tail, dbPath: dbPath)
        case "agent":
            return try await handleAgent(args: tail, dbPath: dbPath)
        case "state":
            return try await handleState(args: tail, dbPath: dbPath)
        case "run":
            return try await handleRun(
                args: tail,
                dbPath: dbPath,
                environment: environment,
                sandboxExecutorFactory: sandboxExecutorFactory,
                browserServiceFactory: browserServiceFactory
            )
        case "exceptions":
            return try await handleExceptions(args: tail, dbPath: dbPath)
        case "sandbox":
            let payload = """
            {"status":"not_implemented","milestone":"M2","module":"HelmIsolation"}
            """
            return CLIExecutionOutput(exitCode: 69, stdout: payload, stderr: "sandbox exec is scheduled for Milestone M2.\n")
        case "browser":
            let payload = """
            {"status":"not_implemented","milestone":"M3","module":"HelmBrowser"}
            """
            return CLIExecutionOutput(exitCode: 69, stdout: payload, stderr: "browser act is scheduled for Milestone M3.\n")
        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown command '\(group)'."))
        }
    }

    private static func handleProject(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing project subcommand (create|list|show)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "create":
            let name = try requireFlag("name", in: flags)
            let goal = try requireFlag("goal", in: flags)
            let workspace = try requireFlag("workspace", in: flags)
            let wsURL = URL(fileURLWithPath: workspace)
            let project = try await cp.createProject(name: name, goal: goal, workspaceRoot: wsURL)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(project), stderr: "")

        case "list":
            let projects = try await cp.listProjects()
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(projects), stderr: "")

        case "show":
            let idStr = try requireFlag("id", in: flags)
            guard let id = UUID(uuidString: idStr) else {
                throw ControlPlaneError.invalidInput("Invalid UUID '\(idStr)'")
            }
            guard let project = try await cp.fetchProject(id: id) else {
                throw ControlPlaneError.projectNotFound(id)
            }
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(project), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown project subcommand '\(sub)'."))
        }
    }

    private static func handleAgent(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing agent subcommand (add|list)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "add":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let name = try requireFlag("name", in: flags)
            let roleRaw = try requireFlag("role", in: flags)
            let goal = try requireFlag("goal", in: flags)
            let backendRaw = flags.values["backend"] ?? "mock"
            guard let backend = LLMBackendKind.parse(backendRaw) else {
                throw ControlPlaneError.invalidInput("Unsupported backend '\(backendRaw)'. Expected mock|claude|codex|http|foundation.")
            }

            let capabilities: Set<AgentCapability>
            if let csv = flags.values["capabilities"] {
                var parsedCaps: Set<AgentCapability> = []
                for token in csv.split(separator: ",") {
                    let item = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !item.isEmpty else { continue }
                    guard let cap = AgentCapability.parse(item) else {
                        throw ControlPlaneError.invalidInput("Unsupported capability '\(item)'.")
                    }
                    parsedCaps.insert(cap)
                }
                capabilities = parsedCaps
            } else {
                capabilities = [.readSharedState, .proposeSharedState, .requestHumanDecision]
            }

            let agent = try await cp.addAgent(
                projectID: projectID,
                name: name,
                role: AgentRole.parse(roleRaw),
                goal: goal,
                backend: backend,
                capabilities: capabilities
            )
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(agent), stderr: "")

        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let agents = try await cp.listAgents(projectID: projectID)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(agents), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown agent subcommand '\(sub)'."))
        }
    }

    private static func handleState(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing state subcommand (list)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let entries = try await cp.listSharedState(projectID: projectID)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(entries), stderr: "")
        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown state subcommand '\(sub)'."))
        }
    }

    private static func handleRun(
        args: [String],
        dbPath: String,
        environment: [String: String],
        sandboxExecutorFactory: (@Sendable () -> (any SandboxExecutor)?)?,
        browserServiceFactory: (@Sendable () -> (any BrowserOCRService)?)?
    ) async throws -> CLIExecutionOutput {
        let flags = try parseFlags(args)
        let projStr = try requireFlag("project", in: flags)
        guard let projectID = UUID(uuidString: projStr) else {
            throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
        }

        let maxSteps: Int?
        if let maxStr = flags.values["max-steps"] {
            guard let val = Int(maxStr), val >= 0 else {
                throw ControlPlaneError.invalidInput("Invalid --max-steps '\(maxStr)'")
            }
            maxSteps = val
        } else {
            maxSteps = nil
        }

        let simulated: SimulatedConditionKind?
        if flags.booleans.contains("simulate-stall") {
            simulated = .stall
        } else if flags.booleans.contains("simulate-drift") {
            simulated = .drift
        } else if flags.booleans.contains("simulate-decision") {
            simulated = .humanDecision
        } else if flags.booleans.contains("simulate-cycle") || environment["HELM_SIMULATE_TASK_CYCLE"] == "1" {
            simulated = .cycle
        } else {
            simulated = nil
        }

        let registry = LLMProviderRegistry.makeDefault(environment: environment)
        let sandboxExecutor = sandboxExecutorFactory?()
        let browserService = browserServiceFactory?()
        let cp = try await MainActor.run {
            try HelmControlPlane(
                databasePath: dbPath,
                providerRegistry: registry,
                sandboxExecutor: sandboxExecutor,
                browserService: browserService,
                environment: environment
            )
        }
        let report: ProjectRunReport
        do {
            report = try await cp.runProjectUntilSettled(
                projectID: projectID,
                maxSteps: maxSteps,
                simulatedCondition: simulated
            )
        } catch {
            await sandboxExecutor?.shutdownWorkspace(projectID)
            throw error
        }
        await sandboxExecutor?.shutdownWorkspace(projectID)
        return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(report), stderr: "")
    }

    private static func handleExceptions(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing exceptions subcommand (list|resolve)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let openOnly = flags.booleans.contains("open-only")
            let alerts = try await cp.listExceptions(projectID: projectID, openOnly: openOnly)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(alerts), stderr: "")

        case "resolve":
            let excStr = try requireFlag("id", in: flags)
            guard let excID = UUID(uuidString: excStr) else {
                throw ControlPlaneError.invalidInput("Invalid exception UUID '\(excStr)'")
            }
            let action = try requireFlag("action", in: flags).lowercased()
            let resolution: ExceptionResolution
            switch action {
            case "approve": resolution = .approve
            case "retry": resolution = .retry
            case "redirect": resolution = .redirect(note: flags.values["note"] ?? "")
            case "abort": resolution = .abort
            default:
                throw ControlPlaneError.invalidInput("Invalid --action '\(action)'. Expected approve|retry|redirect|abort.")
            }
            let updated = try await cp.resolveException(exceptionID: excID, resolution: resolution)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(updated), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown exceptions subcommand '\(sub)'."))
        }
    }

    // MARK: - Argument & JSON Helpers

    private struct ParsedFlags {
        var values: [String: String] = [:]
        var booleans: Set<String> = []
    }

    private static func extractDBPath(from args: [String], environment: [String: String]) -> (String, [String]) {
        var filtered: [String] = []
        var explicitDB: String?
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--db", idx + 1 < args.count {
                explicitDB = args[idx + 1]
                idx += 2
            } else if arg.hasPrefix("--db=") {
                explicitDB = String(arg.dropFirst(5))
                idx += 1
            } else {
                filtered.append(arg)
                idx += 1
            }
        }
        let resolved = explicitDB
            ?? environment["HELM_DB_PATH"]
            ?? HelmDatabase.defaultDatabasePath()
        return (resolved, filtered)
    }

    private static func parseFlags(_ args: [String]) throws -> ParsedFlags {
        var parsed = ParsedFlags()
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            guard arg.hasPrefix("--") else {
                throw ControlPlaneError.invalidInput("Unexpected positional argument '\(arg)'")
            }
            let stripped = String(arg.dropFirst(2))
            if let eqIdx = stripped.firstIndex(of: "=") {
                let key = String(stripped[..<eqIdx])
                let val = String(stripped[stripped.index(after: eqIdx)...])
                parsed.values[key] = val
                idx += 1
            } else if ["simulate-stall", "simulate-drift", "simulate-decision", "simulate-cycle", "open-only"].contains(stripped) {
                parsed.booleans.insert(stripped)
                idx += 1
            } else if idx + 1 < args.count {
                parsed.values[stripped] = args[idx + 1]
                idx += 2
            } else {
                throw ControlPlaneError.invalidInput("Flag '--\(stripped)' requires a value.")
            }
        }
        return parsed
    }

    private static func requireFlag(_ name: String, in flags: ParsedFlags) throws -> String {
        guard let value = flags.values[name] else {
            throw ControlPlaneError.invalidInput("Missing required flag '--\(name)'")
        }
        return value
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try HelmJSON.makeEncoder(prettyPrinted: true).encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func encodeErrorJSON(_ message: String) -> String {
        let payload = ["error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\":\"unknown error\"}"
    }

    private static func usageText() -> String {
        """
        Usage:
          helmctl project create --name <str> --goal <str> --workspace <dir> [--db <path>]
          helmctl project list [--db <path>]
          helmctl project show --id <uuid> [--db <path>]
          helmctl agent add --project <uuid> --name <str> --role <role> --goal <str> --backend mock|claude|codex|http|foundation [--capabilities <csv>] [--db <path>]
          helmctl agent list --project <uuid> [--db <path>]
          helmctl state list --project <uuid> [--db <path>]
          helmctl run --project <uuid> [--simulate-stall | --simulate-drift | --simulate-decision | --simulate-cycle] [--max-steps <N>] [--db <path>]
          helmctl exceptions list --project <uuid> [--open-only] [--db <path>]
          helmctl exceptions resolve --id <uuid> --action approve|retry|redirect|abort [--note <str>] [--db <path>]
          helmctl sandbox exec ... (M2 stub)
          helmctl browser act ... (M3 stub)
        """
    }
}
