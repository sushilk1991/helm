import Darwin
import Foundation
import HelmBrowser
import HelmCore
import HelmIsolation

@main
struct HelmCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let output: CLIExecutionOutput
        if SandboxCLICommand.handles(arguments: args) {
            output = await SandboxCLICommand.run(arguments: args)
        } else if BrowserCLICommand.handles(arguments: args) {
            output = await BrowserCLICommand.run(arguments: args)
        } else {
            output = await HelmCLIRunner.run(
                arguments: args,
                sandboxExecutorFactory: { ExecutionRouter() },
                browserServiceFactory: { BrowseReadActTool() }
            )
        }
        if !output.stdout.isEmpty {
            if let data = (output.stdout + "\n").data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
        }
        if !output.stderr.isEmpty {
            if let data = (output.stderr + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
        Darwin.exit(output.exitCode)
    }
}
