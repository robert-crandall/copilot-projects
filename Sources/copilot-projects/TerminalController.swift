import AppKit
import SwiftTerm

/// Owns a single SwiftTerm terminal + its child shell, and republishes the
/// process-delegate callbacks as plain closures. Deliberately NOT an
/// ObservableObject: the live NSView is kept out of the SwiftUI observation graph.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let sessionId: String
    let terminalView: ProjectsTerminalView

    /// PID of the shell this terminal is running (0 until spawned). Used for the
    /// process-liveness check.
    var shellPID: pid_t {
        terminalView.process?.shellPid ?? 0
    }

    var onTitle: ((String) -> Void)?
    var onDirectory: ((String?) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private(set) var exited = false

    init(sessionId: String, cwd: String, extraEnvironment: [String: String],
         dtachExecutable: String?, dtachSocket: String?) {
        self.sessionId = sessionId
        self.terminalView = ProjectsTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.processDelegate = self
        // Make OSC 8 hyperlinks and plain URLs open on a normal click (the macOS
        // default requires holding ⌘). SwiftTerm's default delegate opens them
        // via NSWorkspace.
        terminalView.linkHighlightMode = .hover
        // Don't report mouse events to the program: a mouse-reporting TUI (a live
        // agent) would otherwise swallow click-drags, so you couldn't select text,
        // and SwiftTerm would clear any selection on each new line of output. With
        // reporting off, a plain drag selects and the selection survives streaming
        // output. The scroll wheel is still forwarded to the agent separately (see
        // ProjectsTerminalView.forwardScroll), so scrolling keeps working.
        terminalView.allowMouseReporting = false
        start(cwd: cwd, extraEnvironment: extraEnvironment,
              dtachExecutable: dtachExecutable, dtachSocket: dtachSocket)
    }

    private func start(cwd: String, extraEnvironment: [String: String],
                       dtachExecutable: String?, dtachSocket: String?) {
        let processEnv = ProcessInfo.processInfo.environment
        let shell = processEnv["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        var env = processEnv
        // The Copilot CLI tags its process tree with per-session/loader env vars.
        // If this app was launched from a copilot session (e.g. `copilot ... --resume`
        // that ran `open`), they leak in and get inherited by every terminal — so a
        // `copilot` started in a session believes it's already a managed child and
        // its `/restart` defers to the launcher's (wrong, often gone) loader instead
        // of re-spawning. Strip them so each session's copilot owns its own lifecycle.
        for key in [
            "COPILOT_LOADER_PID", "COPILOT_RUN_APP", "COPILOT_DETACHED_SESSION",
            "COPILOT_DETACHED_PARENT_SESSION_ID", "COPILOT_DETACHED_PARENT_ENGAGEMENT_ID",
            "COPILOT_AGENT_SESSION_ID", "COPILOT_CONNECTION_TOKEN", "COPILOT_SHUTDOWN_FLUSH",
            "COPILOT_CLI", "COPILOT_CLI_BINARY_VERSION",
        ] {
            env.removeValue(forKey: key)
        }
        for (k, v) in extraEnvironment { env[k] = v }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        let envArray = env.map { "\($0.key)=\($0.value)" }
        let dir = cwd.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : cwd

        if let dtach = dtachExecutable, let socket = dtachSocket {
            // Resumable: dtach owns the shell PTY and survives app quit.
            //   -A attach-or-create, -r winch redraw-on-attach,
            //   -z no suspend key, -E no detach key (fully raw → keyboard passthrough).
            terminalView.startProcess(
                executable: dtach,
                args: ["-A", socket, "-r", "winch", "-z", "-E", shell, "-l"],
                environment: envArray,
                execName: nil,
                currentDirectory: dir
            )
        } else {
            // Fallback (no dtach helper): direct login shell, not resumable.
            terminalView.startProcess(
                executable: shell,
                args: [],
                environment: envArray,
                execName: "-\(shellName)",
                currentDirectory: dir
            )
        }
    }

    func terminate() {
        terminalView.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectory?(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        exited = true
        onExit?(exitCode)
    }
}
