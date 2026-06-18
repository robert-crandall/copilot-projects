import Foundation

/// Filesystem locations used by both the app and the CLI.
///
/// All paths can be overridden via environment variables so that tagged / test
/// instances can run fully isolated from a production copilot-mux.
public enum Paths {
    /// `~/.local/state/copilot-mux` (override with `COPILOT_MUX_STATE_DIR`).
    public static var stateDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_MUX_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local/state/copilot-mux", isDirectory: true)
    }

    /// Unix domain socket the app listens on (override with `COPILOT_MUX_SOCKET`).
    public static var socketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_MUX_SOCKET"], !override.isEmpty {
            return override
        }
        return stateDir.appendingPathComponent("control.sock").path
    }

    /// Persisted projects/sessions.
    public static var statePath: URL {
        stateDir.appendingPathComponent("state.json")
    }

    /// Directory holding per-session dtach sockets.
    public static var sessionsDir: URL {
        stateDir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// dtach socket for a session (kept short to stay under the ~104-byte sun_path limit).
    public static func dtachSocketPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).sock").path
    }

    /// Per-session status marker, written by the Copilot hook so status survives
    /// an app restart (and stays current even while the app isn't running).
    public static func statusMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).status").path
    }

    /// The bundled dtach helper (resumability backend), or an override, or nil.
    public static var dtachExecutable: String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_MUX_DTACH"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/dtach")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return nil
    }

    /// Best-effort creation of the (user-private) state directory.
    @discardableResult
    public static func ensureStateDir() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: stateDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.createDirectory(
                at: sessionsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}
