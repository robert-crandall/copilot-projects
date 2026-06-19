import Foundation

/// Filesystem locations used by both the app and the CLI.
///
/// All paths can be overridden via environment variables so that tagged / test
/// instances can run fully isolated from a production copilot-projects.
public enum Paths {
    /// The storage root. Honors `COPILOT_PROJECTS_STATE_DIR` (or the legacy
    /// `COPILOT_MUX_STATE_DIR`); otherwise see `defaultStateDir`.
    public static var stateDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_PROJECTS_STATE_DIR"] ?? env["COPILOT_MUX_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultStateDir
    }

    /// Resolved once per process. An install that already has sessions under the
    /// pre-rebrand `copilot-mux` directory keeps using it — the directory is
    /// internal and is deliberately never moved, because the live dtach masters
    /// were launched with their old socket paths baked into argv, so relocating
    /// the sockets would strand them. Fresh installs use the current name.
    private static let defaultStateDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = home.appendingPathComponent(".local/state/copilot-projects", isDirectory: true)
        let legacy = home.appendingPathComponent(".local/state/copilot-mux", isDirectory: true)
        if hasMeaningfulState(legacy) && !hasMeaningfulState(current) { return legacy }
        return current
    }()

    /// True if a directory holds real session state, so an empty/accidental dir
    /// never wins the legacy-vs-current decision above.
    private static func hasMeaningfulState(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("state.json").path) { return true }
        let sessions = dir.appendingPathComponent("sessions").path
        if let items = try? fm.contentsOfDirectory(atPath: sessions), !items.isEmpty { return true }
        return false
    }

    /// Unix domain socket the app listens on (override with `COPILOT_PROJECTS_SOCKET`).
    public static var socketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_PROJECTS_SOCKET"] ?? env["COPILOT_MUX_SOCKET"],
           !override.isEmpty {
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
        if let override = env["COPILOT_PROJECTS_DTACH"] ?? env["COPILOT_MUX_DTACH"],
           !override.isEmpty,
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
