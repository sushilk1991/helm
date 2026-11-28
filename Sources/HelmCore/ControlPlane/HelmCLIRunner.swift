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
        case "chat":
            return try await handleChat(
                args: tail,
                dbPath: dbPath,
                environment: environment,
                sandboxExecutorFactory: sandboxExecutorFactory,
                browserServiceFactory: browserServiceFactory
            )
        case "work-feed":
            return try await handleWorkFeed(args: tail, dbPath: dbPath)
        case "tasks":
            return try await handleTasks(args: tail, dbPath: dbPath)
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
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing project subcommand (create|list|show|update-trust)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "create":
            let name = try requireFlag("name", in: flags)
            let goal = try requireFlag("goal", in: flags)
            let workspace = try requireFlag("workspace", in: flags)
            let trustPolicy: SandboxTrustPolicy
            if let rawTrust = flags.values["trust-policy"] {
                guard let parsed = SandboxTrustPolicy(rawValue: rawTrust) else {
                    throw ControlPlaneError.invalidInput("Unsupported trust policy '\(rawTrust)'. Expected sandboxed|standardWorkspace|trustedFullAccess.")
                }
                trustPolicy = parsed
            } else {
                trustPolicy = .standardWorkspace
            }
            let wsURL = URL(fileURLWithPath: workspace)
            let project = try await cp.createProject(
                name: name,
                goal: goal,
                workspaceRoot: wsURL,
                sandboxTrustPolicy: trustPolicy
            )
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

        case "update-trust":
            let idStr = try requireFlag("id", in: flags)
            guard let id = UUID(uuidString: idStr) else {
                throw ControlPlaneError.invalidInput("Invalid UUID '\(idStr)'")
            }
            let rawTrust = try requireFlag("trust-policy", in: flags)
            guard let policy = SandboxTrustPolicy(rawValue: rawTrust) else {
                throw ControlPlaneError.invalidInput("Unsupported trust policy '\(rawTrust)'. Expected sandboxed|standardWorkspace|trustedFullAccess.")
            }
            let updated = try await cp.updateProjectTrustPolicy(projectID: id, policy: policy)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(updated), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown project subcommand '\(sub)'."))
        }
    }

    private static func handleAgent(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing agent subcommand (add|list|update)."))
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
            let role = AgentRole.parse(roleRaw)
            let goal = try requireFlag("goal", in: flags)
            let backendRaw = flags.values["backend"] ?? "mock"
            guard let backend = LLMBackendKind.parse(backendRaw) else {
                throw ControlPlaneError.invalidInput("Unsupported backend '\(backendRaw)'. Expected mock|claude|codex|agy|pi|http|foundation.")
            }

            let personality: AgentPersonality?
            if let rawPers = flags.values["personality"] {
                guard let parsed = AgentPersonality(rawValue: rawPers) ?? AgentPersonality.parse(rawPers) else {
                    throw ControlPlaneError.invalidInput("Unsupported personality '\(rawPers)'.")
                }
                personality = parsed
            } else {
                personality = nil
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
                capabilities = AgentProfile.RolePreset.preset(for: role).capabilities
            }

            let agent = try await cp.addAgent(
                projectID: projectID,
                name: name,
                role: role,
                goal: goal,
                backend: backend,
                capabilities: capabilities,
                personality: personality,
                systemPrompt: flags.values["system-prompt"]
            )
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(agent), stderr: "")

        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let agents = try await cp.listAgents(projectID: projectID)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(agents), stderr: "")

        case "update":
            let idStr = try requireFlag("id", in: flags)
            guard let agentID = UUID(uuidString: idStr) else {
                throw ControlPlaneError.invalidInput("Invalid agent UUID '\(idStr)'")
            }

            let parsedBackend: LLMBackendKind?
            if let rawBackend = flags.values["backend"] {
                guard let b = LLMBackendKind.parse(rawBackend) else {
                    throw ControlPlaneError.invalidInput("Unsupported backend '\(rawBackend)'. Expected mock|claude|codex|agy|pi|http|foundation.")
                }
                parsedBackend = b
            } else {
                parsedBackend = nil
            }

            let parsedPersonality: AgentPersonality?
            if let rawPers = flags.values["personality"] {
                guard let p = AgentPersonality(rawValue: rawPers) ?? AgentPersonality.parse(rawPers) else {
                    throw ControlPlaneError.invalidInput("Unsupported personality '\(rawPers)'.")
                }
                parsedPersonality = p
            } else {
                parsedPersonality = nil
            }

            let nameArg = flags.values["name"]
            let goalArg = flags.values["goal"]
            var resolvedPrompt = flags.values["system-prompt"]
            if resolvedPrompt == nil && flags.booleans.contains("apply-template") {
                guard let existing = try await cp.database.fetchAgent(id: agentID) else {
                    throw HelmDatabaseError.notFound("Agent \(agentID.uuidString)")
                }
                resolvedPrompt = AgentProfile.buildSystemPromptTemplate(
                    role: existing.role,
                    personality: parsedPersonality ?? existing.personality,
                    goal: goalArg ?? existing.goal,
                    notes: existing.personalityNotes
                )
            }

            let updated = try await cp.updateAgent(
                agentID: agentID,
                name: nameArg,
                goal: goalArg,
                backend: parsedBackend,
                personality: parsedPersonality,
                systemPrompt: resolvedPrompt
            )
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(updated), stderr: "")

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

    private static func handleChat(
        args: [String],
        dbPath: String,
        environment: [String: String],
        sandboxExecutorFactory: (@Sendable () -> (any SandboxExecutor)?)?,
        browserServiceFactory: (@Sendable () -> (any BrowserOCRService)?)?
    ) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing chat subcommand (send|list)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))

        switch sub {
        case "send":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let rawChannel = try requireFlag("channel", in: flags)
            let channel = try parseChatChannel(rawChannel)
            let content = try requireFlag("content", in: flags)
            let wait = flags.booleans.contains("wait")

            let registry = LLMProviderRegistry.makeDefault(environment: environment)
            let sandboxExecutor = wait ? sandboxExecutorFactory?() : nil
            let browserService = wait ? browserServiceFactory?() : nil
            let cp = try await MainActor.run {
                try HelmControlPlane(
                    databasePath: dbPath,
                    providerRegistry: registry,
                    sandboxExecutor: sandboxExecutor,
                    browserService: browserService,
                    environment: environment
                )
            }

            if wait {
                let sent: ChatMessage
                do {
                    sent = try await cp.sendChatMessageAndWait(
                        projectID: projectID,
                        channel: channel,
                        content: content
                    )
                } catch {
                    await sandboxExecutor?.shutdownWorkspace(projectID)
                    throw error
                }
                await sandboxExecutor?.shutdownWorkspace(projectID)
                return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(sent), stderr: "")
            } else {
                let sent = try await cp.sendChatMessage(
                    projectID: projectID,
                    channel: channel,
                    content: content
                )
                return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(sent), stderr: "")
            }

        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let channel: ChatChannelKind?
            if let rawChannel = flags.values["channel"] {
                channel = try parseChatChannel(rawChannel)
            } else {
                channel = nil
            }
            let limit: Int
            if let rawLimit = flags.values["limit"] {
                guard let val = Int(rawLimit), val >= 0 else {
                    throw ControlPlaneError.invalidInput("Invalid --limit '\(rawLimit)'")
                }
                limit = val
            } else {
                limit = 200
            }
            let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }
            let messages = try await cp.listChatMessages(projectID: projectID, channel: channel, limit: limit)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(messages), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown chat subcommand '\(sub)'."))
        }
    }

    private static func handleWorkFeed(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing work-feed subcommand (list)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let agentID: UUID?
            if let agentStr = flags.values["agent"] {
                guard let parsed = UUID(uuidString: agentStr) else {
                    throw ControlPlaneError.invalidInput("Invalid agent UUID '\(agentStr)'")
                }
                agentID = parsed
            } else {
                agentID = nil
            }
            let limit: Int
            if let rawLimit = flags.values["limit"] {
                guard let val = Int(rawLimit), val >= 0 else {
                    throw ControlPlaneError.invalidInput("Invalid --limit '\(rawLimit)'")
                }
                limit = val
            } else {
                limit = 200
            }
            let entries = try await cp.listAgentWorkFeed(projectID: projectID, agentID: agentID, limit: limit)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(entries), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown work-feed subcommand '\(sub)'."))
        }
    }

    private static func handleTasks(args: [String], dbPath: String) async throws -> CLIExecutionOutput {
        guard let sub = args.first else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Missing tasks subcommand (list)."))
        }
        let flags = try parseFlags(Array(args.dropFirst()))
        let cp = try await MainActor.run { try HelmControlPlane(databasePath: dbPath) }

        switch sub {
        case "list":
            let projStr = try requireFlag("project", in: flags)
            guard let projectID = UUID(uuidString: projStr) else {
                throw ControlPlaneError.invalidInput("Invalid project UUID '\(projStr)'")
            }
            let tasks = try await cp.listTasks(projectID: projectID)
            return CLIExecutionOutput(exitCode: 0, stdout: try encodeJSON(tasks), stderr: "")

        default:
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Unknown tasks subcommand '\(sub)'."))
        }
    }

    private static func parseChatChannel(_ raw: String) throws -> ChatChannelKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "crew" {
            return .crew
        }
        if trimmed.lowercased().hasPrefix("direct:") {
            let uuidPart = String(trimmed.dropFirst("direct:".count))
            if let uuid = UUID(uuidString: uuidPart) {
                return .direct(agentID: uuid)
            }
        }
        if let parsed = ChatChannelKind(channelKey: trimmed) {
            return parsed
        }
        throw ControlPlaneError.invalidInput("Invalid chat channel '\(raw)'. Expected 'crew' or 'direct:<agent_uuid>'.")
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
            } else if ["simulate-stall", "simulate-drift", "simulate-decision", "simulate-cycle", "open-only", "wait", "apply-template"].contains(stripped) {
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
          helmctl project create --name <str> --goal <str> --workspace <dir> [--trust-policy sandboxed|standardWorkspace|trustedFullAccess] [--db <path>]
          helmctl project list [--db <path>]
          helmctl project show --id <uuid> [--db <path>]
          helmctl project update-trust --id <uuid> --trust-policy sandboxed|standardWorkspace|trustedFullAccess [--db <path>]
          helmctl agent add --project <uuid> --name <str> --role <role> --goal <str> [--backend mock|claude|codex|agy|pi|http|foundation] [--personality <p>] [--system-prompt <str>] [--capabilities <csv>] [--db <path>]
          helmctl agent list --project <uuid> [--db <path>]
          helmctl agent update --id <uuid> [--name <str>] [--goal <str>] [--system-prompt <str>] [--personality <p>] [--backend <b>] [--apply-template] [--db <path>]
          helmctl chat send --project <uuid> --channel crew|direct:<agent_uuid> --content <str> [--wait] [--db <path>]
          helmctl chat list --project <uuid> [--channel crew|direct:<agent_uuid>] [--limit <N>] [--db <path>]
          helmctl work-feed list --project <uuid> [--agent <uuid>] [--limit <N>] [--db <path>]
          helmctl tasks list --project <uuid> [--db <path>]
          helmctl state list --project <uuid> [--db <path>]
          helmctl run --project <uuid> [--simulate-stall | --simulate-drift | --simulate-decision | --simulate-cycle] [--max-steps <N>] [--db <path>]
          helmctl exceptions list --project <uuid> [--open-only] [--db <path>]
          helmctl exceptions resolve --id <uuid> --action approve|retry|redirect|abort [--note <str>] [--db <path>]
          helmctl sandbox exec ...
          helmctl browser act ...
        """
    }
}
