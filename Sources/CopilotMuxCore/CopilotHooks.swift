import Foundation

/// Installs a Copilot CLI hook bridge so a coding agent's lifecycle drives the
/// session status dot automatically. The hook no-ops unless it runs inside a
/// copilot-mux terminal (where COPILOT_MUX_SESSION is set), so it is safe to
/// have configured globally and coexists with other integrations (e.g. cmux).
public enum CopilotHooks {
    public static var hooksDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks", isDirectory: true)
    }

    public static var scriptURL: URL { hooksDir.appendingPathComponent("copilot-mux-hook.sh") }
    public static var configURL: URL { hooksDir.appendingPathComponent("copilot-mux.json") }

    /// True when the Copilot CLI hooks directory exists (CLI installed + used).
    public static var copilotPresent: Bool {
        FileManager.default.fileExists(atPath: hooksDir.path)
    }

    /// Maps agent lifecycle events to `copilot-mux set-status`.
    public static let script = #"""
    #!/usr/bin/env bash
    # copilot-mux <-> Copilot CLI status bridge (managed by copilot-mux; safe to delete).
    # No-ops unless invoked inside a copilot-mux terminal.
    set -u

    emit() { printf '{}\n'; }   # neutral hook result

    if [ -z "${COPILOT_MUX_SESSION:-}" ]; then emit; exit 0; fi

    cli="$(command -v copilot-mux 2>/dev/null || true)"
    if [ -z "$cli" ] && [ -x "$HOME/.local/bin/copilot-mux" ]; then
      cli="$HOME/.local/bin/copilot-mux"
    fi
    if [ -z "$cli" ]; then emit; exit 0; fi

    set_status() { "$cli" set-status "$1" >/dev/null 2>&1 || true; }
    is_ask_user() { printf '%s' "$1" | grep -q '"toolName"[[:space:]]*:[[:space:]]*"ask_user"'; }

    case "${1:-}" in
      running) set_status running ;;
      idle)    set_status idle ;;
      pre)
        payload="$(cat 2>/dev/null || true)"
        if is_ask_user "$payload"; then set_status waiting; else set_status running; fi
        ;;
      post)
        cat >/dev/null 2>&1 || true   # drain stdin
        set_status running            # also refreshes the liveness heartbeat
        ;;
    esac
    emit
    exit 0
    """#

    /// Copilot CLI hook wiring (one entry per lifecycle event). sessionStart and
    /// sessionEnd reset to idle so a fresh / exited agent never reads as running;
    /// tool events refresh the heartbeat so the app can decay a stuck "running".
    public static let config = #"""
    {
      "version": 1,
      "hooks": {
        "sessionStart": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-mux-hook.sh\" idle", "timeoutSec": 5 }
        ],
        "userPromptSubmitted": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-mux-hook.sh\" running", "timeoutSec": 5 }
        ],
        "preToolUse": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-mux-hook.sh\" pre", "timeoutSec": 10 }
        ],
        "postToolUse": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-mux-hook.sh\" post", "timeoutSec": 10 }
        ],
        "agentStop": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-mux-hook.sh\" idle", "timeoutSec": 5 }
        ],
        "sessionEnd": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-mux-hook.sh\" idle", "timeoutSec": 5 }
        ]
      }
    }
    """#

    @discardableResult
    public static func install() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        return "Installed Copilot CLI hooks in \(hooksDir.path) "
            + "(copilot-mux-hook.sh, copilot-mux.json). Start a new Copilot CLI session to pick them up."
    }

    public static func uninstall() {
        let fm = FileManager.default
        try? fm.removeItem(at: scriptURL)
        try? fm.removeItem(at: configURL)
    }

    /// Best-effort install used at app launch. Only writes when content actually
    /// changed, so it won't churn a version-controlled `~/.copilot`.
    public static func installIfPossible() {
        guard copilotPresent, !contentMatches() else { return }
        _ = try? install()
    }

    private static func contentMatches() -> Bool {
        guard let s = try? String(contentsOf: scriptURL, encoding: .utf8),
              let c = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return s == script && c == config
    }
}
