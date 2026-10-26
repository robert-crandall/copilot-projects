import SwiftUI
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol

/// State for one presentation of the session finder. Name, project, folder, and
/// conversation matches are instant; Luna adds meaning-based picks after the
/// user pauses typing.
@MainActor
final class SessionFinderModel: ObservableObject, Identifiable {
    enum LunaPhase: Equatable {
        case idle
        /// Waiting for the user to pause before asking.
        case pending
        case searching
        case finished([LunaMatch])
        case failed(String)
    }

    enum DeepSearchPhase: Equatable {
        case idle
        /// Waiting for the user to pause before searching history when no initial entries are loaded.
        case pending
        case searching
        case finished([LunaMatch])
        case failed(String)
    }

    enum Section: Hashable {
        case recent, recentEnded, matches, luna, history

        var title: String {
            switch self {
            case .recent: return "Recent Sessions"
            case .recentEnded: return "Recent Ended Sessions"
            case .matches: return "Matches"
            case .luna: return "Suggested by Luna"
            case .history: return "Session History"
            }
        }
    }

    static let maximumRecentEndedRows = 15

    struct Row: Identifiable {
        let entry: SessionFinderEntry
        let section: Section
        /// The conversation excerpt that matched, when the name, project, and folder did not.
        let snippet: String?
        /// Why Luna picked this session, if it did.
        let lunaReason: String?
        var id: String { entry.id }
    }

    /// What VoiceOver hears about the highlighted row.
    struct Highlight: Equatable {
        let sessionId: String?
        let lunaReason: String?

        /// A new row is always worth hearing; the same row only when Luna adds or
        /// changes its reason, not when a reason drops away mid-typing.
        func isWorthAnnouncing(after previous: Highlight) -> Bool {
            sessionId != previous.sessionId || (lunaReason != nil && lunaReason != previous.lunaReason)
        }
    }

    nonisolated let id = UUID()
    @Published var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var luna: LunaPhase = .idle
    @Published private(set) var deepSearch: DeepSearchPhase = .idle
    @Published private(set) var highlightedId: String?
    @Published private(set) var isIndexing = true
    @Published private(set) var isLoadingResumable = true
    @Published private(set) var resumeError: String?

    var highlight: Highlight {
        Highlight(sessionId: highlightedId, lunaReason: rows.first { $0.id == highlightedId }?.lunaReason)
    }

    /// Luna's picks that are still listed. Picks for sessions that ended since are
    /// left out, including ones from a cached or late answer.
    var lunaSuggestionCount: Int {
        rows.reduce(0) { $0 + ($1.lunaReason == nil ? 0 : 1) }
    }

    private(set) var entries: [SessionFinderEntry]
    private var deepEntriesById: [String: SessionFinderEntry] = [:]
    private var liveSessionIds: Set<String>
    private var activeCopilotSessionIds: Set<String> = []
    private var localMatches: [SessionFinderSearch.LocalMatch] = []
    private var displayedLunaMatches: [LunaMatch] = []
    private var lunaCache: [String: [LunaMatch]] = [:]
    private var deepCache: [String: [LunaMatch]] = [:]
    private var lunaFailedWithNonRecoverableError = false
    private var indexTask: Task<Void, Never>?
    private var lunaTask: Task<Void, Never>?
    private var deepTask: Task<Void, Never>?
    private var userMovedHighlight = false
    private let currentSessionId: String?
    private let ranker: SessionRanking
    private let historySearcher: SessionHistorySearching?
    private let lunaDelay: TimeInterval
    private let loadResumableEntriesByIds: @Sendable ([String]) -> [SessionFinderEntry]
    private let onOpen: (String) -> Void

