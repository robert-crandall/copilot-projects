import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Command-line front end. When the `copilot-mux` binary is invoked with a known
/// subcommand it acts as a thin client to the running app's control socket.
public enum CLIMain {
    /// Subcommands that should be handled by the CLI (vs. launching the GUI).
    public static let commands: Set<String> = [
        "set-status", "status",
        "notify",
        "list-projects", "projects",
        "list-status", "ls",
        "new-project",
        "new-session",
        "rename-project",
        "focus",
        "attach",
        "ping",
        "install-cli",
        "install-hooks", "uninstall-hooks",
        "help", "--help", "-h",
    ]

    public static func isCommand(_ s: String) -> Bool {
        commands.contains(s)
    }

    public static func run(_ args: [String]) -> Int32 {
        guard let raw = args.first else {
            printUsage()
            return 1
        }
        let command = canonical(raw)
        let rest = Array(args.dropFirst())

        switch command {
        case "help":
            printUsage()
            return 0
        case "install-cli":
            return installCLI(rest)
        case "install-hooks":
            do {
                let message = try CopilotHooks.install()
                print(message)
                return 0
            } catch {
                fail("\(error)")
                return 1
            }
        case "uninstall-hooks":
            CopilotHooks.uninstall()
            print("Removed copilot-mux Copilot CLI hooks.")
            return 0
        case "attach":
            return attachSession(rest)
        default:
            break
        }

        let parsed = parseFlags(rest)
        let env = ProcessInfo.processInfo.environment

        var req = ControlRequest(command: command)
        req.projectId = parsed.flags["project"] ?? env["COPILOT_MUX_PROJECT"]
        req.sessionId = parsed.flags["session"] ?? env["COPILOT_MUX_SESSION"]

        switch command {
        case "set-status":
            guard let status = parsed.flags["status"] ?? parsed.positionals.first else {
                fail("set-status requires a status: idle | running | waiting")
                return 1
            }
            req.status = status
            req.text = parsed.flags["text"]
        case "notify":
            req.title = parsed.flags["title"] ?? parsed.positionals.first
            req.body = parsed.flags["body"]
                ?? (parsed.positionals.count > 1 ? parsed.positionals[1] : nil)
            if req.title == nil {
                fail("notify requires a title")
                return 1
            }
        case "new-project":
            req.name = parsed.flags["name"] ?? parsed.positionals.first
            req.cwd = parsed.flags["cwd"]
        case "new-session":
            req.cwd = parsed.flags["cwd"]
        case "rename-project":
            req.name = parsed.flags["name"] ?? parsed.positionals.first
            if req.name == nil {
                fail("rename-project requires a name")
                return 1
            }
        case "focus", "list-projects", "list-status", "ping":
            break
        default:
            fail("unknown command: \(command)")
            return 1
        }

        do {
            let resp = try ControlClient().send(req)
            if let text = resp.text, !text.isEmpty {
                print(text)
            }
            if !resp.ok {
                fail(resp.error ?? "unknown error")
                return 1
            }
            return 0
        } catch {
            fail("\(error)")
            return 1
        }
    }

    // MARK: - aliases

    private static func canonical(_ command: String) -> String {
        switch command {
        case "status": return "set-status"
        case "projects": return "list-projects"
        case "ls": return "list-status"
        case "--help", "-h": return "help"
        default: return command
        }
    }

    // MARK: - attach (resume a session, incl. over SSH)

