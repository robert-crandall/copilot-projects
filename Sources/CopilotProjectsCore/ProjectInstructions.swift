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
/// the next time `copilot` is launched — including in already-open shells, because
/// `AppModel` advertises this directory to every session up front, even before any
/// instruction file exists.
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
    /// match `instructions`, and return the root directory to advertise via
    /// `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`.
    ///
    /// The directory is always returned (and always advertised by callers) even when
    /// there are currently no instructions: the Copilot CLI tolerates a missing/empty
    /// extra dir, and advertising it up front means instructions saved *after* a shell
    /// is already open are picked up by the next `copilot` launched in that shell.
    @discardableResult
    public static func sync(projectId: String,
                            instructions: String,
                            stateDir: URL = Paths.stateDir) -> URL {
        let fm = FileManager.default
        let root = rootDirectory(projectId: projectId, stateDir: stateDir)
        let file = instructionsFile(projectId: projectId, stateDir: stateDir)
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if fm.fileExists(atPath: file.path) {
                do {
                    try fm.removeItem(at: file)
                } catch {
                    NSLog("copilot-projects: failed to clear project instructions at \(file.path): \(error)")
                }
            }
            return root
        }
        do {
            try fm.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(fileContents(instructions).utf8).write(to: file, options: .atomic)
        } catch {
            NSLog("copilot-projects: failed to write project instructions at \(file.path): \(error)")
        }
        return root
    }

    /// Read a project's instructions back from disk, stripping the `applyTo`
    /// frontmatter. Returns nil when the file is missing or empty. Used to recover
    /// instructions that a downgrade-then-upgrade round-trip dropped from state.json
    /// (the on-disk file is an independent, durable copy).
    public static func readInstructions(projectId: String,
                                        stateDir: URL = Paths.stateDir) -> String? {
        let file = instructionsFile(projectId: projectId, stateDir: stateDir)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let body = strippingFrontmatter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Drop a leading `---` … `---` YAML frontmatter block (the shape `fileContents`
    /// writes). Returns the input unchanged when it isn't present.
    static func strippingFrontmatter(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        guard lines.first == "---" else { return raw }
        lines.removeFirst()
        guard let close = lines.firstIndex(of: "---") else { return raw }
        return lines[(close + 1)...].joined(separator: "\n")
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
