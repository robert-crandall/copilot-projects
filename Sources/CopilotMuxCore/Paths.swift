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
            return true
        } catch {
            return false
        }
    }
}
