import AppKit
import SwiftTerm

/// Owns a single SwiftTerm terminal + its child shell, and republishes the
/// process-delegate callbacks as plain closures. Deliberately NOT an
/// ObservableObject: the live NSView is kept out of the SwiftUI observation graph.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let sessionId: String
    let terminalView: MuxTerminalView

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
        self.terminalView = MuxTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.processDelegate = self
        // Make OSC 8 hyperlinks and plain URLs open on a normal click (the macOS
        // default requires holding ⌘). SwiftTerm's default delegate opens them
        // via NSWorkspace.
        terminalView.linkHighlightMode = .hover
        start(cwd: cwd, extraEnvironment: extraEnvironment,
              dtachExecutable: dtachExecutable, dtachSocket: dtachSocket)
    }

    private func start(cwd: String, extraEnvironment: [String: String],
                       dtachExecutable: String?, dtachSocket: String?) {
        let processEnv = ProcessInfo.processInfo.environment
        let shell = processEnv["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        var env = processEnv
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
