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

    /// What the sidebar dot shows. Unlike `aggregateStatus`, "running" is *not* an
    /// attention state here (it's already conveyed by the subtitle and the tab dot);
    /// the dot only lights up when a session needs you: blocked on input (waiting),
    /// or finished and not yet viewed.
    var dotState: ProjectDotState {
        if sessions.contains(where: { $0.status == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.finishedUnseen }) { return .finished }
        return .idle
    }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var hasUnread: Bool { sessions.contains { $0.hasUnread } }
}

/// The sidebar status dot's meaning (see `Project.dotState`).
enum ProjectDotState {
    case idle      // nothing needs you (covers actively-running)
    case finished  // a session finished and hasn't been viewed yet
    case waiting   // a session is blocked on your input
}

/// On-disk shape of the app state.
struct PersistedState: Codable {
    var projects: [Project]
    var selectedProjectId: String?
}

/// Which number-key overlay to show while a modifier is held.
enum NumberHint {
    case none      // nothing held
    case projects  // ⌘ held → number badges on projects
    case tabs      // ⌃ held → number badges on session tabs
}
