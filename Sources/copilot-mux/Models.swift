import Foundation
import CopilotMuxCore

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
    /// Project-level rollup used for the sidebar dot.
    var aggregateStatus: SessionStatus {
        if sessions.contains(where: { $0.status == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.status == .running }) { return .running }
        return .idle
    }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var hasUnread: Bool { sessions.contains { $0.hasUnread } }
}

/// On-disk shape of the app state.
struct PersistedState: Codable {
    var projects: [Project]
    var selectedProjectId: String?
}