    private static func attachSession(_ args: [String]) -> Int32 {
        guard let dtach = Paths.dtachExecutable else {
            fail("dtach helper not found (resumability backend missing)")
            return 1
        }
        let parsed = parseFlags(args)
        let fm = FileManager.default
        let dir = Paths.sessionsDir
        let socks = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".sock") }
        let env = ProcessInfo.processInfo.environment
        let wanted = parsed.positionals.first
            ?? parsed.flags["session"]
            ?? env["COPILOT_MUX_SESSION"]

        let socketPath: String
        if let wanted = wanted, !wanted.isEmpty {
            if socks.contains("\(wanted).sock") {
                socketPath = Paths.dtachSocketPath(sessionId: wanted)
            } else {
                let matches = socks.filter { $0.hasPrefix(wanted) }
                if matches.count == 1 {
                    socketPath = dir.appendingPathComponent(matches[0]).path
                } else if matches.isEmpty {
                    fail("no session matching “\(wanted)” (try: copilot-mux ls)")
                    return 1
                } else {
                    fail("ambiguous “\(wanted)” — matches \(matches.count) sessions")
                    return 1
                }
            }
        } else if socks.count == 1 {
            socketPath = dir.appendingPathComponent(socks[0]).path
        } else {
            fail("specify a session id (copilot-mux ls to list)")
            return 1
        }

        guard fm.fileExists(atPath: socketPath) else {
            fail("session socket not found: \(socketPath)")
            return 1
        }

        // Replace this process with a dtach attach client (no -E, so Ctrl-\
        // detaches when used over SSH).
        let argv = [dtach, "-a", socketPath, "-r", "winch"]
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        execv(dtach, &cargs)
        fail("failed to launch dtach: \(String(cString: strerror(errno)))")
        return 1
    }

    // MARK: - flag parsing

    private struct Parsed {
        var positionals: [String] = []
        var flags: [String: String] = [:]
    }

    private static func parseFlags(_ args: [String]) -> Parsed {
        var out = Parsed()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                out.positionals.append(contentsOf: args[(i + 1)...])
                break
            }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    out.flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    out.flags[body] = args[i + 1]
                    i += 1
                } else {
                    out.flags[body] = ""   // boolean-ish flag
                }
            } else {
                out.positionals.append(a)
            }
            i += 1
        }
        return out
    }

    // MARK: - install-cli

    private static func installCLI(_ args: [String]) -> Int32 {
        let parsed = parseFlags(args)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = parsed.flags["dir"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        guard let exe = currentExecutablePath() else {
            fail("could not resolve the running executable path")
            return 1
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("copilot-mux")
            if fm.fileExists(atPath: link.path) {
                try? fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: exe)
            print("Linked \(link.path) -> \(exe)")
            let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !pathEnv.split(separator: ":").contains(Substring(dir.path)) {
                print("note: \(dir.path) is not on your PATH; add it to use `copilot-mux`.")
            }
            return 0
        } catch {
            fail("\(error)")
            return 1
        }
    }

    private static func currentExecutablePath() -> String? {
        if let p = Bundle.main.executablePath { return p }
        let arg0 = CommandLine.arguments.first ?? ""
        if arg0.hasPrefix("/") { return arg0 }
        return nil
    }

    // MARK: - output

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("copilot-mux: \(message)\n".utf8))
    }

    private static func printUsage() {
        let usage = """
        copilot-mux — project-organized terminal sessions

        Usage:
          copilot-mux                         Launch the app
          copilot-mux set-status <state>      Set status of the current session
                                              state: idle | running | waiting
              [--text "..."] [--session ID] [--project ID]
          copilot-mux notify <title> [body]   Post a macOS notification
              [--title T] [--body B] [--session ID] [--project ID]
          copilot-mux list-projects           List projects and their status
          copilot-mux list-status (ls)        List per-session status + ids
          copilot-mux attach [session]        Attach/resume a session (also works over SSH)
          copilot-mux new-project [name]      Create a project [--cwd DIR]
          copilot-mux new-session             Add a session to a project [--cwd DIR] [--project ID]
          copilot-mux rename-project <name>   Rename a project [--project ID]
          copilot-mux focus                   Focus a project/session [--project ID] [--session ID]
          copilot-mux ping                    Check the app is reachable
          copilot-mux install-cli [--dir D]   Symlink this binary onto your PATH
          copilot-mux install-hooks           Install Copilot CLI status hooks (~/.copilot/hooks)
          copilot-mux uninstall-hooks         Remove the Copilot CLI status hooks
          copilot-mux help                    Show this help

        Inside a copilot-mux terminal, COPILOT_MUX_PROJECT / COPILOT_MUX_SESSION are set,
        so set-status / notify target the current session automatically.
        """
        print(usage)
    }
}
