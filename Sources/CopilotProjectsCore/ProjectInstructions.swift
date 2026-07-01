import Foundation

/// Per-project Copilot instructions: extra guidance applied to every Copilot CLI
/// session started inside a project, without touching the user's repositories.
///
/// Delivery relies on the Copilot CLI's `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` env var
/// (a comma-separated list of extra directories the CLI scans for custom-instruction
/// files, in addition to the git root and cwd). A file with `applyTo: "**"`
/// frontmatter is treated by the CLI as an always-applied instruction regardless of
/// the session's working directory.
///
/// The advertised directory is keyed by **session**, not project:
///
///     <stateDir>/sessions/<sessionId>.instructions/.github/instructions/project.instructions.md
///
/// A shell's environment is fixed when the shell starts and can't be changed
/// afterwards, but the app can rewrite the *contents* of the advertised directory at
/// any time. Keying it per session lets the app keep that file in sync with whatever
/// project the session currently belongs to — so editing a project's instructions
/// reaches its already-open shells (on their next `copilot` launch), and dragging a
/// session into another project switches it to that project's instructions. It also
/// means one project's `applyTo: "**"` file can never bleed into another project's
/// sessions.
///
/// A separate per-project plain-text copy is kept purely as a durable backup:
///
///     <stateDir>/projects/<projectId>/instructions.md
///
/// so instructions survive a downgrade → upgrade round-trip (older app builds drop
/// the unknown `instructions` key from state.json).
public enum ProjectInstructions {
    /// Environment variable the Copilot CLI reads for extra instruction directories.
    public static let dirsEnvKey = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"

    // MARK: - Per-session delivery (advertised to the CLI)

    /// Root directory advertised to `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` for a session.
    /// The CLI scans this like a repo root, finding `.github/instructions/*.md`.
    public static func sessionRoot(sessionId: String, stateDir: URL = Paths.stateDir) -> URL {
        sessionsRoot(stateDir: stateDir)
            .appendingPathComponent("\(sessionId).instructions", isDirectory: true)
    }

    /// Parent of every per-session delivery root — used to recognise (and strip)
    /// app-managed roots that leak in via an inherited environment.
    public static func sessionsRoot(stateDir: URL = Paths.stateDir) -> URL {
        stateDir.appendingPathComponent("sessions", isDirectory: true)
    }

    static func sessionInstructionsFile(sessionId: String, stateDir: URL = Paths.stateDir) -> URL {
        sessionRoot(sessionId: sessionId, stateDir: stateDir)
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("instructions", isDirectory: true)
            .appendingPathComponent("project.instructions.md")
    }

    /// Render the on-disk delivery file: `applyTo: "**"` frontmatter + body.
    public static func fileContents(_ instructions: String) -> String {
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return "---\napplyTo: \"**\"\n---\n\n\(body)\n"
    }

    /// Write (or, for empty instructions, remove) a session's delivery file so it
    /// reflects `instructions` (its current project's guidance), and return the
    /// session root to advertise. The root is always returned — even when empty — so
    /// callers advertise it up front; the CLI tolerates a missing/empty extra dir, so
    /// instructions written later are still picked up by the next `copilot` in an
    /// already-open shell.
    @discardableResult
    public static func syncSession(sessionId: String,
                                   instructions: String,
                                   stateDir: URL = Paths.stateDir) -> URL {
        let root = sessionRoot(sessionId: sessionId, stateDir: stateDir)
        let file = sessionInstructionsFile(sessionId: sessionId, stateDir: stateDir)
        writeOrRemove(file: file, contents: fileContentsOrEmpty(instructions), what: "session instructions")
        return root
    }

    /// Remove a session's delivery directory (used when the session ends). Best-effort.
    public static func removeSession(sessionId: String, stateDir: URL = Paths.stateDir) {
        try? FileManager.default.removeItem(at: sessionRoot(sessionId: sessionId, stateDir: stateDir))
    }

    // MARK: - Per-project durable backup (downgrade recovery)

    static func projectBackupFile(projectId: String, stateDir: URL = Paths.stateDir) -> URL {
        stateDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("instructions.md")
    }

    /// Persist a plain-text backup of a project's instructions (no frontmatter, so no
    /// parsing on the way back). Empty clears it.
    public static func syncProjectBackup(projectId: String,
                                         instructions: String,
                                         stateDir: URL = Paths.stateDir) {
        let file = projectBackupFile(projectId: projectId, stateDir: stateDir)
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        writeOrRemove(file: file, contents: trimmed, what: "project instructions backup")
    }

    /// Read a project's backed-up instructions. Returns nil when absent or empty.
    public static func readProjectBackup(projectId: String,
                                         stateDir: URL = Paths.stateDir) -> String? {
        let file = projectBackupFile(projectId: projectId, stateDir: stateDir)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Remove a project's backup directory (used when the project is closed).
    public static func removeProject(projectId: String, stateDir: URL = Paths.stateDir) {
        let dir = stateDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Environment composition

    /// Compose the `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value for a session. The
    /// session's own delivery root is placed first. Any inherited value is preserved
    /// so a user's global setting isn't clobbered — except that app-managed *other*
    /// session roots (which could leak in when the app itself was launched from a
    /// managed shell) are stripped, so one session's `applyTo: "**"` file can't apply
    /// to another. Returns nil only when there is nothing to set.
    public static func customInstructionsDirsValue(sessionRoot: URL?,
                                                   inherited: String?,
                                                   managedSessionsRoot: URL? = nil) -> String? {
        let currentPath = sessionRoot?.standardizedFileURL.path
        let managedPath = managedSessionsRoot?.standardizedFileURL.path
        var dirs = (inherited ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { entry in
                guard let managedPath else { return true }
                let url = URL(fileURLWithPath: entry).standardizedFileURL
                let isManagedRoot = url.deletingLastPathComponent().path == managedPath
                    && url.lastPathComponent.hasSuffix(".instructions")
                // Keep the current session's own root and any non-managed (user)
                // dirs; drop other sessions' app-managed roots.
                return !isManagedRoot || url.path == currentPath
            }
        if let sessionRoot {
            let path = sessionRoot.standardizedFileURL.path
            if !dirs.contains(path) { dirs.insert(path, at: 0) }
        }
        return dirs.isEmpty ? nil : dirs.joined(separator: ",")
    }

    // MARK: - internals

    private static func fileContentsOrEmpty(_ instructions: String) -> String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : fileContents(instructions)
    }

    /// Write `contents` to `file`, or remove `file` when `contents` is empty. On a
    /// failed removal, best-effort overwrite with empty content so stale instructions
    /// are never left active (they'd otherwise keep applying and could be resurrected
    /// on the next load). Failures are logged, not thrown.
    private static func writeOrRemove(file: URL, contents: String, what: String) {
        let fm = FileManager.default
        if contents.isEmpty {
            guard fm.fileExists(atPath: file.path) else { return }
            do {
                try fm.removeItem(at: file)
            } catch {
                NSLog("copilot-projects: failed to clear \(what) at \(file.path): \(error)")
                do {
                    try Data().write(to: file, options: .atomic)
                } catch {
                    NSLog("copilot-projects: failed to neutralize \(what) at \(file.path): \(error)")
                }
            }
            return
        }
        do {
            try fm.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(contents.utf8).write(to: file, options: .atomic)
        } catch {
            NSLog("copilot-projects: failed to write \(what) at \(file.path): \(error)")
        }
    }
}
