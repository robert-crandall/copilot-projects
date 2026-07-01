import Foundation
import CopilotProjectsCore

/// A terminal session inside a project. Value type; the live terminal NSView lives
/// elsewhere (AppModel.controllers) and is keyed by `id`.
struct Session: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var cwd: String

    // Transient (not persisted): reset on load.
    var status: SessionStatus = .idle
    var statusText: String? = nil
    var hasUnread: Bool = false
    /// The agent went active → idle while you weren't looking at this session, so it
    /// has finished and is waiting for you to come back. Cleared when you view it.
    var finishedUnseen: Bool = false
    /// copilot is waiting on its own background agents (it reports this via a
    /// "Copilot: Waiting for background agents" terminal title). Surfaced as a tab/
    /// sidebar indicator instead of letting that title clobber the tab's real name.
    var backgroundAgentsActive: Bool = false

    private enum CodingKeys: String, CodingKey { case id, title, cwd }

    init(id: String = UUID().uuidString, title: String, cwd: String) {
        self.id = id
        self.title = title
        self.cwd = cwd
    }
}

/// A project groups sessions and owns a default working directory.
struct Project: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var cwd: String
    var sessions: [Session]
    var selectedSessionId: String?
    /// Extra Copilot instructions applied to every Copilot session started in this
    /// project (see `ProjectInstructions`). Empty means "no per-project instructions".
    var instructions: String

    init(id: String = UUID().uuidString,
         name: String,
         cwd: String,
         sessions: [Session] = [],
         selectedSessionId: String? = nil,
         instructions: String = "") {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.sessions = sessions
        self.selectedSessionId = selectedSessionId
        self.instructions = instructions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, sessions, selectedSessionId, instructions
    }

    // Decode `instructions` leniently so state written by older versions (which
    // lacks the key) still loads. Encoding stays synthesized from CodingKeys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        cwd = try c.decode(String.self, forKey: .cwd)
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        selectedSessionId = try c.decodeIfPresent(String.self, forKey: .selectedSessionId)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    }
}

extension Project {
    /// Project-level rollup for the CLI/status text (idle | running | waiting).
    var aggregateStatus: SessionStatus {
        if sessions.contains(where: { $0.status == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.status == .running }) { return .running }
        return .idle
    }

    /// What the sidebar dot shows. The dot lights up only when a project has a
    /// session that finished and you haven't viewed it yet ("ready for you").
    /// Running and waiting are conveyed by the color-coded subtitle counts, not the
    /// dot, so an idle/busy/waiting project stays dot-free.
    var dotState: ProjectDotState {
        if sessions.contains(where: { $0.finishedUnseen }) { return .finished }
        return .idle
    }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var hasUnread: Bool { sessions.contains { $0.hasUnread } }
    var hasBackgroundAgents: Bool { sessions.contains { $0.backgroundAgentsActive } }

    /// Whether this project carries any per-project Copilot instructions.
    var hasInstructions: Bool {
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The sidebar status dot's meaning (see `Project.dotState`).
enum ProjectDotState {
    case idle      // no dot — nothing finished is waiting to be seen
    case finished  // a session finished and hasn't been viewed yet (blue)
}

/// On-disk shape of the app state.
struct PersistedState: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [Project]
    var selectedProjectId: String?

    init(projects: [Project], selectedProjectId: String?) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projects = projects
        self.selectedProjectId = selectedProjectId
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, selectedProjectId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        projects = try values.decode([Project].self, forKey: .projects)
        selectedProjectId = try values.decodeIfPresent(String.self, forKey: .selectedProjectId)
    }
}

/// Which number-key overlay to show while a modifier is held.
enum NumberHint {
    case none      // nothing held
    case projects  // ⌘ held → number badges on projects
    case tabs      // ⌃ held → number badges on session tabs
}
