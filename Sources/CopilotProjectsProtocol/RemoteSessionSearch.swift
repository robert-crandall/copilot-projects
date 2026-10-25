import Foundation

/// Searches the host's live sessions: instant name, project, folder, and
/// conversation matches, Luna's meaning-based picks, or the most recently active
/// sessions. Hosts advertise the capabilities only through the gateway that serves `path`.
public enum RemoteSessionSearchContract {
    public static let capability = "session-search-v1"
    /// The `recent` mode and `RemoteSessionSearchMatch.lastActivityAt`.
    public static let recentCapability = "session-search-recent-v1"
    /// The `history` mode, resumable ended-session matches, and `resumePath`.
    public static let historyCapability = "session-search-history-v1"
    /// Gateway route, POST JSON.
    public static let path = "/search"
    /// Gateway route to resume an ended session from search results, POST JSON.
    public static let resumePath = "/search/resume"
    /// Swift `Character`s (grapheme clusters) after trimming. A client that keeps
    /// queries within this many UTF-16 code units never exceeds it.
    public static let maximumQueryLength = 300
    public static let maximumMatches = 50
    public static let maximumExcludedSessionIds = 60

    /// The query trimmed of surrounding whitespace, or nil when that leaves it
    /// empty or longer than `maximumQueryLength`.
    public static func normalizedQuery(_ value: String) -> String? {
        normalizedQuery(value, mode: .instant)
    }

    /// As `normalizedQuery(_:)`, except that `recent`, which ignores its query,
    /// also accepts an empty one.
    public static func normalizedQuery(_ value: String, mode: RemoteSessionSearchMode) -> String? {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= maximumQueryLength, !query.isEmpty || mode == .recent else { return nil }
        return query
    }
    /// Cleans a session title by stripping control characters, collapsing runs of
    /// whitespace (including tabs and newlines) to single spaces, and truncating to
    /// 120 characters. Returns `nil` when empty.
    public static func sanitizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if scalar == "\t" || scalar == "\n" || scalar == "\r" { return " " }
            if scalar.value < 0x20 || scalar.value == 0x7f || (0x80 ... 0x9f).contains(scalar.value) {
                return " "
            }
            return Character(scalar)
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= 120 ? collapsed : String(collapsed.prefix(120))
    }
}

public enum RemoteSessionSearchMode: String, Codable, Sendable {
    case instant, luna
    /// Every live session, most recently active first, plus recent ended sessions when opted in.
    /// Needs `recentCapability`.
    case recent
    /// Second-stage CLI history search across the full local `session-store.db` after `luna` finishes.
    /// Needs `historyCapability`.
    case history
}

public struct RemoteSessionSearchRequest: Codable, Equatable, Sendable {
    public let query: String
    public let mode: RemoteSessionSearchMode
    /// When `true`, `.recent`, `.instant`, and `.luna` also include resumable ended sessions.
    public let includeResumable: Bool?
    /// Optional Copilot session UUIDs already displayed to exclude during `history` search.
    public let excludedCopilotSessionIds: [String]?

    public init(
        query: String,
        mode: RemoteSessionSearchMode,
        includeResumable: Bool? = nil,
        excludedCopilotSessionIds: [String]? = nil
    ) {
        self.query = query
        self.mode = mode
        self.includeResumable = includeResumable
        self.excludedCopilotSessionIds = excludedCopilotSessionIds
    }
}

public struct RemoteSessionSearchMatch: Codable, Equatable, Sendable {
    public let sessionId: String
    public let projectId: String
    /// Instant: one-line conversation excerpt when only conversation text matched.
    public let snippet: String?
    /// Luna: short reason.
    public let reason: String?
    /// When the session's transcript last changed, in milliseconds since 1970.
    /// Absent when unknown, such as for a plain terminal, or from an older host.
    public let lastActivityAtMilliseconds: Int64?
    /// Present for an ended Copilot CLI session that can be resumed into `projectId`.
    public let resumableCopilotSessionId: String?
    /// Display title for an ended resumable session (nil for live sessions).
    public let title: String?
    /// Folder name for an ended resumable session (nil for live sessions or root).
    public let folderName: String?

    public var lastActivityAt: Date? {
        lastActivityAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    public var isResumable: Bool {
        resumableCopilotSessionId != nil
    }

    public init(
        sessionId: String,
        projectId: String,
        snippet: String? = nil,
        reason: String? = nil,
        lastActivityAt: Date? = nil,
        resumableCopilotSessionId: String? = nil,
        title: String? = nil,
        folderName: String? = nil
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.snippet = snippet
        self.reason = reason
        lastActivityAtMilliseconds = lastActivityAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
        self.resumableCopilotSessionId = resumableCopilotSessionId
        self.title = title
        self.folderName = folderName
    }
}

public struct RemoteResumeSearchSessionRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let projectId: String
    public let copilotSessionId: String
    public let title: String?

    public init(
        requestId: UUID,
        projectId: String,
        copilotSessionId: String,
        title: String? = nil
    ) {
        self.requestId = requestId
        self.projectId = projectId
        self.copilotSessionId = copilotSessionId
        self.title = title
    }

    public func normalized() -> Self? {
        let project = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let copilot = copilotSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, project.utf8.count <= 256,
              let uuid = UUID(uuidString: copilot) else {
            return nil
        }
        return Self(
            requestId: requestId,
            projectId: project,
            copilotSessionId: uuid.uuidString.lowercased(),
            title: RemoteSessionSearchContract.sanitizedTitle(title)
        )
    }
}

public struct RemoteResumeSearchSessionResponse: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let projectId: String
    public let sessionId: String

    public init(requestId: UUID, projectId: String, sessionId: String) {
        self.requestId = requestId
        self.projectId = projectId
        self.sessionId = sessionId
    }
}

public enum RemoteResumeSearchSessionOutcome: Equatable, Sendable {
    case created(RemoteResumeSearchSessionResponse)
    case existing(RemoteResumeSearchSessionResponse)
    case invalid(String)
    case unsupported
    case conflict
    case gone(String)
    case inUse(String)
    case unknownProject
    case unavailable(String)
    case persistenceUnavailable
}

public struct RemoteSessionSearchResponse: Codable, Equatable, Sendable {
    public let mode: RemoteSessionSearchMode
    /// Ranked, best first; for `recent`, most recently active first.
    public let matches: [RemoteSessionSearchMatch]

    public init(mode: RemoteSessionSearchMode, matches: [RemoteSessionSearchMatch]) {
        self.mode = mode
        self.matches = matches
    }
}

public enum RemoteSessionSearchOutcome: Equatable, Sendable {
    case results(RemoteSessionSearchResponse)
    /// Oversized query, or an empty one outside `recent` → HTTP 400.
    case invalid(String)
    /// The host can't search → HTTP 404.
    case unsupported
    /// Too many concurrent Luna runs → HTTP 429.
    case busy
    /// Luna error (user-facing message) → HTTP 502 `{"error": message}`.
    case failed(String)
}
