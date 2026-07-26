import Foundation

/// Reads the per-session targeting variables the app injects into each shell.
public enum Env {
    public static func projectId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(env["COPILOT_PROJECTS_PROJECT"])
    }

    public static func sessionId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(env["COPILOT_PROJECTS_SESSION"])
    }

    public static func socket(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(env["COPILOT_PROJECTS_SOCKET"])
    }

    public static func shouldInstallGlobalIntegration(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard nonEmpty(env["COPILOT_PROJECTS_NO_INSTALL"]) != "1"
        else { return false }

        return nonEmpty(env["COPILOT_PROJECTS_STATE_DIR"]) == nil
            && socket(env) == nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
