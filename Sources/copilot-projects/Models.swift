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
    var turnCompleted: Bool = false
    /// copilot is waiting on its own background agents (it reports this via a
    /// "Copilot: Waiting for background agents" terminal title). Surfaced as a
    /// session indicator instead of letting that title clobber the session's real name.
    var backgroundAgentsActive: Bool = false
    var scheduledTurnActive: Bool = false
    var agentActivity: AgentActivitySnapshot?

    var activeSubagentCount: Int { agentActivity?.activeSubagents.count ?? 0 }
    var schedules: [TrackedSchedule] { agentActivity?.schedules ?? [] }
    var hasBackgroundWork: Bool {
        backgroundAgentsActive || scheduledTurnActive || activeSubagentCount > 0
    }
    /// A pending structured `ask_user` or schema `elicitation` awaiting an answer.
    /// These are answered via their own card, so a free-form remote prompt must
    /// never be injected over one even when the terminal footer reads idle.
    var hasPendingQuestions: Bool {
        (agentActivity?.trackedUserInputs?.isEmpty == false)
            || (agentActivity?.trackedElicitations?.isEmpty == false)
    }

    private enum CodingKeys: String, CodingKey { case id, title, cwd }

    init(id: String = UUID().uuidString, title: String, cwd: String) {
        self.id = id
        self.title = title
        self.cwd = cwd
    }
}

/// Which action a session is waiting on. Declaration order is display order.
enum SessionAttentionGroup: String, CaseIterable, Identifiable {
    case needsYou
    case readyForReview
    case workingWithoutYou
    case inactive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .readyForReview: return "Ready for review"
        case .workingWithoutYou: return "Working without you"
        case .inactive: return "Inactive"
        }
    }

    static func group(for session: Session) -> SessionAttentionGroup {
        if session.status == .waiting || session.hasPendingQuestions {
            return .needsYou
        }
        if session.status == .idle && session.finishedUnseen {
            return .readyForReview
        }
        if session.status == .running || session.hasBackgroundWork {
            return .workingWithoutYou
        }
        return .inactive
    }
}

struct SessionListEntry: Identifiable, Equatable {
    var session: Session
    var projectId: String
    var projectName: String
    var id: String { session.id }
}

struct AttentionSection: Identifiable, Equatable {
    var group: SessionAttentionGroup
    var entries: [SessionListEntry]
    var id: String { group.rawValue }
    var count: Int { entries.count }
}

enum SessionManualOrder {
    static func reconciled(order: [String], projects: [Project]) -> [String] {
        let liveIds = projects.flatMap(\.sessions).map(\.id)
        let liveSet = Set(liveIds)
        var seen = Set<String>()
        var result = order.filter { liveSet.contains($0) && seen.insert($0).inserted }
        result.append(contentsOf: liveIds.filter { seen.insert($0).inserted })
        return result
    }

    static func ranks(_ order: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
    }
}

/// A project groups sessions and owns a default working directory.
struct Project: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var cwd: String
    var sessions: [Session]
    var selectedSessionId: String?

    init(id: String = UUID().uuidString,
         name: String,
         cwd: String,
         sessions: [Session] = [],
         selectedSessionId: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.sessions = sessions
        self.selectedSessionId = selectedSessionId
    }
}

extension Project {
    /// Project-level rollup for the CLI/status text (idle | running | waiting).
    var aggregateStatus: SessionStatus {
        if sessions.contains(where: { $0.status == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.status == .running }) { return .running }
        return .idle
    }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var backgroundWorkCount: Int { sessions.filter(\.hasBackgroundWork).count }
    var scheduledCount: Int { sessions.filter { !$0.schedules.isEmpty }.count }
    var hasUnread: Bool { sessions.contains { $0.hasUnread } }
    var hasBackgroundWork: Bool { backgroundWorkCount > 0 }
}

/// On-disk shape of the app state.
struct PersistedState: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [Project]
    var selectedProjectId: String?
    var sessionOrder: [String]

    init(projects: [Project], selectedProjectId: String?, sessionOrder: [String] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projects = projects
        self.selectedProjectId = selectedProjectId
        self.sessionOrder = sessionOrder
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, selectedProjectId, sessionOrder
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        projects = try values.decode([Project].self, forKey: .projects)
        selectedProjectId = try values.decodeIfPresent(String.self, forKey: .selectedProjectId)
        sessionOrder = try values.decodeIfPresent([String].self, forKey: .sessionOrder) ?? []
    }
}

/// Which number-key overlay to show while a modifier is held.
enum NumberHint {
    case none      // nothing held
    case projects  // ⌘ held → number badges on projects
    case tabs      // ⌃ held → number badges on session rows
}
