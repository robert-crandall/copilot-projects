import Foundation
import CopilotMuxCore

// Single binary, two roles: a known subcommand runs the CLI client; anything else
// launches the SwiftUI app.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, CLIMain.isCommand(first) {
    exit(CLIMain.run(cliArgs))
}

CopilotMuxApp.main()
