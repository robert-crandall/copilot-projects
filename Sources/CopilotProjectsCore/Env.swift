import Foundation

/// Reads the per-session targeting variables the app injects into each shell.
/// New sessions carry `COPILOT_PROJECTS_*`; sessions started before the rebrand
/// still carry the legacy `COPILOT_MUX_*` names (a running shell's environment is
/// frozen at launch and cannot be rewritten), so every read falls back to them.
public enum Env {
    public static func projectId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        first(env, "COPILOT_PROJECTS_PROJECT", "COPILOT_MUX_PROJECT")
    }

    public static func sessionId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        first(env, "COPILOT_PROJECTS_SESSION", "COPILOT_MUX_SESSION")
    }

    public static func socket(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        first(env, "COPILOT_PROJECTS_SOCKET", "COPILOT_MUX_SOCKET")
    }

    private static func first(_ env: [String: String], _ keys: String...) -> String? {
        for key in keys {
            if let value = env[key], !value.isEmpty { return value }
        }
        return nil
    }
}
