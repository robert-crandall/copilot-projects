import Foundation

/// Installs a Copilot CLI hook bridge so a coding agent's lifecycle drives the
/// session status dot automatically. The hook no-ops unless it runs inside a
/// Copilot Projects terminal (where the per-session env is set), so it is safe to
/// have configured globally and coexists with other integrations (e.g. cmux).
///
/// Compatibility: a `copilot` process caches its hook command at startup, so an
/// agent that was already running before the rebrand keeps invoking the old
/// `copilot-mux-hook.sh`. The script is therefore written under both the new and
/// the legacy name (identical content), and the legacy JSON config is removed so
/// new agents register only the new hook (no double-fire).
public enum CopilotHooks {
    public static var hooksDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks", isDirectory: true)
    }

    public static var scriptURL: URL { hooksDir.appendingPathComponent("copilot-projects-hook.sh") }
    public static var configURL: URL { hooksDir.appendingPathComponent("copilot-projects.json") }
    static var legacyScriptURL: URL { hooksDir.appendingPathComponent("copilot-mux-hook.sh") }
    static var legacyConfigURL: URL { hooksDir.appendingPathComponent("copilot-mux.json") }

    /// True when the Copilot CLI hooks directory exists (CLI installed + used).
    public static var copilotPresent: Bool {
        FileManager.default.fileExists(atPath: hooksDir.path)
    }

    /// Maps agent lifecycle events to `copilot-projects set-status`. Reads both the
    /// current and legacy env var names so it works in sessions started before the
    /// rebrand (whose shells still carry `COPILOT_MUX_*`).
    public static let script = #"""
    #!/usr/bin/env bash
    # Copilot Projects <-> Copilot CLI status bridge (managed by Copilot Projects; safe to delete).
    # No-ops unless invoked inside a Copilot Projects terminal.
    set -u

    emit() { printf '{}\n'; }   # neutral hook result

    session_id="${COPILOT_PROJECTS_SESSION:-${COPILOT_MUX_SESSION:-}}"
    socket="${COPILOT_PROJECTS_SOCKET:-${COPILOT_MUX_SOCKET:-}}"
    if [ -z "$session_id" ]; then emit; exit 0; fi

    # Derive the state dir from whichever socket env is present; otherwise fall back
    # to the storage root that matches the session's vintage.
    if [ -n "$socket" ]; then
      state_dir="$(dirname "$socket")"
    elif [ -n "${COPILOT_MUX_SESSION:-}" ]; then
      state_dir="$HOME/.local/state/copilot-mux"
    else
      state_dir="$HOME/.local/state/copilot-projects"
    fi

    cli="$(command -v copilot-projects 2>/dev/null || true)"
    [ -z "$cli" ] && [ -x "$HOME/.local/bin/copilot-projects" ] && cli="$HOME/.local/bin/copilot-projects"
    [ -z "$cli" ] && cli="$(command -v copilot-mux 2>/dev/null || true)"
    [ -z "$cli" ] && [ -x "$HOME/.local/bin/copilot-mux" ] && cli="$HOME/.local/bin/copilot-mux"

    # Persist the status to a marker file (survives an app restart and stays
    # current even while the app isn't running) and notify the live app.
    status() {
      mkdir -p "$state_dir/sessions" 2>/dev/null || true
      printf '%s' "$1" > "$state_dir/sessions/$session_id.status" 2>/dev/null || true
      # Notify the live app in the background: a slow/hung control socket must never
      # block the hook. preToolUse has a timeout, and a timed-out hook is treated as
      # an error that DENIES the agent's tool call. The marker file above is the
      # source of truth; the socket notify is a best-effort live-UI update.
      [ -n "$cli" ] && ( "$cli" set-status "$1" >/dev/null 2>&1 & ) || true
    }
    # The agent is blocked on the user when the CLI raises an elicitation
    # (the ask_user tool) or a permission prompt. Those don't fire tool hooks —
    # they arrive via the `notification` hook, tagged with a notification_type.
    is_input_wait() {
      printf '%s' "$1" | grep -qE '"notification_type"[[:space:]]*:[[:space:]]*"(elicitation_dialog|permission_prompt)"'
    }
    # Record the Copilot CLI session id (carried by tool/notification payloads as
    # "sessionId") so the app can auto-resume THIS exact agent session after a
    # reboot — copilot --resume=<id> — instead of guessing per tab. Best-effort;
    # validates the id charset so nothing unsafe lands in the marker.
    record_cli_session() {
      # Match only a UUID-shaped value and take the leftmost: this relies on the
      # CLI emitting the real top-level "sessionId" first (escaped occurrences inside
      # tool args/results don't match the unescaped pattern). Captured only on
      # tool/notification events, so a pure-chat session that never calls a tool
      # isn't recorded — best-effort.
      cid="$(printf '%s' "$1" \
        | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[0-9A-Fa-f-]{36}"' \
        | head -1 \
        | sed -E 's/.*"([0-9A-Fa-f-]{36})"$/\1/')"
      case "$cid" in
        ""|*[!0-9A-Fa-f-]*) : ;;   # empty or non-UUID charset -> skip
        *) mkdir -p "$state_dir/sessions" 2>/dev/null || true
           # Write atomically (tmp + mv) so the app never reads a half-truncated marker.
           tmp="$state_dir/sessions/.$session_id.copilot-session.$$"
           if printf '%s' "$cid" > "$tmp" 2>/dev/null; then
             mv -f "$tmp" "$state_dir/sessions/$session_id.copilot-session" 2>/dev/null || rm -f "$tmp" 2>/dev/null
           fi || true ;;
      esac
    }

    case "${1:-}" in
      running) status running ;;
      idle)    status idle ;;
      pre)  record_cli_session "$(cat 2>/dev/null || true)"; status running ;;   # a tool call ⇒ working
      post) record_cli_session "$(cat 2>/dev/null || true)"; status running ;;
      notify)
        payload="$(cat 2>/dev/null || true)"
        record_cli_session "$payload"
        if is_input_wait "$payload"; then status waiting; fi
        ;;
      end)
        # The agent session ENDED (user exited) — drop the resume marker so the tab
        # doesn't boot back into a session the user already left ("zombie resume").
        # Only sessionEnd maps here; agentStop (between-turn idle, session alive) uses
        # `idle` and must NOT clear it. If a reboot kills the agent mid-session, this
        # never fires, so the marker survives and the session resumes — as intended.
        rm -f "$state_dir/sessions/$session_id.copilot-session" 2>/dev/null || true
        status idle
        ;;
    esac
    emit
    exit 0
    """#

    /// Copilot CLI hook wiring (one entry per lifecycle event). sessionStart resets
    /// to idle so a fresh agent never reads as running; tool events keep it running;
    /// the notification hook surfaces "waiting" when the agent raises an ask_user /
    /// permission prompt (which fire no tool hook); sessionEnd (`end`) resets to idle
    /// AND drops the resume marker so an exited session isn't auto-resumed on reboot.
    public static let config = #"""
    {
      "version": 1,
      "hooks": {
        "sessionStart": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" idle", "timeoutSec": 5 }
        ],
        "userPromptSubmitted": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" running", "timeoutSec": 5 }
        ],
        "preToolUse": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" pre", "timeoutSec": 10 }
        ],
        "postToolUse": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" post", "timeoutSec": 10 }
        ],
        "notification": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" notify", "timeoutSec": 5 }
        ],
        "agentStop": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" idle", "timeoutSec": 5 }
        ],
        "sessionEnd": [
          { "type": "command", "bash": "\"$HOME/.copilot/hooks/copilot-projects-hook.sh\" end", "timeoutSec": 5 }
        ]
      }
    }
    """#

    @discardableResult
    public static func install() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        // Write the (identical) script under both names so agents that cached the
        // legacy hook path before the rebrand don't hit a missing file.
        for url in [scriptURL, legacyScriptURL] {
            try Data(script.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try Data(config.utf8).write(to: configURL, options: .atomic)
        // Remove the legacy JSON so new agents don't register the hook twice. The
        // legacy script file stays in place for already-running agents.
        try? fm.removeItem(at: legacyConfigURL)
        return "Installed Copilot CLI hooks in \(hooksDir.path) "
            + "(copilot-projects-hook.sh, copilot-projects.json). Start a new Copilot CLI session to pick them up."
    }

    public static func uninstall() {
        let fm = FileManager.default
        for url in [scriptURL, legacyScriptURL, configURL, legacyConfigURL] {
            try? fm.removeItem(at: url)
        }
    }

    /// Best-effort install used at app launch. Only writes when something is out of
    /// date, so it won't churn a version-controlled `~/.copilot`.
    public static func installIfPossible() {
        guard copilotPresent, !upToDate() else { return }
        _ = try? install()
    }

    private static func upToDate() -> Bool {
        let fm = FileManager.default
        guard let s = try? String(contentsOf: scriptURL, encoding: .utf8), s == script,
              let c = try? String(contentsOf: configURL, encoding: .utf8), c == config,
              let ls = try? String(contentsOf: legacyScriptURL, encoding: .utf8), ls == script,
              !fm.fileExists(atPath: legacyConfigURL.path)
        else { return false }
        return true
    }
}
