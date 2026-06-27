import Foundation
import CopilotProjectsCore

// Single binary, two roles: a known subcommand runs the CLI client; no arguments
// launches the SwiftUI app. Unknown arguments are errors — silently launching a
// second GUI for a typo such as `--version` can create competing dtach clients.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, CLIMain.isCommand(first) {
    exit(CLIMain.run(cliArgs))
}
if !cliArgs.isEmpty, !CLIMain.isCocoaLaunchArguments(cliArgs) {
    FileHandle.standardError.write(
        Data("copilot-projects: unknown command: \(cliArgs[0]) (try `copilot-projects help`)\n".utf8)
    )
    exit(2)
}

// One-time copy of pre-rebrand UserDefaults (bundle-id change) before any window
// or split view restores its saved frame.
LegacyDefaults.migrateIfNeeded()
CopilotProjectsApp.main()
