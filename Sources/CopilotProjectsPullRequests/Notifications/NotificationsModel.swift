import AppKit
import Foundation
import SwiftUI
import CopilotProjectsCore

enum NotificationsFetchError: Error, Equatable {
    case cliUnavailable
    case notSignedIn
    case failed(String)

    var title: String {
        switch self {
        case .cliUnavailable: return "GitHub CLI Needed"
        case .notSignedIn: return "Sign In to GitHub"
        case .failed: return "Couldn’t Load Notifications"
        }
    }

    var message: String {
        switch self {
        case .cliUnavailable:
            return "Notifications are read with the accounts you use with gh. Install the GitHub CLI, then run gh auth login."
        case .notSignedIn:
            return "No GitHub account is signed in to gh. Run gh auth login in a terminal, then refresh."
        case .failed(let detail):
            return detail
        }
    }
}

enum NotificationsFilter: String, CaseIterable, Identifiable {
    case unread = "Unread"
    case all = "All"

    var id: String { rawValue }

    func items(_ items: [NotificationItem]) -> [NotificationItem] {
        self == .unread ? items.filter(\.thread.unread) : items
    }
}

/// A banner Copilot Notifications can raise, and what a click on it does.
struct NotificationBanner: Equatable, Sendable {
    let identifier: String
    let title: String
    let subtitle: String?
    let body: String
    /// Opened, and marked read, when the banner is clicked; nil shows the window.
    let url: URL?
    let thread: NotificationThread.Key?
}

@MainActor
protocol NotificationBannerPosting: AnyObject {
    func post(_ banners: [NotificationBanner])
}

/// The user's GitHub notifications for every gh account, kept fresh while the
/// app runs, window or not, so the Dock badge and banners stay true.
@MainActor
final class NotificationsModel: ObservableObject {
    static let pollInterval: TimeInterval = 60
    static let fullRefreshInterval: TimeInterval = 300
    static let reopenFreshness: TimeInterval = 60
    static let accountsLifetime: TimeInterval = 600
    static let workspacePollInterval: TimeInterval = 3
    /// A look shorter than this was a glance through ⌘Tab, not a read.
    static let minimumLook: TimeInterval = 1.5
    /// Individual banners per refresh; more become one summary banner.
    static let individualBannerLimit = 3
    /// How long an open review request's state is trusted before it's read
    /// again: merging doesn't always touch the notification.
    static let openDetailLifetime: TimeInterval = 15 * 60

    static let lookedAtKey = "notifications.lookedAt"
    static let bannerHighWaterKey = "notifications.bannerHighWaters"
    static let menuBarCountKey = "notifications.menuBarCount"

