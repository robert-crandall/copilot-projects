import Foundation
import CopilotProjectsCore

// Single binary, two roles: a known subcommand runs the CLI client; anything else
// launches the SwiftUI app.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, CLIMain.isCommand(first) {
    exit(CLIMain.run(cliArgs))
}

// One-time copy of pre-rebrand UserDefaults (bundle-id change) before any window
// or split view restores its saved frame.
LegacyDefaults.migrateIfNeeded()
CopilotProjectsApp.main()
