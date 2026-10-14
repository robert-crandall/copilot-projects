import Foundation

/// Why GitHub sent a notification: its `reason` field.
enum NotificationReason: Equatable, Hashable, Sendable {
    case approvalRequested, assign, author, comment, ciActivity, invitation, manual, mention
    case memberFeatureRequested, reviewRequested, securityAdvisoryCredit, securityAlert
    case stateChange, subscribed, teamMention
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "approval_requested": self = .approvalRequested
        case "assign": self = .assign
        case "author": self = .author
        case "comment": self = .comment
        case "ci_activity": self = .ciActivity
        case "invitation": self = .invitation
        case "manual": self = .manual
        case "mention": self = .mention
        case "member_feature_requested": self = .memberFeatureRequested
        case "review_requested": self = .reviewRequested
        case "security_advisory_credit": self = .securityAdvisoryCredit
        case "security_alert": self = .securityAlert
        case "state_change": self = .stateChange
        case "subscribed": self = .subscribed
        case "team_mention": self = .teamMention
        default: self = .other(raw)
        }
    }
}

/// Who a notification reached the user through. The window's bands, in order.
enum NotificationBand: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case toYou, viaTeams, watching, quiet

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .toYou: return "To you"
        case .viaTeams: return "Via your teams"
        case .watching: return "Watching"
        case .quiet: return "Quiet"
        }
    }

    /// Bands whose unread threads count toward the badge and can raise banners.
    var needsYou: Bool { self != .quiet }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One row of the window: why a set of threads reached the user.
enum NotificationLane: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case reviewRequested, mentioned, assigned, yourWork, conversations
    case teamReviewRequested, teamMentioned
    case watchedRepositories, subscribedThreads
    case ciActivity, other

    var id: Int { rawValue }

    var band: NotificationBand {
        switch self {
        case .reviewRequested, .mentioned, .assigned, .yourWork, .conversations: return .toYou
        case .teamReviewRequested, .teamMentioned: return .viaTeams
        case .watchedRepositories, .subscribedThreads: return .watching
        case .ciActivity, .other: return .quiet
        }
    }

    var title: String {
        switch self {
        case .reviewRequested, .teamReviewRequested: return "Review requested"
        case .mentioned: return "Mentioned"
        case .assigned: return "Assigned"
        case .yourWork: return "Your pull requests and issues"
        case .conversations: return "Conversations you’re in"
        case .teamMentioned: return "Team mentioned"
        case .watchedRepositories: return "Repositories you watch"
        case .subscribedThreads: return "Threads you subscribed to"
        case .ciActivity: return "CI activity"
        case .other: return "Other"
        }
    }

    /// Said once beside the lane's name, so chips needn't repeat it.
    var explanation: String {
        switch self {
        case .reviewRequested: return "You were asked to review"
        case .mentioned: return "Someone @mentioned you"
        case .assigned: return "Assigned to you"
        case .yourWork: return "Activity on threads you opened"
        case .conversations: return "Replies and changes where you took part"
        case .teamReviewRequested: return "A team you’re on was asked to review"
        case .teamMentioned: return "A team you’re on was @mentioned"
        case .watchedRepositories: return "New threads in repositories you watch"
        case .subscribedThreads: return "Threads you chose to follow"
        case .ciActivity: return "Workflow runs you started"
        case .other: return "Alerts, invitations, and the rest"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The window's columns: how recently a thread changed, measured from when
/// the user last looked.
enum NotificationFreshness: Int, CaseIterable, Identifiable, Sendable {
    case sinceYouLooked, today, thisWeek, older

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sinceYouLooked: return "Since you looked"
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .older: return "Older"
        }
    }

    /// Unread changes after the last look are new; everything else is placed by its day.
    static func of(
        updatedAt: Date, unread: Bool, lookedAt: Date?, now: Date, calendar: Calendar = .current
    ) -> NotificationFreshness {
        if unread, lookedAt.map({ updatedAt > $0 }) ?? true { return .sinceYouLooked }
        if calendar.isDate(updatedAt, inSameDayAs: now) || updatedAt > now { return .today }
        if updatedAt > now.addingTimeInterval(-7 * 86_400) { return .thisWeek }
        return .older
    }
}

