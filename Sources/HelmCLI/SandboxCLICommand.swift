import Foundation
import HelmCore
import HelmIsolation

enum SandboxCLICommand {
    static func handles(arguments: [String]) -> Bool {
        let stripped = stripDBFlag(from: arguments)
        return stripped.first == "sandbox"
    }

    static func run(arguments: [String]) async -> CLIExecutionOutput {
        let stripped = stripDBFlag(from: arguments)
        guard stripped.first == "sandbox" else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Expected 'sandbox' command."))
        }
        let tail = Array(stripped.dropFirst())
        guard let sub = tail.first else {
            return CLIExecutionOutput(
                exitCode: 2,
                stdout: "",
                stderr: encodeErrorJSON("Missing sandbox subcommand. Usage: helmctl sandbox exec --workspace <dir> --cmd <shell> [--mode vm|seatbelt] [--timeout <sec>] [--max-output-bytes <N>] [--project <uuid>]")
            )
        }
        guard sub == "exec" else {
            return CLIExecutionOutput(
                exitCode: 2,
                stdout: "",
                stderr: encodeErrorJSON("Unknown sandbox subcommand '\(sub)'. Expected 'exec'.")
            )
        }

        do {
            let flags = try parseFlags(Array(tail.dropFirst()))
            let workspace = try requireFlag("workspace", in: flags)
            let command = try requireFlag("cmd", in: flags)

            let preferredMode: IsolationMode?
            if let modeRaw = flags.values["mode"] {
                switch modeRaw.lowercased() {
                case "vm", "virtualizationvm":
                    preferredMode = .virtualizationVM
                case "seatbelt", "seatbeltsandbox":
                    preferredMode = .seatbeltSandbox
                default:
                    return CLIExecutionOutput(
                        exitCode: 2,
                        stdout: "",
                        stderr: encodeErrorJSON("Invalid --mode '\(modeRaw)'. Expected vm|seatbelt.")
                    )
                }
            } else {
                preferredMode = nil
            }

            let timeoutSeconds: TimeInterval
            if let timeoutRaw = flags.values["timeout"] {
                guard let parsed = Double(timeoutRaw), parsed.isFinite, parsed > 0 else {
                    return CLIExecutionOutput(
                        exitCode: 2,
                        stdout: "",
                        stderr: encodeErrorJSON("Invalid --timeout '\(timeoutRaw)'. Expected positive number of seconds.")
                    )
                }
                timeoutSeconds = parsed
            } else {
                timeoutSeconds = 60
            }

            let maxOutputBytes: Int
            if let maxRaw = flags.values["max-output-bytes"] ?? flags.values["max-bytes"] {
                guard let parsed = Int(maxRaw), parsed >= 0 else {
                    return CLIExecutionOutput(
                        exitCode: 2,
                        stdout: "",
                        stderr: encodeErrorJSON("Invalid --max-output-bytes '\(maxRaw)'. Expected non-negative integer.")
                    )
                }
                maxOutputBytes = parsed
            } else {
                maxOutputBytes = 262_144
            }

            let projectID: UUID
            if let projRaw = flags.values["project"] {
                guard let parsed = UUID(uuidString: projRaw) else {
                    return CLIExecutionOutput(
                        exitCode: 2,
                        stdout: "",
                        stderr: encodeErrorJSON("Invalid --project UUID '\(projRaw)'.")
                    )
                }
                projectID = parsed
            } else {
                projectID = UUID()
            }

            let request = ExecutionRequest(
                projectID: projectID,
                workspacePath: URL(fileURLWithPath: workspace),
                command: command,
                preferredMode: preferredMode,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: maxOutputBytes
            )

            let router = ExecutionRouter()
            do {
                let result = try await router.execute(request)
                await router.shutdownWorkspace(projectID)
                let data = try HelmJSON.makeEncoder(prettyPrinted: true).encode(result)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                return CLIExecutionOutput(exitCode: 0, stdout: json, stderr: "")
            } catch {
                await router.shutdownWorkspace(projectID)
                return CLIExecutionOutput(
                    exitCode: 1,
                    stdout: "",
                    stderr: encodeErrorJSON(error.localizedDescription)
                )
            }
        } catch {
            return CLIExecutionOutput(
                exitCode: 2,
                stdout: "",
                stderr: encodeErrorJSON(error.localizedDescription)
            )
        }
    }

    private static func stripDBFlag(from args: [String]) -> [String] {
        var filtered: [String] = []
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--db", idx + 1 < args.count {
                idx += 2
            } else if arg.hasPrefix("--db=") {
                idx += 1
            } else {
                filtered.append(arg)
                idx += 1
            }
        }
        return filtered
    }

    private static let allowedExecFlags: Set<String> = [
        "workspace",
        "cmd",
        "mode",
        "timeout",
        "max-output-bytes",
        "max-bytes",
        "project",
    ]

    private struct ParsedFlags {
        var values: [String: String] = [:]
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
                guard allowedExecFlags.contains(key) else {
                    throw ControlPlaneError.invalidInput("Unknown flag '--\(key)'")
                }
                let val = String(stripped[stripped.index(after: eqIdx)...])
                parsed.values[key] = val
                idx += 1
            } else {
                guard allowedExecFlags.contains(stripped) else {
                    throw ControlPlaneError.invalidInput("Unknown flag '--\(stripped)'")
                }
                guard idx + 1 < args.count else {
                    throw ControlPlaneError.invalidInput("Flag '--\(stripped)' requires a value.")
                }
                parsed.values[stripped] = args[idx + 1]
                idx += 2
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

    private static func encodeErrorJSON(_ message: String) -> String {
        let payload = ["error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\":\"unknown error\"}"
    }
}
