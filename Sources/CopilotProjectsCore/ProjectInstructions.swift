import Foundation

/// Per-project Copilot instructions: extra guidance applied to every Copilot CLI
/// session started inside a project, without touching the user's repositories.
///
/// Delivery relies on the Copilot CLI's `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` env var
/// (a comma-separated list of extra directories the CLI scans for custom-instruction
/// files, in addition to the git root and cwd). For each project we maintain an
/// app-managed directory under the state dir:
///
///     <stateDir>/projects/<projectId>/.github/instructions/project.instructions.md
///
/// The file carries `applyTo: "**"` frontmatter, which the CLI treats as an
/// always-applied instruction regardless of the session's working directory — so
/// the project's guidance is inlined into every session's context. Because the
/// directory lives under the app's state dir (not the repo), nothing shows up in
/// the user's `git status`.
///
/// The Copilot CLI reads custom instructions once at startup, so edits take effect
/// for the *next* Copilot session, not sessions already running.
public enum ProjectInstructions {
    /// Environment variable the Copilot CLI reads for extra instruction directories.
    public static let dirsEnvKey = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"

    /// Root directory handed to `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` for a project.
    /// The CLI scans this like a repo root, finding `.github/instructions/*.md`.
    public static func rootDirectory(projectId: String, stateDir: URL = Paths.stateDir) -> URL {
        stateDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
    }

    /// The instruction file the CLI loads (`applyTo: "**"` → always applied).
    public static func instructionsFile(projectId: String, stateDir: URL = Paths.stateDir) -> URL {
        rootDirectory(projectId: projectId, stateDir: stateDir)
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("instructions", isDirectory: true)
            .appendingPathComponent("project.instructions.md")
    }

    /// Render the on-disk file: `applyTo: "**"` frontmatter followed by the body.
    public static func fileContents(_ instructions: String) -> String {
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return "---\napplyTo: \"**\"\n---\n\n\(body)\n"
    }

    /// Write (or, for empty instructions, remove) the project's instruction file to
    /// match `instructions`. Returns the root directory to expose via
    /// `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` when instructions are present, or nil when
    /// they are empty (nothing to add).
    @discardableResult
    public static func sync(projectId: String,
                            instructions: String,
                            stateDir: URL = Paths.stateDir) -> URL? {
        let fm = FileManager.default
        let file = instructionsFile(projectId: projectId, stateDir: stateDir)
        let root = rootDirectory(projectId: projectId, stateDir: stateDir)
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? fm.removeItem(at: file)
            return nil
        }
        do {
            try fm.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(fileContents(instructions).utf8).write(to: file, options: .atomic)
            return root
        } catch {
            return nil
        }
    }

    /// Delete a project's instructions directory entirely (used when the project is
    /// closed). Best-effort.
    public static func remove(projectId: String, stateDir: URL = Paths.stateDir) {
        try? FileManager.default.removeItem(at: rootDirectory(projectId: projectId, stateDir: stateDir))
    }

    /// Compose the `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value for a session, keeping
    /// any inherited value so a user-configured global setting isn't clobbered. The
    /// project's own directory (when present) is placed first. Returns nil when
    /// there is nothing to set (no project dir and no inherited value), so the caller
    /// can leave any inherited environment value untouched.
    public static func customInstructionsDirsValue(projectRoot: URL?, inherited: String?) -> String? {
        var dirs = (inherited ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let projectRoot {
            let path = projectRoot.path
            if !dirs.contains(path) { dirs.insert(path, at: 0) }
        }
        return dirs.isEmpty ? nil : dirs.joined(separator: ",")
    }
}