/// What kind of thing a notification is about.
enum NotificationSubjectKind: Equatable, Sendable {
    case pullRequest, issue, discussion, release, commit, checkSuite, workflowRun, securityAlert
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "PullRequest": self = .pullRequest
        case "Issue": self = .issue
        case "Discussion": self = .discussion
        case "Release": self = .release
        case "Commit": self = .commit
        case "CheckSuite": self = .checkSuite
        case "WorkflowRun": self = .workflowRun
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread", "SecurityAdvisory":
            self = .securityAlert
        default: self = .other(raw)
        }
    }

    var symbol: String {
        switch self {
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "smallcircle.filled.circle"
        case .discussion: return "bubble.left.and.bubble.right"
        case .release: return "tag"
        case .commit: return "circle.and.line.horizontal"
        case .checkSuite, .workflowRun: return "play.circle"
        case .securityAlert: return "exclamationmark.shield"
        case .other: return "bell"
        }
    }

    var label: String {
        switch self {
        case .pullRequest: return "Pull request"
        case .issue: return "Issue"
        case .discussion: return "Discussion"
        case .release: return "Release"
        case .commit: return "Commit"
        case .checkSuite, .workflowRun: return "Workflow run"
        case .securityAlert: return "Security alert"
        case .other(let raw): return raw.isEmpty ? "Notification" : raw
        }
    }
}

/// A GitHub notification thread for one signed-in account.
struct NotificationThread: Identifiable, Equatable, Sendable {
    struct Key: Hashable, Comparable, Sendable, CustomStringConvertible {
        let account: String
        let id: String

        var description: String { "\(account)/\(id)" }

        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.account, lhs.id) < (rhs.account, rhs.id) }
    }

    let key: Key
    var unread: Bool
    let reason: NotificationReason
    let updatedAt: Date
    /// When the user last read the thread anywhere, as GitHub recorded it.
    var lastReadAt: Date? = nil
    let title: String
    let kind: NotificationSubjectKind
    /// `owner/repo`.
    let repository: String
    /// The REST URL of the subject, when GitHub gives one.
    let subjectAPIURL: URL?
    /// The subject's issue or pull request number, when it has one.
    let number: Int?

    var id: Key { key }
    var account: String { key.account }

    var pullRequestKey: PullRequestKey? {
        guard kind == .pullRequest, let number else { return nil }
        return PullRequestKey(repository: repository, number: number)
    }

    /// `repo#number`, or the repository's name when the subject has no number.
    var shortName: String {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        return number.map { "\(name)#\($0)" } ?? name
    }

    /// Where the thread opens on github.com.
    var webURL: URL {
        Self.webURL(apiURL: subjectAPIURL, repository: repository, kind: kind)
    }

    static func webURL(apiURL: URL?, repository: String, kind: NotificationSubjectKind) -> URL {
        let repositoryURL = URL(string: "https://github.com/\(repository)")!
        guard let apiURL, apiURL.host == "api.github.com" else {
            switch kind {
            case .checkSuite, .workflowRun: return repositoryURL.appendingPathComponent("actions")
            case .discussion: return repositoryURL.appendingPathComponent("discussions")
            case .securityAlert: return repositoryURL.appendingPathComponent("security")
            default: return repositoryURL
            }
        }
        // /repos/{owner}/{repo}/{collection}/{id}
        let parts = apiURL.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[0] == "repos" else { return repositoryURL }
        let base = "https://github.com/\(parts[1])/\(parts[2])"
        let rest = parts[4...].joined(separator: "/")
        switch parts[3] {
        case "pulls": return URL(string: "\(base)/pull/\(rest)") ?? repositoryURL
        case "issues": return URL(string: "\(base)/issues/\(rest)") ?? repositoryURL
        case "commits": return URL(string: "\(base)/commit/\(rest)") ?? repositoryURL
        case "discussions": return URL(string: "\(base)/discussions/\(rest)") ?? repositoryURL
        case "releases": return URL(string: "\(base)/releases") ?? repositoryURL
        default: return repositoryURL
        }
    }

    /// The trailing number of `…/pulls/123` or `…/issues/123`.
    static func number(apiURL: URL?) -> Int? {
        guard let apiURL else { return nil }
        let parts = apiURL.path.split(separator: "/")
        guard parts.count >= 2, ["pulls", "issues", "discussions"].contains(parts[parts.count - 2]) else { return nil }
        return Int(parts[parts.count - 1])
    }
}