    init(
        sources: [SessionFinderSource],
        currentSessionId: String? = nil,
        activeCopilotSessionIds: Set<String> = [],
        ranker: SessionRanking = LunaSessionRanker(),
        historySearcher: SessionHistorySearching? = nil,
        lunaDelay: TimeInterval = 0.6,
        loadTranscript: @escaping @Sendable (String) -> TranscriptSnapshot? = {
            TranscriptController.loadRemoteSnapshot(sessionId: $0)
        },
        loadResumableEntries: @escaping @Sendable () -> [SessionFinderEntry] = { [] },
        loadResumableEntriesByIds: @escaping @Sendable ([String]) -> [SessionFinderEntry] = { _ in [] },
        onOpen: @escaping (String) -> Void
    ) {
        self.currentSessionId = currentSessionId
        self.activeCopilotSessionIds = Set(activeCopilotSessionIds.map { $0.lowercased() })
        self.ranker = ranker
        self.historySearcher = historySearcher
        self.lunaDelay = lunaDelay
        self.loadResumableEntriesByIds = loadResumableEntriesByIds
        self.onOpen = onOpen
        entries = sources.map { SessionFinderEntry(source: $0) }
        liveSessionIds = Set(sources.map(\.sessionId))
        rebuildRows()
        indexTask = Task { [weak self] in
            let liveScan = Task.detached(priority: .userInitiated) {
                SessionFinderSearch.index(sources, loadTranscript: loadTranscript)
            }
            let liveIndexed = await withTaskCancellationHandler {
                await liveScan.value
            } onCancel: {
                liveScan.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.entries = liveIndexed
            self.isIndexing = false
            self.refreshLocalMatches()
            self.scheduleLuna()

            let resumableScan = Task.detached(priority: .userInitiated) {
                loadResumableEntries()
            }
            let resumableIndexed = await withTaskCancellationHandler {
                await resumableScan.value
            } onCancel: {
                resumableScan.cancel()
            }
            guard !Task.isCancelled else { return }
            self.isLoadingResumable = false
            if !resumableIndexed.isEmpty {
                self.lunaTask?.cancel()
                self.lunaTask = nil
                self.deepTask?.cancel()
                self.deepTask = nil
                if !SessionFinderSearch.tokens(self.query).isEmpty, self.highlightedId != nil {
                    self.userMovedHighlight = true
                }
                self.entries = liveIndexed + resumableIndexed
                self.lunaCache.removeAll()
                self.refreshLocalMatches()
                self.scheduleLuna(preserveDisplayedMatches: true)
            } else {
                self.scheduleDeepSearchIfReady()
            }
        }
    }

    private func isAvailable(_ entry: SessionFinderEntry) -> Bool {
        if let copilotId = entry.source.resumableCopilotSessionId?.lowercased() {
            return !activeCopilotSessionIds.contains(copilotId)
        }
        return liveSessionIds.contains(entry.id)
    }

    private var availableEntries: [SessionFinderEntry] {
        entries.filter(isAvailable)
    }

    private var availableDeepEntries: [SessionFinderEntry] {
        deepEntriesById.values.filter(isAvailable)
    }

    var hasResumableSessions: Bool {
        availableEntries.contains { $0.source.isResumable }
            || availableDeepEntries.contains { $0.source.isResumable }
    }

    var highlightedIsResumable: Bool {
        guard let highlightedId else { return false }
        return rows.first { $0.id == highlightedId }?.entry.source.isResumable == true
    }

    func source(for sessionId: String) -> SessionFinderSource? {
        availableEntries.first { $0.id == sessionId }?.source
            ?? availableDeepEntries.first { $0.id == sessionId }?.source
    }

    /// Stops indexing and any Luna or deep-history run. Call when the finder closes.
    func cancel() {
        indexTask?.cancel()
        lunaTask?.cancel()
        deepTask?.cancel()
        indexTask = nil
        lunaTask = nil
        deepTask = nil
    }

    /// Drops sessions that ended while the finder was open and hides ended
    /// sessions that are now live or resuming in a tab.
    func retainSessions(_ sessionIds: Set<String>, activeCopilotSessionIds: Set<String>? = nil) {
        let loweredCopilot = activeCopilotSessionIds.map { Set($0.map { $0.lowercased() }) }
            ?? self.activeCopilotSessionIds
        guard sessionIds != liveSessionIds || loweredCopilot != self.activeCopilotSessionIds else { return }
        liveSessionIds = sessionIds
        self.activeCopilotSessionIds = loweredCopilot
        refreshLocalMatches()
    }

    /// Drops a resumable entry that could not be reopened.
    func removeResumableSession(id: String, error: String? = nil) {
        resumeError = error
        let hadEntry = entries.contains { $0.id == id && $0.source.isResumable }
            || deepEntriesById[id]?.source.isResumable == true
        guard hadEntry else { return }
        entries.removeAll { $0.id == id && $0.source.isResumable }
        deepEntriesById.removeValue(forKey: id)
        refreshLocalMatches()
    }

    func setResumeError(_ message: String?) {
        resumeError = message
    }

    func moveHighlight(_ delta: Int) {
        resumeError = nil
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlightedId } ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(current + delta, 0), rows.count - 1)
        highlightedId = rows[next].id
        userMovedHighlight = true
    }

    func openHighlighted() {
        guard let sessionId = highlightedId ?? rows.first?.id else { return }
        onOpen(sessionId)
    }

    func open(_ sessionId: String) {
        onOpen(sessionId)
    }

    private func queryDidChange() {
        userMovedHighlight = false
        resumeError = nil
        displayedLunaMatches = []
        lunaFailedWithNonRecoverableError = false
        lunaTask?.cancel()
        deepTask?.cancel()
        lunaTask = nil
        deepTask = nil
        deepSearch = .idle
        refreshLocalMatches()
        scheduleLuna()
    }

    private func refreshLocalMatches() {
        localMatches = SessionFinderSearch.localMatches(for: query, in: availableEntries)
        rebuildRows()
    }

    /// Any query with a non-space character goes to Luna once typing pauses.
    private func scheduleLuna(preserveDisplayedMatches: Bool = false) {
        lunaTask?.cancel()
        deepTask?.cancel()
        lunaTask = nil
        deepTask = nil
        lunaFailedWithNonRecoverableError = false
        let text = SessionFinderSearch.collapseWhitespace(query)
        let searchable = availableEntries
        guard !isIndexing, !text.isEmpty else {
            displayedLunaMatches = []
            luna = .idle
            deepSearch = .idle
            rebuildRows()
            return
        }
        guard !searchable.isEmpty else {
            displayedLunaMatches = []
            luna = .idle
            rebuildRows()
            scheduleDeepSearchIfReady()
            return
        }
        let key = SessionFinderSearch.fold(text)
        if let cached = lunaCache[key] {
            displayedLunaMatches = cached
            luna = .finished(cached)
            rebuildRows()
            scheduleDeepSearchIfReady()
            return
        }
        if !preserveDisplayedMatches {
            displayedLunaMatches = []
            deepSearch = .idle
        }
        let previousDisplayed = displayedLunaMatches
        luna = .pending
        rebuildRows()
        let ranker = ranker
        let delay = lunaDelay
        lunaTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.luna = .searching
            let phase: LunaPhase
            do {
                let matches = try await ranker.rank(query: text, entries: searchable)
                guard !Task.isCancelled else { return }
                let combined: [LunaMatch]
                if preserveDisplayedMatches && !previousDisplayed.isEmpty {
                    let seen = Set(matches.map(\.sessionId))
                    combined = matches + previousDisplayed.filter { !seen.contains($0.sessionId) }
                } else {
                    combined = matches
                }
                self?.displayedLunaMatches = combined
                self?.lunaCache[key] = combined
                phase = .finished(combined)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if preserveDisplayedMatches && !previousDisplayed.isEmpty {
                    phase = .finished(previousDisplayed)
                } else {
                    self?.displayedLunaMatches = []
                    if let lunaError = error as? LunaSearchError,
                       lunaError == .copilotUnavailable || lunaError == .notSignedIn {
                        self?.lunaFailedWithNonRecoverableError = true
                    }
                    phase = .failed((error as? LunaSearchError)?.message ?? error.localizedDescription)
                }
            }
            self?.luna = phase
            self?.rebuildRows()
            self?.scheduleDeepSearchIfReady()
        }
    }

    /// Starts the second-stage CLI session-store search once both the initial
    /// resumable scan and the fast in-memory Luna pass have completed.
    private func scheduleDeepSearchIfReady() {
        deepTask?.cancel()
        deepTask = nil
        let text = SessionFinderSearch.collapseWhitespace(query)
        guard let historySearcher, !isIndexing, !isLoadingResumable, !text.isEmpty else {
            if text.isEmpty {
                deepSearch = .idle
            }
            return
        }
        let lunaReady: Bool
        var needsDebounce = false
        switch luna {
        case .finished:
            lunaReady = true
        case .failed:
            lunaReady = !lunaFailedWithNonRecoverableError
        case .idle where availableEntries.isEmpty:
            lunaReady = true
            needsDebounce = true
        default:
            lunaReady = false
        }
        guard lunaReady else { return }

        let key = SessionFinderSearch.fold(text)
        if let cached = deepCache[key] {
            deepSearch = .finished(cached)
            rebuildRows()
            return
        }

        let delay = needsDebounce ? lunaDelay : 0
        deepSearch = needsDebounce ? .pending : .searching
        rebuildRows()

        let loadByIds = loadResumableEntriesByIds
        deepTask = Task { [weak self] in
            if needsDebounce {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            let preflight: (excluded: Set<String>, knownIds: Set<String>)? = {
                guard !Task.isCancelled, let self, !self.isIndexing, !self.isLoadingResumable else { return nil }
                let currentKey = SessionFinderSearch.fold(SessionFinderSearch.collapseWhitespace(self.query))
                guard currentKey == key else { return nil }
                if needsDebounce {
                    self.deepSearch = .searching
                    self.rebuildRows()
                }
                let excluded = self.activeCopilotSessionIds.union(
                    self.rows.compactMap { $0.entry.source.resumableCopilotSessionId?.lowercased() }
                )
                let knownIds = Set(self.entries.map(\.id)).union(self.deepEntriesById.keys)
                return (excluded, knownIds)
            }()
            guard let preflight else { return }
            let phase: DeepSearchPhase
            do {
                let matches = try await historySearcher.searchHistory(
                    query: text,
                    excludedCopilotSessionIds: preflight.excluded
                )
                guard !Task.isCancelled, let self else { return }
                let currentKey = SessionFinderSearch.fold(SessionFinderSearch.collapseWhitespace(self.query))
                guard currentKey == key else { return }

                let missingCopilotIds: [String] = matches.compactMap { match in
                    guard !preflight.knownIds.contains(match.sessionId),
                          match.sessionId.hasPrefix("resumable:") else {
                        return nil
                    }
                    return String(match.sessionId.dropFirst("resumable:".count))
                }
                if !missingCopilotIds.isEmpty {
                    let loadTask = Task.detached(priority: .userInitiated) {
                        loadByIds(missingCopilotIds)
                    }
                    let loaded = await withTaskCancellationHandler {
                        await loadTask.value
                    } onCancel: {
                        loadTask.cancel()
                    }
                    guard !Task.isCancelled else { return }
                    let postLoadKey = SessionFinderSearch.fold(SessionFinderSearch.collapseWhitespace(self.query))
                    guard postLoadKey == key else { return }
                    for entry in loaded {
                        self.deepEntriesById[entry.id] = entry
                    }
                }

                let validIds = Set(self.availableEntries.map(\.id))
                    .union(self.availableDeepEntries.map(\.id))
                let validated = matches.filter { validIds.contains($0.sessionId) }
                if self.highlightedId != nil, !validated.isEmpty {
                    self.userMovedHighlight = true
                }
                self.deepCache[key] = validated
                phase = .finished(validated)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                let currentKey = SessionFinderSearch.fold(SessionFinderSearch.collapseWhitespace(self.query))
                guard currentKey == key else { return }
                phase = .failed((error as? LunaSearchError)?.message ?? error.localizedDescription)
            }
            self?.deepSearch = phase
            self?.rebuildRows()
        }
    }

    private func rebuildRows() {
        let available = availableEntries
        let deepAvailable = availableDeepEntries
        let live = available.filter { !$0.source.isResumable }
        let resumable = available.filter(\.source.isResumable)
        let availableIds = Set(available.map(\.id))
        var built: [Row]
        let browsing = SessionFinderSearch.tokens(query).isEmpty
        if browsing {
            let liveRows = SessionFinderSearch.recent(live).map {
                Row(entry: $0, section: .recent, snippet: nil, lunaReason: nil)
            }
            let endedRows = SessionFinderSearch.recent(resumable)
                .prefix(Self.maximumRecentEndedRows)
                .map {
                    Row(entry: $0, section: .recentEnded, snippet: nil, lunaReason: nil)
                }
            built = liveRows + endedRows
        } else {
            let lunaPicks: [LunaMatch]
            if case .finished(let matches) = luna {
                lunaPicks = matches
            } else {
                lunaPicks = displayedLunaMatches
            }
            let deepPicks: [LunaMatch]
            if case .finished(let matches) = deepSearch {
                deepPicks = matches
            } else {
                deepPicks = []
            }
            var seenPickIds = Set<String>()
            let picks = (lunaPicks + deepPicks).filter { seenPickIds.insert($0.sessionId).inserted }
            let reasons = Dictionary(picks.map { ($0.sessionId, $0.reason) }, uniquingKeysWith: { first, _ in first })
            built = localMatches.filter { availableIds.contains($0.entry.id) }.map { match in
                Row(
                    entry: match.entry, section: .matches,
                    snippet: match.snippet, lunaReason: reasons[match.entry.id]
                )
            }
            // Luna's extra picks go below the instant matches so a late answer never
            // moves the row under the cursor, and deep-history picks follow under their own section.
            var listed = Set(built.map(\.id))
            let byId = Dictionary(
                (available + deepAvailable).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var seenLunaIds = Set<String>()
            for pick in lunaPicks where seenLunaIds.insert(pick.sessionId).inserted && !listed.contains(pick.sessionId) {
                guard let entry = byId[pick.sessionId] else { continue }
                listed.insert(pick.sessionId)
                built.append(Row(entry: entry, section: .luna, snippet: nil, lunaReason: pick.reason))
            }
            var seenDeepIds = Set<String>()
            for pick in deepPicks where seenDeepIds.insert(pick.sessionId).inserted && !listed.contains(pick.sessionId) {
                guard let entry = byId[pick.sessionId] else { continue }
                listed.insert(pick.sessionId)
                built.append(Row(entry: entry, section: .history, snippet: nil, lunaReason: pick.reason))
            }
        }
        rows = built
        if !(userMovedHighlight && built.contains { $0.id == highlightedId }) {
            // Browsing defaults past the current session among live tabs, like ⌘Tab.
            let liveBrowsing = browsing ? built.filter { !$0.entry.source.isResumable } : []
            let preferred = browsing
                ? (liveBrowsing.first { $0.id != currentSessionId } ?? liveBrowsing.first ?? built.first)
                : nil
            highlightedId = (preferred ?? built.first)?.id
            userMovedHighlight = false
        }
    }
}

extension AppModel {
    /// When the transcript last changed: the later of its sealed file and the
    /// live file of the turn in progress. `nil` without a sealed file.
    nonisolated static func transcriptLastActivity(sessionId: String) -> Date? {
        let modified = { (path: String) in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        guard let sealed = modified(Paths.transcriptSnapshotPath(sessionId: sessionId)) else {
            return nil
        }
        return max(sealed, modified(Paths.transcriptLivePath(sessionId: sessionId)) ?? sealed)
    }

    var sessionFinderSources: [SessionFinderSource] {
        projects.flatMap { project in
            project.sessions.map {
                SessionFinderSource(
                    sessionId: $0.id, projectId: project.id, projectName: project.name,
                    title: $0.title, cwd: $0.cwd,
                    lastActivity: Self.transcriptLastActivity(sessionId: $0.id)
                )
            }
        }
    }

    var sessionFinderProjectTargets: [SessionFinderProjectTarget] {
        projects.map { project in
            SessionFinderProjectTarget(
                id: project.id,
                name: project.name,
                cwd: project.cwd,
                sessionCwds: project.sessions.map(\.cwd)
            )
        }
    }
}

struct SessionFinderView: View {
    @ObservedObject var finder: SessionFinderModel
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var markerCopilotSessionIds: Set<String> = []

    private struct LiveSession {
        let session: Session
        let projectName: String
    }

    var body: some View {
        let live = liveSessions
        VStack(spacing: 0) {
            searchField
            Divider()
            results(live: live)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 460)
        .background(StudioStyle.chrome)
        .defaultFocus($searchFocused, true)
        .task(id: liveSessionIds) {
            let ids = liveSessionIds
            let directory = model.resumeMarkerDirectory
            let validated = await Task.detached(priority: .utility) {
                AppModel.validatedMarkerCopilotSessionIds(sessionIds: ids, directory: directory)
            }.value
            guard !Task.isCancelled else { return }
            markerCopilotSessionIds = validated
        }
        .onAppear {
            searchFocused = true
            finder.retainSessions(Set(liveSessionIds), activeCopilotSessionIds: activeCopilotSessionIds)
            announce(finder.highlightedId, live: live)
        }
        .onDisappear { finder.cancel() }
        .onChange(of: liveSessionIds) { _, ids in
            finder.retainSessions(Set(ids), activeCopilotSessionIds: activeCopilotSessionIds)
        }
        .onChange(of: activeCopilotSessionIds) { _, copilotIds in
            finder.retainSessions(Set(liveSessionIds), activeCopilotSessionIds: copilotIds)
        }
        .onChange(of: finder.highlight) { previous, highlight in
            if highlight.isWorthAnnouncing(after: previous) { announce(highlight.sessionId, live: live) }
        }
    }

    private var liveSessionIds: [String] {
        model.projects.flatMap { $0.sessions.map(\.id) }
    }

    private var activeCopilotSessionIds: Set<String> {
        model.inMemoryActiveCopilotSessionIds().union(markerCopilotSessionIds)
    }

    private var liveSessions: [String: LiveSession] {
        var sessions: [String: LiveSession] = [:]
        for project in model.projects {
            for session in project.sessions {
                sessions[session.id] = LiveSession(session: session, projectName: project.name)
            }
        }
        return sessions
    }

    /// Focus stays in the search field, so VoiceOver hears the highlighted row.
    private func announce(_ sessionId: String?, live: [String: LiveSession]) {
        guard let sessionId, let row = finder.rows.first(where: { $0.id == sessionId }) else { return }
        var text: String
        if let current = live[sessionId] {
            text = "\(current.session.title), \(current.projectName), \(current.session.attentionLabel)"
        } else if row.entry.source.isResumable {
            text = "\(row.entry.source.title), \(row.entry.source.projectName), Ended, resume in \(row.entry.source.projectName)"
        } else {
            return
        }
        if let reason = row.lunaReason, !reason.isEmpty {
            let prefix = row.section == .history ? "Session History" : "Suggested by Luna"
            text += ". \(prefix): \(reason)"
        }
        AccessibilityNotification.Announcement(text).post()
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(StudioStyle.secondaryText)
                .accessibilityHidden(true)
            TextField(
                "Find Session",
                text: $finder.query,
                prompt: Text("Session name, project, folder, or what you worked on")
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($searchFocused)
            .accessibilityIdentifier("session-finder-field")
            if finder.luna == .searching || finder.deepSearch == .searching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(finder.deepSearch == .searching ? "Searching history" : "Asking Luna")
                }
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private func results(live: [String: LiveSession]) -> some View {
        let rows = finder.rows
        let searching = !SessionFinderSearch.tokens(finder.query).isEmpty
        let isReadingConversations = finder.isIndexing || finder.isLoadingResumable
        if live.isEmpty && !finder.hasResumableSessions && !isReadingConversations
            && finder.deepSearch != .pending && finder.deepSearch != .searching {
            ContentUnavailableView(
                "No Sessions Yet", systemImage: "terminal",
                description: Text("Start a Copilot session with ⌘T, then find it here.")
            )
        } else if rows.isEmpty && isReadingConversations {
            statusList(
                title: searching ? SessionFinderModel.Section.matches.title : SessionFinderModel.Section.recent.title,
                message: "Reading conversations…"
            )
        } else if rows.isEmpty && (finder.luna == .pending || finder.deepSearch == .pending) {
            statusList(title: SessionFinderModel.Section.luna.title, message: "Luna searches when you pause typing.")
        } else if rows.isEmpty && finder.luna == .searching {
            statusList(title: SessionFinderModel.Section.luna.title, message: "Luna is looking through your conversations…")
        } else if rows.isEmpty && finder.deepSearch == .searching {
            statusList(title: SessionFinderModel.Section.history.title, message: "Searching your full session history…")
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: finder.query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections(rows), id: \.section) { group in
                            sectionHeader(group.section.title)
                            ForEach(group.rows) { row in
                                if let current = live[row.id] {
                                    SessionFinderRow(
                                        row: row,
                                        target: .live(session: current.session, projectName: current.projectName),
                                        isHighlighted: row.id == finder.highlightedId,
                                        isCurrent: row.id == model.globalSelectedSessionId,
                                        onOpen: { finder.open(row.id) }
                                    )
                                    .id(row.id)
                                } else if row.entry.source.isResumable {
                                    SessionFinderRow(
                                        row: row,
                                        target: .resumable(projectName: row.entry.source.projectName),
                                        isHighlighted: row.id == finder.highlightedId,
                                        isCurrent: false,
                                        onOpen: { finder.open(row.id) }
                                    )
                                    .id(row.id)
                                }
                            }
                        }
                        if finder.luna == .searching && !rows.contains(where: { $0.section == .luna }) {
                            sectionHeader(SessionFinderModel.Section.luna.title)
                            statusText("Luna is looking through your conversations…")
                        } else if finder.deepSearch == .searching {
                            if !rows.contains(where: { $0.section == .history }) {
                                sectionHeader(SessionFinderModel.Section.history.title)
                            }
                            statusText("Searching your full session history…")
                        }
                    }
                    .padding(8)
                }
                .onChange(of: finder.highlightedId) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func statusList(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(title)
            statusText(message)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(StudioStyle.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
    }

    private func sections(_ rows: [SessionFinderModel.Row]) -> [(section: SessionFinderModel.Section, rows: [SessionFinderModel.Row])] {
        var groups: [(section: SessionFinderModel.Section, rows: [SessionFinderModel.Row])] = []
        for row in rows {
            if groups.last?.section == row.section {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append((row.section, [row]))
            }
        }
        return groups
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudioStyle.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("↑↓", "Move")
            keyHint("↩", finder.highlightedIsResumable ? "Resume" : "Open")
            // Escape clears a search before it closes; the legend says which.
            Button {
                if finder.query.isEmpty { onDismiss() } else { finder.query = "" }
            } label: {
                keyHint("esc", finder.query.isEmpty ? "Close" : "Clear")
            }
            .buttonStyle(.plain)
            .help(finder.query.isEmpty ? "Close Find Session" : "Clear the search")
            Spacer(minLength: 12)
            lunaNote
        }
        .font(.caption)
        .foregroundStyle(StudioStyle.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(StudioStyle.sidebar)
    }

    private enum FooterStatus {
        case hidden
        case waitingForPause
        case suggestions(Int)
        case warning(String)
    }

    private var footerStatus: FooterStatus {
        if let error = finder.resumeError, !error.isEmpty {
            return .warning(error)
        }
        if finder.luna == .searching || finder.deepSearch == .searching {
            return .hidden
        }
        let count = finder.lunaSuggestionCount
        switch finder.luna {
        case .pending:
            return .waitingForPause
        case .searching:
            return .hidden
        case .idle:
            switch finder.deepSearch {
            case .finished:
                return .suggestions(count)
            case .failed(let message):
                return .warning(message)
            case .idle, .pending, .searching:
                return .waitingForPause
            }
        case .finished:
            if case .failed(let message) = finder.deepSearch, count == 0 {
                return .warning(message)
            }
            return .suggestions(count)
        case .failed(let message):
            if case .finished = finder.deepSearch, count > 0 {
                return .suggestions(count)
            }
            return .warning(message)
        }
    }

    @ViewBuilder
    private var lunaNote: some View {
        switch footerStatus {
        case .hidden:
            EmptyView()
        case .waitingForPause:
            Text("Luna joins when you pause typing")
                .lineLimit(1)
                .help("Meaning-based suggestions use \(LunaSessionRanker.model) through the Copilot CLI, then search your full session history.")
        case .suggestions(let count):
            Text(count == 0
                 ? "Luna found nothing more"
                 : "Luna suggested \(count) \(count == 1 ? "session" : "sessions")")
                .lineLimit(1)
        case .warning(let message):
            Label {
                Text(message).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help(message)
        }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionFinderRow: View {
    enum Target {
        case live(session: Session, projectName: String)
        case resumable(projectName: String)
    }

    let row: SessionFinderModel.Row
    let target: Target
    let isHighlighted: Bool
    let isCurrent: Bool
    let onOpen: () -> Void
    @State private var isHovering = false

    private var title: String {
        switch target {
        case .live(let session, _): return session.title
        case .resumable: return row.entry.source.title
        }
    }

    private var projectName: String {
        switch target {
        case .live(_, let projectName), .resumable(let projectName):
            return projectName
        }
    }

    private var context: String {
        var parts = [projectName]
        let folder = row.entry.folderName
        if !folder.isEmpty, folder != "/", folder != projectName { parts.append(folder) }
        switch target {
        case .live(let session, _):
            parts.append(session.attentionLabel)
            if isCurrent { parts.append("Current") }
        case .resumable:
            parts.append("Ended · Resume")
        }
        return parts.joined(separator: " · ")
    }

    private var reason: String? {
        guard let reason = row.lunaReason, !reason.isEmpty else { return nil }
        return reason
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            switch target {
            case .live(let session, _):
                SessionStateIndicator(session: session)
                    .frame(width: 18, height: 18)
            case .resumable:
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioStyle.secondaryText)
                    .frame(width: 18, height: 18)
                    .help("Ended session — press Return to resume")
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let lastActivity = row.entry.lastActivity {
                        Text(lastActivity, format: .relative(presentation: .named))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // A pick on an already-listed row stays inline so the list never shifts.
                    if row.section != .luna, row.lunaReason != nil {
                        lunaMark
                    }
                    Text(context)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                if row.section == .luna, let reason {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        lunaMark
                        Text(reason).foregroundStyle(Color.primary).lineLimit(1)
                    }
                    .font(.caption)
                } else if let snippet = row.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? StudioStyle.selection : isHovering ? StudioStyle.raised : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? StudioStyle.selectionEdge : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .help(reason.map { "\(title)\n\(row.section == .history ? "Session History" : "Suggested by Luna"): \($0)" } ?? title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
    }

    private var lunaMark: some View {
        let prefix = row.section == .history ? "Session History" : "Suggested by Luna"
        return Image(systemName: row.section == .history ? "clock.arrow.circlepath" : "sparkle")
            .foregroundStyle(StudioStyle.selectionEdge)
            .accessibilityLabel(reason.map { "\(prefix): \($0)." } ?? "\(prefix).")
    }
}
