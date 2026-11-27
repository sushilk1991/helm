import Foundation
import HelmBrowser
import HelmCore

enum BrowserCLICommand {
    static func handles(arguments: [String]) -> Bool {
        let stripped = stripDBFlag(from: arguments)
        return stripped.first == "browser"
    }

    static func run(arguments: [String]) async -> CLIExecutionOutput {
        let stripped = stripDBFlag(from: arguments)
        guard stripped.first == "browser" else {
            return CLIExecutionOutput(exitCode: 2, stdout: "", stderr: encodeErrorJSON("Expected 'browser' command."))
        }

        let tail = Array(stripped.dropFirst())
        guard let sub = tail.first else {
            return CLIExecutionOutput(
                exitCode: 2,
                stdout: "",
                stderr: encodeErrorJSON("Missing browser subcommand. Usage: \(usageText)")
            )
        }

        if sub == "--help" || sub == "-h" || sub == "help" {
            return CLIExecutionOutput(exitCode: 0, stdout: "{\"help\":true}", stderr: usageText + "\n")
        }

        guard sub == "act" else {
            return CLIExecutionOutput(
                exitCode: 2,
                stdout: "",
                stderr: encodeErrorJSON("Unknown browser subcommand '\(sub)'. Expected 'act'.")
            )
        }

        let actArgs = Array(tail.dropFirst())
        if actArgs.contains("--help") || actArgs.contains("-h") {
            return CLIExecutionOutput(exitCode: 0, stdout: "{\"help\":true}", stderr: usageText + "\n")
        }

        let options: ParsedActOptions
        do {
            options = try parseActOptions(actArgs)
        } catch {
            return CLIExecutionOutput(
                exitCode: 2,
                stdout: "",
                stderr: encodeErrorJSON(error.localizedDescription)
            )
        }

        let screenshotURL: URL
        if let outPath = options.screenshotOut {
            screenshotURL = URL(fileURLWithPath: outPath)
        } else {
            screenshotURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("helm_browser_shot_\(UUID().uuidString).png")
        }

        var actions: [BrowserAction] = [.navigate(url: options.url)]
        for pair in options.types {
            actions.append(.typeText(selectorOrOCR: pair.target, text: pair.value, submit: false))
        }
        if let clickCSS = options.clickCSS {
            actions.append(.clickCSS(x: clickCSS.x, y: clickCSS.y))
        }
        if let clickOCR = options.clickOCR {
            actions.append(.clickOCRText(query: clickOCR))
        }
        if let evalJS = options.evalJS {
            actions.append(.evaluateJS(script: evalJS))
        }

        let tool = BrowseReadActTool()
        let timeoutSeconds = options.timeoutSeconds
        let actionSequence = actions

        do {
            let cliOutput: BrowserObservationCLIOutput = try await withThrowingTaskGroup(of: BrowserObservationCLIOutput.self) { group in
                group.addTask {
                    let sessionID = try await tool.openSession(projectID: UUID())
                    do {
                        var lastReport: BrowserActionReport?
                        for (index, action) in actionSequence.enumerated() {
                            let isFinal = (index == actionSequence.count - 1)
                            lastReport = try await tool.performDetailed(
                                action,
                                sessionID: sessionID,
                                screenshotOutURL: isFinal ? screenshotURL : nil,
                                timeoutSeconds: timeoutSeconds
                            )
                        }
                        await tool.closeSession(sessionID)
                        guard let finalReport = lastReport else {
                            throw HelmBrowserError.cdpProtocolError("No browser observation produced.")
                        }
                        return finalReport.toCLIOutput()
                    } catch {
                        await tool.closeSession(sessionID)
                        throw error
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    await tool.closeAllSessions()
                    throw HelmBrowserError.timeout(timeoutSeconds)
                }
                guard let first = try await group.next() else {
                    throw HelmBrowserError.timeout(timeoutSeconds)
                }
                group.cancelAll()
                return first
            }

            let data = try HelmJSON.makeEncoder(prettyPrinted: true).encode(cliOutput)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return CLIExecutionOutput(exitCode: 0, stdout: json, stderr: "")
        } catch {
            await tool.closeAllSessions()
            if options.screenshotOut == nil {
                try? FileManager.default.removeItem(at: screenshotURL)
            }
            return CLIExecutionOutput(
                exitCode: 1,
                stdout: "",
                stderr: encodeErrorJSON(error.localizedDescription)
            )
        }
    }

    // MARK: - Argument Parsing

    private struct ParsedActOptions: Sendable {
        let url: String
        let clickOCR: String?
        let clickCSS: (x: Double, y: Double)?
        let types: [(target: String, value: String)]
        let evalJS: String?
        let screenshotOut: String?
        let timeoutSeconds: TimeInterval
    }

    private static let usageText = """
    helmctl browser act --url <url> [--click-ocr <text>] [--click-css <x,y>] [--type <target>=<val>]... [--eval-js <script>] [--screenshot-out <path>] [--timeout <sec>]
    """

    private static func parseActOptions(_ args: [String]) throws -> ParsedActOptions {
        var url: String?
        var clickOCR: String?
        var clickCSS: (x: Double, y: Double)?
        var types: [(target: String, value: String)] = []
        var evalJS: String?
        var screenshotOut: String?
        var timeoutSeconds: TimeInterval = 60.0

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            guard arg.hasPrefix("--") else {
                throw HelmBrowserError.invalidArgument("Unexpected positional argument '\(arg)'.")
            }

            let key: String
            let value: String
            let raw = String(arg.dropFirst(2))
            if let eqIdx = raw.firstIndex(of: "=") {
                key = String(raw[..<eqIdx])
                value = String(raw[raw.index(after: eqIdx)...])
                idx += 1
            } else {
                key = raw
                guard idx + 1 < args.count else {
                    throw HelmBrowserError.invalidArgument("Flag '--\(key)' requires a value.")
                }
                value = args[idx + 1]
                idx += 2
            }

            switch key {
            case "url":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw HelmBrowserError.invalidArgument("--url cannot be empty.")
                }
                url = trimmed
            case "click-ocr":
                clickOCR = value
            case "click-css":
                let parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                      let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                      x.isFinite, y.isFinite
                else {
                    throw HelmBrowserError.invalidArgument("Invalid --click-css '\(value)'. Expected '<x>,<y>'.")
                }
                clickCSS = (x, y)
            case "type":
                guard let eqIdx = value.firstIndex(of: "=") else {
                    throw HelmBrowserError.invalidArgument("Invalid --type '\(value)'. Expected '<target>=<value>'.")
                }
                let target = String(value[..<eqIdx])
                let text = String(value[value.index(after: eqIdx)...])
                guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HelmBrowserError.invalidArgument("--type target cannot be empty in '\(value)'.")
                }
                types.append((target: target, value: text))
            case "eval-js":
                evalJS = value
            case "screenshot-out":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw HelmBrowserError.invalidArgument("--screenshot-out cannot be empty.")
                }
                screenshotOut = trimmed
            case "timeout":
                guard let parsed = Double(value), parsed.isFinite, parsed > 0 else {
                    throw HelmBrowserError.invalidArgument("Invalid --timeout '\(value)'. Expected positive seconds.")
                }
                timeoutSeconds = parsed
            default:
                throw HelmBrowserError.invalidArgument("Unknown flag '--\(key)'.")
            }
        }

        guard let resolvedURL = url else {
            throw HelmBrowserError.invalidArgument("Missing required flag '--url'.")
        }
        if clickOCR != nil && clickCSS != nil {
            throw HelmBrowserError.invalidArgument("--click-ocr and --click-css cannot be combined in one command.")
        }

        return ParsedActOptions(
            url: resolvedURL,
            clickOCR: clickOCR,
            clickCSS: clickCSS,
            types: types,
            evalJS: evalJS,
            screenshotOut: screenshotOut,
            timeoutSeconds: timeoutSeconds
        )
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

    private static func encodeErrorJSON(_ message: String) -> String {
        let payload = ["error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\":\"unknown error\"}"
    }
}