/// What GitHub says about a thread's pull request or issue beyond the notification.
struct NotificationSubjectDetail: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case open, draft, merged, closed, completed, notPlanned

        /// Merged or closed: nothing left to act on.
        var isSettled: Bool { self != .open && self != .draft }

        var label: String? {
            switch self {
            case .open: return nil
            case .draft: return "Draft"
            case .merged: return "Merged"
            case .closed: return "Closed"
            case .completed: return "Closed as completed"
            case .notPlanned: return "Closed as not planned"
            }
        }
    }

    var state: State?
    var headRefName: String?
    /// The user was asked to review this pull request by name, at any point.
    var viewerRequested = false
    /// `org/slug` of every team asked to review, most recent first.
    var requestedTeams: [String] = []
    /// Every review request was read; false when older ones were left out.
    var requestHistoryComplete = true
    /// The asked team the user belongs to, when known.
    var viewerTeam: String?
    /// The latest time the user was mentioned, assigned, or asked to review by name.
    var viewerTargetedAt: Date?
    /// The latest time each team (`org/slug`, lowercased) was asked to review.
    var teamRequestedAt: [String: Date] = [:]
    /// The latest time the user reviewed, commented, merged, or closed it.
    var viewerActedAt: Date?
    /// The user acted after the last time anything asked for them.
    var answered = false

    /// The team to name on a team review request.
    var teamToName: String? { viewerTeam ?? requestedTeams.first }

    /// Whether the user's last action came after the last thing aimed at them:
    /// a mention, assignment, or review request to them, or a review request to
    /// a team they're on. `onTeam` answers nil when membership isn't known; such
    /// a team counts as theirs, so an unknown never hides a request. With nothing
    /// aimed at them in the history, nothing is answered.
    func isAnswered(onTeam: (String) -> Bool?) -> Bool {
        let teamTargets = teamRequestedAt.filter { onTeam($0.key) != false }.map(\.value)
        guard let target = ([viewerTargetedAt].compactMap { $0 } + teamTargets).max(),
              let acted = viewerActedAt else { return false }
        return acted > target
    }
}

/// A thread placed in the window: its lane, column, and what its chip says.
struct NotificationItem: Identifiable, Equatable, Sendable {
    let thread: NotificationThread
    let lane: NotificationLane
    let detail: NotificationSubjectDetail?
    /// Who asked for a review isn't known yet; it sits with To you until it is.
    let isClassifying: Bool
    var session: PullRequestSession?

    var id: NotificationThread.Key { thread.key }

    /// Threads that ask something of the user, and so can be answered.
    static let answerableReasons: Set<NotificationReason> = [.reviewRequested, .mention, .teamMention, .assign]

    /// The user already reviewed, replied, merged, or closed it since they were
    /// last asked; later activity by others doesn't ask again.
    var isAnswered: Bool { Self.answerableReasons.contains(thread.reason) && detail?.answered == true }

    /// A review request whose pull request is already merged or closed: there's
    /// nothing left to review. Mentions and other activity on a closed thread
    /// can still need an answer, so they're never settled this way.
    var isSettled: Bool {
        (lane == .reviewRequested || lane == .teamReviewRequested) && thread.reason == .reviewRequested
            && detail?.state?.isSettled == true
    }
    /// Unread, in a band that needs the user, still open to act on, and not answered.
    var needsYou: Bool { thread.unread && lane.band.needsYou && !isSettled && !isAnswered }

    /// Where a thread belongs. Review requests are yours until GitHub's history
    /// shows they only ever reached a team: losing one to a team lane costs more
    /// than seeing a team request among your own.
    static func lane(for reason: NotificationReason, detail: NotificationSubjectDetail?) -> NotificationLane {
        switch reason {
        case .reviewRequested:
            guard let detail, !detail.viewerRequested, detail.requestHistoryComplete,
                  !detail.requestedTeams.isEmpty else { return .reviewRequested }
            return .teamReviewRequested
        case .approvalRequested: return .reviewRequested
        case .mention: return .mentioned
        case .assign: return .assigned
        case .author: return .yourWork
        case .comment, .stateChange: return .conversations
        case .teamMention: return .teamMentioned
        case .subscribed: return .watchedRepositories
        case .manual: return .subscribedThreads
        case .ciActivity: return .ciActivity
        case .invitation, .memberFeatureRequested, .securityAdvisoryCredit, .securityAlert, .other: return .other
        }
    }

    init(thread: NotificationThread, detail: NotificationSubjectDetail?, detailsSettled: Bool, session: PullRequestSession? = nil) {
        self.thread = thread
        self.detail = detail
        lane = Self.lane(for: thread.reason, detail: detail)
        isClassifying = thread.reason == .reviewRequested && thread.kind == .pullRequest && detail == nil && !detailsSettled
        self.session = session
    }

