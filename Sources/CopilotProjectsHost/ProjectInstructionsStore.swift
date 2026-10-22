import Foundation
import Darwin

struct ProjectInstructionsStore {
    static let environmentKey = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    static let sessionDirectoryKey = "COPILOT_PROJECTS_INSTRUCTIONS_DIR"
    static let header = "---\napplyTo: \"**\"\n---\n"
    private static let filePath = ".github/instructions/copilot-projects.instructions.md"

    let root: URL

    var supportsCustomInstructions: Bool { !root.path.contains(",") }

    func projectDirectory(_ projectId: String) -> URL {
        root.appendingPathComponent("projects").appendingPathComponent(projectId)
    }

    func sessionDirectory(_ sessionId: String) -> URL {
        root.appendingPathComponent("sessions").appendingPathComponent(sessionId)
    }

    func read(projectId: String) throws -> String {
        try validate(projectId)
        let url = projectDirectory(projectId).appendingPathComponent(Self.filePath)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.hasPrefix(Self.header) ? String(text.dropFirst(Self.header.count)) : text
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }

    func save(_ text: String, projectId: String) throws {
        try validate(projectId)
        guard supportsCustomInstructions else { throw StoreError.commaInPath }
        let url = projectDirectory(projectId).appendingPathComponent(Self.filePath)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try removeIfPresent(url)
        } else {
            try createDirectory(url.deletingLastPathComponent())
            try (Self.header + text).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Shells outlive the app and project moves. Keep their env path stable and
    /// redirect it before the next Copilot process discovers instructions.
    func link(sessionId: String, projectId: String) throws {
        try validate(sessionId)
        try validate(projectId)
        let target = projectDirectory(projectId)
        let link = sessionDirectory(sessionId)
        try createDirectory(target)
        try createDirectory(link.deletingLastPathComponent())
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path {
            return
        }
        let staged = link.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: target)
        defer {
            do { try removeIfPresent(staged) }
            catch { NSLog("copilot-projects: could not remove staged instruction link: \(error)") }
        }
        guard Darwin.rename(staged.path, link.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func removeClosed(sessionIds: Set<String>, projectIds: Set<String>) throws {
        for id in sessionIds {
            try validate(id)
            try removeIfPresent(sessionDirectory(id))
        }
        for id in projectIds {
            try validate(id)
            try removeIfPresent(projectDirectory(id))
        }
    }

    static func environment(
        from base: [String: String], sessionDirectory: String?
    ) -> [String: String] {
        var result = base
        let previous = result.removeValue(forKey: sessionDirectoryKey)
        var directories = (result[environmentKey] ?? "").split(separator: ",").map(String.init)
        if let previous {
            directories.removeAll { $0 == previous }
        }
        if let sessionDirectory {
            directories.append(sessionDirectory)
            result[sessionDirectoryKey] = sessionDirectory
        }
        if directories.isEmpty {
            result.removeValue(forKey: environmentKey)
        } else {
            result[environmentKey] = directories.joined(separator: ",")
        }
        return result
    }

    private func validate(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..",
              !id.contains("/"), !id.contains("\0") else { throw StoreError.invalidIdentifier }
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }

    enum StoreError: LocalizedError {
        case commaInPath, invalidIdentifier

        var errorDescription: String? {
            switch self {
            case .commaInPath:
                return "Project instructions require an app state directory without commas. "
                    + "Copilot uses commas to separate instruction directories. Plain terminals are unaffected."
            case .invalidIdentifier:
                return "The project or session has an invalid identifier for instruction storage."
            }
        }
    }
}