    @Published private(set) var threads: [NotificationThread] = []
    @Published private(set) var details: [NotificationThread.Key: NotificationSubjectDetail] = [:]
    @Published private(set) var settled: Set<NotificationThread.Key> = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var warning: String?
    @Published private(set) var accounts: [String] = []
    /// Accounts with unread threads beyond what one refresh reads.
    @Published private(set) var truncatedAccounts: Set<String> = []
    @Published private(set) var workspace: WorkspaceState = .connecting
    @Published private(set) var links: [PullRequestKey: String] = [:]
    /// When the user last finished looking at the window.
    @Published private(set) var lookedAt: Date?
    /// The look the columns are measured from. It catches up with `lookedAt`
    /// when the user comes back, so what they saw moves out of Since you looked
    /// in front of them rather than while they're away.
    @Published private(set) var columnsLookedAt: Date?
    @Published var bannersToYou: Bool { didSet { saveBannerSetting(.toYou, bannersToYou) } }
    @Published var bannersViaTeams: Bool { didSet { saveBannerSetting(.viaTeams, bannersViaTeams) } }
    @Published var bannersWatching: Bool { didSet { saveBannerSetting(.watching, bannersWatching) } }
    @Published var bannersAllowed: Bool?
    @Published var showsMenuBarCount: Bool {
        didSet { if writesState { defaults.set(showsMenuBarCount, forKey: Self.menuBarCountKey) } }
    }

    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(NotificationsFetchError)
    }

    let storageNote: String?
    private let loadAccounts: @Sendable () async throws -> [GitHubAccount]
    private let api: GitHubNotificationsAPI
    private let plan: NotificationsFetchPlan
    private let detailsFetcher: NotificationDetailsFetcher
    private let source: PullRequestsWorkspace
    private let transcripts: PullRequestTranscriptReading
    private let transcriptPath: @Sendable (String) -> String?
    private let host: PullRequestsHostApp
    private let defaults: UserDefaults
    /// Only the copy holding the lock saves looks, settings, and the summary.
    private let writesState: Bool
    private let summaryURL: URL?
    private let clock: () -> Date
    private let openURL: (URL) -> Void
    private let isVisible: () -> Bool
    weak var banners: NotificationBannerPosting?
    /// The Dock badge; nil clears it.
    var setBadge: (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }
    /// Every published count change, for the menu bar item.
    var onCounts: ((NotificationCounts) -> Void)?

    private var cachedAccounts: (accounts: [GitHubAccount], loadedAt: Date)?
    private var lastModified: [String: String] = [:]
    /// The longest wait between polls GitHub asked each account for.
    private var pollIntervals: [String: TimeInterval] = [:]
    private var lastFullRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var loop: Task<Void, Never>?
    private var workspaceLoop: Task<Void, Never>?
    private var lastGoodSnapshot: WorkspaceSnapshot?
    /// The `updatedAt` each thread's details were read for.
    private var detailVersions: [NotificationThread.Key: Date] = [:]
    private var viewerTeams: [String: Set<String>] = [:]
    /// Threads marked done here, hidden from refreshes that started before
    /// GitHub saw it, until they change again.
    private var doneLocally: [NotificationThread.Key: Date] = [:]
    /// Threads marked read here, kept read across refreshes racing the request.
    private var readLocally: [NotificationThread.Key: Date] = [:]
    private var lookStarted: Date?
    /// When threads were first on screen; a look only counts from then.
    private var loadedAt: Date?
    /// Per account: the newest change already considered for a banner.
    private var bannerHighWaters: [String: Date]
    private var announced: [NotificationThread.Key: Date] = [:]
    private var linkedSessions: [String] = []
    /// When each subject's details were last read.
    private var detailReadAt: [NotificationThread.Key: Date] = [:]
    /// While subject details are being read, counts may still include requests
    /// that turn out to be for a team or already merged; nothing is published.
    private var readingDetails = false

    init(
        workspace: PullRequestsWorkspace = ControlWorkspaceBridge(),
        host: PullRequestsHostApp = .none,
        defaults: UserDefaults = .standard,
        writesState: Bool = true,
        storageNote: String? = nil,
        summaryURL: URL? = nil,
        stateDirectory: URL? = nil,
        api: GitHubNotificationsAPI = GitHubNotificationsAPI(),
        plan: NotificationsFetchPlan = NotificationsFetchPlan(),
        detailsFetcher: NotificationDetailsFetcher = NotificationDetailsFetcher(),
        loadAccounts: (@Sendable () async throws -> [GitHubAccount])? = nil,
        transcripts: PullRequestTranscriptReading? = nil,
        transcriptPath: @escaping @Sendable (String) -> String? = {
            PullRequestTranscriptIndex.transcriptPath(copilotSessionId: $0)
        },
        clock: @escaping () -> Date = Date.init,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        isVisible: @escaping () -> Bool = { true }
    ) {
        source = workspace
        self.host = host
        self.defaults = defaults
        self.writesState = writesState
        self.storageNote = storageNote
        self.summaryURL = summaryURL
        self.api = api
        self.plan = plan
        self.detailsFetcher = detailsFetcher
        self.loadAccounts = loadAccounts ?? {
            guard let executable = GitHubCLI.executable() else { throw NotificationsFetchError.cliUnavailable }
            let accounts = try await GitHubCLI.accounts(executable: executable)
            guard !accounts.isEmpty else { throw NotificationsFetchError.notSignedIn }
            return accounts
        }
        self.transcripts = transcripts
            ?? PullRequestTranscriptIndex(storeURL: writesState ? stateDirectory?.appendingPathComponent("transcript-index.json") : nil)
        self.transcriptPath = transcriptPath
        self.clock = clock
        self.openURL = openURL
        self.isVisible = isVisible
        let looked = (defaults.object(forKey: Self.lookedAtKey) as? Double).map(Date.init(timeIntervalSince1970:))
        lookedAt = looked
        columnsLookedAt = looked
        bannerHighWaters = ((defaults.dictionary(forKey: Self.bannerHighWaterKey) as? [String: Double]) ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
        showsMenuBarCount = defaults.object(forKey: Self.menuBarCountKey) as? Bool ?? true
        bannersToYou = defaults.object(forKey: Self.bannerKey(.toYou)) as? Bool ?? true
        bannersViaTeams = defaults.object(forKey: Self.bannerKey(.viaTeams)) as? Bool ?? true
        bannersWatching = defaults.object(forKey: Self.bannerKey(.watching)) as? Bool ?? true
    }

    deinit {
        loop?.cancel()
        workspaceLoop?.cancel()
        refreshTask?.cancel()
    }

    // MARK: Derived

    var items: [NotificationItem] {
        let sessions = liveSessions
        return threads.map { thread in
            let session = thread.pullRequestKey.flatMap { links[$0] }.flatMap { sessions[$0] }
            return NotificationItem(
                thread: thread, detail: details[thread.key], detailsSettled: settled.contains(thread.key), session: session
            )
        }
    }

    var counts: NotificationCounts { NotificationCounts(items: items) }

    /// More than one account: chips from the others name theirs.
    var primaryAccount: String? { accounts.count > 1 ? accounts.first : nil }

    var isConnected: Bool {
        if case .connected = workspace { return true }
        return false
    }

    var canOpenHost: Bool { host.open != nil }

    var liveSessions: [String: PullRequestSession] {
        switch workspace {
        case .connected(let snapshot): return PullRequestSession.sessions(in: snapshot)
        case .disconnected(let lastGood?): return PullRequestSession.sessions(in: lastGood).mapValues(\.withUnknownState)
        case .connecting, .disconnected: return [:]
        }
    }

    func bannersEnabled(for band: NotificationBand) -> Bool {
        switch band {
        case .toYou: return bannersToYou
        case .viaTeams: return bannersViaTeams
        case .watching: return bannersWatching
        case .quiet: return false
        }
    }

    // MARK: Running

    /// Starts reading GitHub and the workspace; the app calls it once at launch.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
        workspaceLoop = Task { [weak self] in await self?.runWorkspaceLoop() }
    }

    private func runLoop() async {
        await refreshNow()
        while !Task.isCancelled {
            // GitHub can ask for longer gaps under load; never poll sooner.
            let wait = max(Self.pollInterval, pollIntervals.values.max() ?? 0)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let due = lastFullRefresh.map { clock().timeIntervalSince($0) >= Self.fullRefreshInterval } ?? true
            let changed = due ? false : await inboxChanged()
            if due || changed { await refreshNow() }
        }
    }

    /// A refresh is due when GitHub says an inbox changed since the last one.
    private func inboxChanged() async -> Bool {
        guard let accounts = cachedAccounts?.accounts else { return true }
        var changed = false
        for account in accounts {
            guard let since = lastModified[account.login] else { return true }
            switch try? await api.list(account: account, query: Self.probeQuery, ifModifiedSince: since) {
            case .notModified(let interval):
                if let interval { pollIntervals[account.login] = interval }
            case .page(let page):
                if let interval = page.pollInterval { pollIntervals[account.login] = interval }
                changed = true
            case nil:
                changed = true
            }
        }
        return changed
    }

    private static let probeQuery = [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "per_page", value: "1")]

    func refreshNow() async {
        refresh()
        while let task = refreshTask { await task.value; if refreshTask == task { break } }
    }

    /// Reads every account's inbox again. One runs at a time; another asked for
    /// meanwhile runs right after it.
    func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    /// The window opened or came forward: refresh unless GitHub was just read.
    func refreshIfStale() {
        let freshness = max(Self.reopenFreshness, pollIntervals.values.max() ?? 0)
        if lastFullRefresh.map({ clock().timeIntervalSince($0) >= freshness }) ?? true { refresh() }
    }

    private func accountsForRefresh() async throws -> [GitHubAccount] {
        if let cached = cachedAccounts, clock().timeIntervalSince(cached.loadedAt) < Self.accountsLifetime {
            return cached.accounts
        }
        let loaded = try await loadAccounts()
        cachedAccounts = (loaded, clock())
        return loaded
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        if threads.isEmpty, phase != .loaded { phase = .loading }
        let started = clock()
        lastFullRefresh = started
        let accounts: [GitHubAccount]
        do {
            accounts = try await accountsForRefresh()
        } catch {
            fail(error as? NotificationsFetchError ?? .failed(error.localizedDescription))
            return
        }
        self.accounts = accounts.map(\.login)
        var fetched: [String: NotificationsFetchPlan.Result] = [:]
        var failures: [String] = []
        let probe = Self.probeQuery
        await withTaskGroup(of: (String, Result<NotificationsFetchPlan.Result, Error>, String?, TimeInterval?).self) { group in
            for account in accounts {
                group.addTask { [api, plan] in
                    // The baseline for later "changed?" probes is taken before reading.
                    var stamp: String?
                    var interval: TimeInterval?
                    if case .page(let page)? = try? await api.list(account: account, query: probe) {
                        stamp = page.lastModified
                        interval = page.pollInterval
                    }
                    do {
                        return (account.login, .success(try await plan.fetch(account: account, api: api, now: started)), stamp, interval)
                    } catch {
                        return (account.login, .failure(error), stamp, interval)
                    }
                }
            }
            for await (login, result, stamp, interval) in group {
                if let interval { pollIntervals[login] = interval }
                switch result {
                case .success(let value):
                    fetched[login] = value
                    if let stamp { lastModified[login] = stamp }
                case .failure(let error):
                    // No baseline, so the next probe reads this inbox again.
                    lastModified[login] = nil
                    // Reload accounts next time, but keep acting for the ones still signed in.
                    if (error as? GitHubNotificationsAPI.Failure)?.isUnauthorized == true {
                        cachedAccounts?.loadedAt = .distantPast
                    }
                    failures.append("\(login.isEmpty ? "gh" : login): \(error.localizedDescription)")
                }
            }
        }
        guard !fetched.isEmpty else {
            fail(.failed("Couldn’t read notifications from GitHub. " + failures.joined(separator: " ")))
            return
        }
        apply(fetched, accounts: accounts, started: started)
        seedFirstLook()
        warning = failures.isEmpty ? nil : "Some accounts weren’t refreshed. " + failures.joined(separator: " ")
        lastUpdated = clock()
        if phase != .loaded { loadedAt = loadedAt ?? clock() }
        phase = .loaded
        readingDetails = true
        // Sessions Pull Requests started for a PR link at once; transcript matches
        // follow each PR's branch as its details arrive.
        await matchSessions()
        await readDetails(accounts: accounts)
        readingDetails = false
        await matchSessions()
        announceNewThreads(fetchedAccounts: Set(fetched.keys))
        publish()
    }

    private func fail(_ error: NotificationsFetchError) {
        if threads.isEmpty {
            phase = .failed(error)
        } else {
            warning = "GitHub refresh failed. Showing the last successful results. \(error.message)"
        }
    }

    /// Replaces each fetched account's threads, keeping what this copy did to
    /// them while the fetch was in flight.
    private func apply(_ fetched: [String: NotificationsFetchPlan.Result], accounts: [GitHubAccount], started: Date) {
        let known = Set(accounts.map(\.login))
        var merged = threads.filter { fetched[$0.account] == nil && known.contains($0.account) }
        for (_, result) in fetched {
            for var thread in result.threads {
                if let done = doneLocally[thread.key] {
                    if thread.updatedAt <= done { continue }
                    doneLocally[thread.key] = nil
                }
                if let read = readLocally[thread.key] {
                    if thread.updatedAt <= read { thread.unread = false } else { readLocally[thread.key] = nil }
                }
                merged.append(thread)
            }
        }
        truncatedAccounts = Set(fetched.filter(\.value.truncated).map(\.key))
        // A done still in flight keeps its details, in case it fails and comes back.
        let present = Set(merged.map(\.key)).union(doneLocally.keys)
        details = details.filter { present.contains($0.key) }
        settled = settled.filter { present.contains($0) }
        detailVersions = detailVersions.filter { present.contains($0.key) }
        detailReadAt = detailReadAt.filter { present.contains($0.key) }
        threads = merged
    }

    private func readDetails(accounts: [GitHubAccount]) async {
        let now = clock()
        let stale = threads.filter { thread in
            guard (thread.kind == .pullRequest || thread.kind == .issue) && thread.number != nil else { return false }
            if detailVersions[thread.key] != thread.updatedAt { return true }
            // An unread request on a still-open PR is checked again now and then.
            return thread.unread && thread.reason == .reviewRequested && details[thread.key]?.state?.isSettled != true
                && now.timeIntervalSince(detailReadAt[thread.key] ?? .distantPast) >= Self.openDetailLifetime
        }
        guard !stale.isEmpty else { return }
        let byAccount = Dictionary(grouping: stale, by: \.account)
        for account in accounts {
            guard let threads = byAccount[account.login] else { continue }
            let result = await detailsFetcher.details(for: threads, account: account)
            var answered = result.details
            if let login = result.viewerLogin {
                let organizations = Set(answered.values.flatMap(\.requestedTeams).compactMap { $0.split(separator: "/").first.map(String.init) })
                for organization in organizations where viewerTeams["\(account.login)|\(organization.lowercased())"] == nil {
                    if let teams = await detailsFetcher.viewerTeams(organization: organization, account: account, login: login) {
                        viewerTeams["\(account.login)|\(organization.lowercased())"] = teams
                    }
                }
                for (key, detail) in answered where !detail.requestedTeams.isEmpty {
                    answered[key]?.viewerTeam = detail.requestedTeams.first { team in
                        let organization = team.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
                        return viewerTeams["\(account.login)|\(organization)"]?.contains(team.lowercased()) == true
                    }
                }
            }
            let versions = Dictionary(uniqueKeysWithValues: threads.map { ($0.key, $0.updatedAt) })
            for key in result.settled {
                // A subject GitHub didn't answer for is asked about again next time.
                if answered[key] != nil {
                    detailVersions[key] = versions[key]
                    detailReadAt[key] = now
                }
                details[key] = answered[key]
            }
            settled.formUnion(result.settled)
        }
    }

    // MARK: Sessions

    private func runWorkspaceLoop() async {
        await pollWorkspace()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.workspacePollInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if isVisible() { await pollWorkspace() }
        }
    }

    func pollWorkspace() async {
        apply(await source.snapshot())
        if Self.signature(liveSessions) != linkedSessions { await matchSessions() }
    }

    func apply(_ fetch: WorkspaceFetch) {
        let state: WorkspaceState
        switch fetch {
        case .snapshot(let snapshot):
            lastGoodSnapshot = snapshot
            state = .connected(snapshot)
        case .unreachable:
            state = .disconnected(lastGood: lastGoodSnapshot)
        }
        if workspace != state { workspace = state }
    }

    /// Ties each pull request thread to the live session working on it: the one
    /// Pull Requests started for it, or the one whose transcript names its branch.
    private static func signature(_ sessions: [String: PullRequestSession]) -> [String] {
        sessions.values.map { "\($0.id)|\($0.copilotSessionId ?? "")|\($0.pullRequestKeys.joined(separator: ","))" }.sorted()
    }

    func matchSessions() async {
        let sessions = liveSessions
        linkedSessions = Self.signature(sessions)
        var heads: [PullRequestKey: String] = [:]
        for thread in threads {
            guard let key = thread.pullRequestKey else { continue }
            heads[key] = details[thread.key]?.headRefName ?? heads[key] ?? ""
        }
        guard !heads.isEmpty, !sessions.isEmpty else {
            if !links.isEmpty { links = [:] }
            return
        }
        var matched: [PullRequestKey: String] = [:]
        for session in sessions.values.sorted(by: { $0.id < $1.id }) {
            for text in session.pullRequestKeys {
                if let key = PullRequestKey(text), heads[key] != nil, matched[key] == nil { matched[key] = session.id }
            }
        }
        let sources = sessions.values.sorted { $0.id < $1.id }.compactMap { session -> PullRequestTranscriptIndex.Source? in
            guard let copilotId = session.copilotSessionId, let path = transcriptPath(copilotId) else { return nil }
            return PullRequestTranscriptIndex.Source(sessionId: session.id, path: path)
        }
        if !sources.isEmpty {
            // As Pull Requests does: only a distinctive branch name is worth finding in a transcript.
            let evidence = await transcripts.evidence(for: sources, branches: Set(heads.values.filter(PullRequestLinker.isDistinctiveBranch)))
            // A PR whose branch isn't known yet isn't inferred at all: on its URL
            // alone, a session that only reviews it could win over the one building it.
            let unmatched = heads.filter { matched[$0.key] == nil && !$0.value.isEmpty }
                .map { (key: $0.key, headRefName: $0.value) }
            matched.merge(PullRequestLinker.links(heads: unmatched, evidence: evidence)) { current, _ in current }
        }
        if links != matched { links = matched }
    }

    // MARK: Looking

    /// The window became key. Moving between the window and its own popovers
    /// is one look.
    func beganLooking() {
        guard lookStarted == nil else { return }
        lookStarted = clock()
        guard columnsLookedAt != lookedAt else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            columnsLookedAt = lookedAt
        } else {
            withAnimation(.easeOut(duration: 0.2)) { columnsLookedAt = lookedAt }
        }
    }

    /// The app went to the background, or the window closed: what it showed has
    /// been seen, counting only from when there were threads to see.
    func finishedLooking() {
        guard let started = lookStarted else { return }
        lookStarted = nil
        let now = clock()
        guard phase == .loaded, let loadedAt, now.timeIntervalSince(max(started, loadedAt)) >= Self.minimumLook else { return }
        lookedAt = now
        if writesState { defaults.set(now.timeIntervalSince1970, forKey: Self.lookedAtKey) }
    }

    var isLooking: Bool { lookStarted != nil }

    /// Before the window was ever looked at, the last time the user read a
    /// notification on GitHub stands in, so the first view spreads threads
    /// across the days instead of calling everything unread new.
    private func seedFirstLook() {
        guard lookedAt == nil, let lastRead = threads.compactMap(\.lastReadAt).max() else { return }
        lookedAt = lastRead
        columnsLookedAt = lastRead
        if writesState { defaults.set(lastRead.timeIntervalSince1970, forKey: Self.lookedAtKey) }
    }

    // MARK: Actions

    /// Opens the thread on GitHub and marks it read there.
    func open(_ item: NotificationItem) {
        openURL(item.thread.webURL)
        if item.thread.unread { markRead([item]) }
    }

    /// Shows the session working on `item`'s pull request; reaching it opens
    /// the thread, so it's marked read as opening it on GitHub would.
    func goToSession(_ session: PullRequestSession, for item: NotificationItem? = nil) {
        guard case .connected(let snapshot) = workspace else {
            host.open?()
            return
        }
        let pid = snapshot.hostProcessIdentifier
        Task {
            if case .done = await source.revealSession(projectId: session.projectId, sessionId: session.id) {
                host.activate(pid)
                if let item, item.thread.unread { markRead([item]) }
            } else {
                await pollWorkspace()
            }
        }
    }

    func openHost() { host.open?() }

    func copyLink(_ item: NotificationItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.thread.webURL.absoluteString, forType: .string)
    }

    func markRead(_ items: [NotificationItem]) {
        let targets = items.filter(\.thread.unread).map(\.thread)
        guard !targets.isEmpty else { return }
        let now = clock()
        for thread in targets { readLocally[thread.key] = now }
        update(targets.map(\.key)) { $0.unread = false }
        perform(targets, verb: "mark as read", action: { api, account, id in try await api.markRead(account: account, threadId: id) }) { [weak self] failed in
            for thread in failed { self?.readLocally[thread.key] = nil }
            self?.update(failed.map(\.key)) { $0.unread = true }
        }
    }

    func markDone(_ items: [NotificationItem]) {
        remove(items.map(\.thread), verb: "mark as done") { api, account, id in
            try await api.markDone(account: account, threadId: id)
        }
    }

    /// Ignores the thread, even in a watched repository, and clears it, as
    /// GitHub's own Unsubscribe does. A mention or a new request still notifies.
    func unsubscribe(_ item: NotificationItem) {
        remove([item.thread], verb: "unsubscribe from") { api, account, id in
            try await api.unsubscribe(account: account, threadId: id)
            try await api.markDone(account: account, threadId: id)
        }
    }

    private func remove(
        _ targets: [NotificationThread], verb: String,
        action: @escaping @Sendable (GitHubNotificationsAPI, GitHubAccount, String) async throws -> Void
    ) {
        guard !targets.isEmpty else { return }
        let keys = Set(targets.map(\.key))
        for thread in targets { doneLocally[thread.key] = thread.updatedAt }
        animate { self.threads.removeAll { keys.contains($0.key) } }
        publish()
        perform(targets, verb: verb, action: action) { [weak self] failed in
            guard let self else { return }
            for thread in failed { self.doneLocally[thread.key] = nil }
            let present = Set(self.threads.map(\.key))
            self.animate { self.threads += failed.filter { !present.contains($0.key) } }
        }
    }

    private func perform(
        _ targets: [NotificationThread], verb: String,
        action: @escaping @Sendable (GitHubNotificationsAPI, GitHubAccount, String) async throws -> Void,
        rollback: @escaping ([NotificationThread]) -> Void
    ) {
        let api = api
        Task { [weak self] in
            guard let self else { return }
            let accounts = Dictionary((cachedAccounts?.accounts ?? []).map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
            var failed: [NotificationThread] = []
            var message: String?
            // A few at a time: a whole lane can be hundreds of threads.
            var queue = targets[...]
            while !queue.isEmpty {
                let batch = queue.prefix(6)
                queue = queue.dropFirst(6)
                let results = await withTaskGroup(of: (NotificationThread, String?).self) { group in
                    for thread in batch {
                        group.addTask {
                            guard let account = accounts[thread.account] else {
                                return (thread, "\(thread.account) is no longer signed in to gh")
                            }
                            do {
                                try await action(api, account, thread.key.id)
                                return (thread, nil)
                            } catch {
                                return (thread, error.localizedDescription)
                            }
                        }
                    }
                    var results: [(NotificationThread, String?)] = []
                    for await result in group { results.append(result) }
                    return results
                }
                for (thread, error) in results where error != nil {
                    failed.append(thread)
                    message = error
                }
            }
            guard !failed.isEmpty else { return }
            rollback(failed)
            let what = failed.count == 1 ? "“\(failed[0].title)”" : "\(failed.count) notifications"
            warning = "Couldn’t \(verb) \(what). \(message ?? "")"
            publish()
        }
    }

    private func update(_ keys: [NotificationThread.Key], _ change: (inout NotificationThread) -> Void) {
        let keys = Set(keys)
        for index in threads.indices where keys.contains(threads[index].key) { change(&threads[index]) }
        publish()
    }

    private func animate(_ change: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            change()
        } else {
            withAnimation(.easeOut(duration: 0.2), change)
        }
    }

    // MARK: Badge, summary, banners

    /// Puts the needs-you count on the Dock and in the summary Copilot Projects reads.
    func publish() {
        guard !readingDetails else { return }
        let counts = counts
        setBadge(counts.badgeLabel)
        onCounts?(counts)
        guard writesState, let summaryURL, phase == .loaded else { return }
        // Stamped now: a local read or done is fresh even when GitHub was read long ago.
        let summary = NotificationsSummary(
            needsYou: counts.needsYou, toYou: counts.toYou, viaTeams: counts.viaTeams,
            watching: counts.watching, updatedAt: clock()
        )
        do { try summary.write(to: summaryURL) } catch {
            NSLog("copilot-notifications: could not write its summary: \(error)")
        }
    }

    /// Banners for unread threads that need the user and changed since the
    /// last announcement, never the backlog and never while they're looking.
    /// Each account keeps its own high-water mark, moved only by its own
    /// successful reads, so one account's failed refresh can't lose another's
    /// banners. An account seen for the first time announces nothing.
    func announceNewThreads(fetchedAccounts: Set<String>) {
        let fresh = items.filter { item in
            guard fetchedAccounts.contains(item.thread.account),
                  let highWater = bannerHighWaters[item.thread.account] else { return false }
            return item.needsYou && bannersEnabled(for: item.lane.band) && item.thread.updatedAt > highWater
                && announced[item.id].map { $0 < item.thread.updatedAt } ?? true
        }
        let now = clock()
        for account in fetchedAccounts {
            let newest = threads.filter { $0.account == account }.map(\.updatedAt).max()
            let current = bannerHighWaters[account]
            bannerHighWaters[account] = [current ?? now, newest ?? .distantPast].max()
        }
        if writesState {
            defaults.set(bannerHighWaters.mapValues(\.timeIntervalSince1970), forKey: Self.bannerHighWaterKey)
        }
        guard !fresh.isEmpty, !isLooking else { return }
        for item in fresh { announced[item.id] = item.thread.updatedAt }
        banners?.post(Self.banners(for: fresh.sorted(by: NotificationLayout.order)))
    }

    static func banners(for items: [NotificationItem]) -> [NotificationBanner] {
        guard items.count > individualBannerLimit else { return items.map(banner) }
        let counts = NotificationCounts(items: items)
        let parts = [
            counts.toYou > 0 ? "\(counts.toYou) to you" : nil,
            counts.viaTeams > 0 ? "\(counts.viaTeams) via your teams" : nil,
            counts.watching > 0 ? "\(counts.watching) watching" : nil,
        ].compactMap { $0 }
        return [NotificationBanner(
            identifier: "summary-\(UUID().uuidString)", title: "\(items.count) new notifications need you",
            subtitle: nil, body: parts.joined(separator: " · "), url: nil, thread: nil
        )]
    }

    static func banner(_ item: NotificationItem) -> NotificationBanner {
        let title: String
        switch item.lane {
        case .reviewRequested: title = item.thread.reason == .approvalRequested ? "Approval requested" : "Review requested"
        case .teamReviewRequested: title = item.detail?.teamToName.map { "@\($0) was asked to review" } ?? "Your team was asked to review"
        case .mentioned: title = "You were mentioned"
        case .teamMentioned: title = "Your team was mentioned"
        case .assigned: title = "Assigned to you"
        case .yourWork: title = "Activity on your \(item.thread.kind == .pullRequest ? "pull request" : "thread")"
        case .conversations: title = "New in a conversation you’re in"
        case .watchedRepositories, .subscribedThreads: title = "New in \(item.thread.repository)"
        case .ciActivity, .other: title = item.thread.kind.label
        }
        return NotificationBanner(
            identifier: "\(item.thread.key)|\(Int(item.thread.updatedAt.timeIntervalSince1970))",
            title: title, subtitle: item.thread.shortName, body: item.thread.title,
            url: item.thread.webURL, thread: item.thread.key
        )
    }

    /// A banner was clicked: open its thread and mark it read, even when the
    /// thread isn't loaded here (yet, or any more).
    func openBanner(thread key: NotificationThread.Key?, url: URL?) {
        if let key, let item = items.first(where: { $0.id == key }) {
            open(item)
            return
        }
        if let url { openURL(url) }
        if let key { markRead(key: key) }
    }

    private func markRead(key: NotificationThread.Key) {
        readLocally[key] = clock()
        let api = api
        Task { [weak self] in
            guard let self else { return }
            guard let account = (try? await self.accountsForRefresh())?.first(where: { $0.login == key.account }) else {
                self.readLocally[key] = nil
                return
            }
            do {
                try await api.markRead(account: account, threadId: key.id)
            } catch {
                self.readLocally[key] = nil
                // A refresh may have loaded it, read, in the meantime.
                self.update([key]) { $0.unread = true }
                self.warning = "Couldn’t mark a notification as read. \(error.localizedDescription)"
            }
        }
    }

    private static func bannerKey(_ band: NotificationBand) -> String { "notifications.banners.\(band)" }

    private func saveBannerSetting(_ band: NotificationBand, _ enabled: Bool) {
        if writesState { defaults.set(enabled, forKey: Self.bannerKey(band)) }
    }

    // MARK: Fixtures

    /// Shows threads read elsewhere, as a completed refresh. Used by captures
    /// and tests, which must not reach GitHub.
    func show(
        _ threads: [NotificationThread], details: [NotificationThread.Key: NotificationSubjectDetail] = [:],
        settled: Set<NotificationThread.Key>? = nil, accounts: [String], links: [PullRequestKey: String] = [:],
        lookedAt: Date? = nil, updated: Date = Date(), truncated: Set<String> = [], warning: String? = nil
    ) {
        self.threads = threads
        self.details = details
        self.settled = settled ?? Set(details.keys)
        self.accounts = accounts
        self.links = links
        self.lookedAt = lookedAt
        columnsLookedAt = lookedAt
        lastUpdated = updated
        truncatedAccounts = truncated
        self.warning = warning
        loadedAt = loadedAt ?? clock()
        phase = .loaded
    }
}