    /// The facts a chip adds to what its lane already says, most useful first.
    func detailParts(showsAccount: Bool) -> [String] {
        var parts: [String] = []
        if lane == .teamReviewRequested, let team = detail?.teamToName { parts.append("@\(team)") }
        if thread.reason == .approvalRequested { parts.append("Deployment approval") }
        if let state = detail?.state?.label { parts.append(state) }
        if isClassifying {
            parts.append("Checking who was asked…")
        } else if thread.reason == .reviewRequested, thread.kind == .pullRequest, detail == nil {
            parts.append("Couldn’t check who was asked")
        }
        if showsAccount { parts.append("as \(thread.account)") }
        return parts
    }
}

/// The window's threads arranged into bands, lanes, and columns.
struct NotificationLayout: Equatable {
    struct Lane: Identifiable, Equatable {
        let lane: NotificationLane
        let items: [NotificationItem]

        var id: NotificationLane { lane }
        var unreadCount: Int { items.filter(\.thread.unread).count }
        /// Counted as the Dock badge counts them.
        var needsYouCount: Int { items.filter(\.needsYou).count }
        /// Unread, but its pull request or issue is already merged or closed.
        var settledCount: Int { items.filter { $0.thread.unread && $0.isSettled && $0.lane.band.needsYou }.count }

        func items(in column: NotificationFreshness, lookedAt: Date?, now: Date) -> [NotificationItem] {
            items.filter {
                NotificationFreshness.of(updatedAt: $0.thread.updatedAt, unread: $0.thread.unread, lookedAt: lookedAt, now: now) == column
            }
        }
    }

    struct Band: Identifiable, Equatable {
        let band: NotificationBand
        let lanes: [Lane]

        var id: NotificationBand { band }
        var unreadCount: Int { lanes.reduce(0) { $0 + $1.unreadCount } }
        var needsYouCount: Int { lanes.reduce(0) { $0 + $1.needsYouCount } }
        var settledCount: Int { lanes.reduce(0) { $0 + $1.settledCount } }
    }

    let bands: [Band]

    /// Lanes and bands appear only when they hold something; chips lead with
    /// unread, then newest.
    init(items: [NotificationItem]) {
        let byLane = Dictionary(grouping: items, by: \.lane)
        bands = NotificationBand.allCases.compactMap { band in
            let lanes = NotificationLane.allCases.filter { $0.band == band }.compactMap { lane -> Lane? in
                guard let items = byLane[lane], !items.isEmpty else { return nil }
                return Lane(lane: lane, items: items.sorted(by: Self.order))
            }
            return lanes.isEmpty ? nil : Band(band: band, lanes: lanes)
        }
    }

    static func order(_ lhs: NotificationItem, _ rhs: NotificationItem) -> Bool {
        if lhs.thread.unread != rhs.thread.unread { return lhs.thread.unread }
        if lhs.thread.updatedAt != rhs.thread.updatedAt { return lhs.thread.updatedAt > rhs.thread.updatedAt }
        return lhs.thread.key < rhs.thread.key
    }

    var lanes: [Lane] { bands.flatMap(\.lanes) }
    var isEmpty: Bool { bands.isEmpty }
}

/// The counts the header, the Dock badge, and Copilot Projects' menu bar item share.
struct NotificationCounts: Equatable, Sendable {
    var toYou = 0
    var viaTeams = 0
    var watching = 0
    var quiet = 0
    /// Unread threads whose pull request or issue is already merged or closed.
    var settled = 0
    /// Unread threads the user already answered.
    var answered = 0

    var needsYou: Int { toYou + viaTeams + watching }

    init(items: [NotificationItem]) {
        for item in items where item.thread.unread {
            if item.lane.band.needsYou, item.isSettled {
                settled += 1
                continue
            }
            if item.lane.band.needsYou, item.isAnswered {
                answered += 1
                continue
            }
            switch item.lane.band {
            case .toYou: toYou += 1
            case .viaTeams: viaTeams += 1
            case .watching: watching += 1
            case .quiet: quiet += 1
            }
        }
    }

    /// The Dock badge: nothing at zero, and never wider than four characters.
    var badgeLabel: String? {
        switch needsYou {
        case 0: return nil
        case ..<1000: return "\(needsYou)"
        default: return "999+"
        }
    }
}
