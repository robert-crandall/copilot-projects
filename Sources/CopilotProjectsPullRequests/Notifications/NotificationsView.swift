import AppKit
import SwiftUI
import CopilotProjectsCore
import CopilotProjectsStyle

enum NotificationsWindow {
    static let id = "notifications"
    static let title = "Notifications"
    static let inboxURL = URL(string: "https://github.com/notifications")!
}

struct NotificationsView: View {
    @ObservedObject var model: NotificationsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chips
    @State private var selection: NotificationThread.Key?
    @State private var filter: NotificationsFilter = .all
    /// Cells showing every chip rather than the first few.
    @State private var expanded: Set<String> = []
    @State private var selectedInitialItem = false
    /// The user picked a thread, so a finished refresh doesn't move the selection.
    @State private var userSelected = false
    @State private var editingBanners = false
    /// Legacy scrollers take width from the lanes; rebuild them when the style changes.
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    @FocusState private var lanesFocused: Bool

    static let reasonColumnWidth: CGFloat = 240
    /// Chips a cell shows before offering the rest.
    static let cellLimit = 5

    var body: some View {
        let all = model.items
        let visible = filter.items(all)
        let layout = NotificationLayout(items: visible)
        let now = Date()
        let order = readingOrder(layout, now: now)
        VStack(spacing: 0) {
            titleStrip
            header(NotificationCounts(items: all), total: all.count)
            filterBar(visibleCount: visible.count, totalCount: all.count)
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }
            Divider()
            content(layout, order: order, now: now, hasThreads: !all.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(order)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(StudioStyle.chrome)
        .background(TitlebarSeparatorRemover())
        .onChange(of: filter) {
            selection = order.first?.id
            userSelected = true
            lanesFocused = true
        }
        .onChange(of: order.map(\.id)) { _, keys in
            // A thread that left on refresh takes the selection with it, so the
            // next Return never lands on something else.
            if let selection, !keys.contains(selection) { self.selection = nil }
        }
        .onChange(of: model.isRefreshing) { _, refreshing in
            // The first read places review requests only once their history is
            // known; until the user picks, the most urgent thread stays selected.
            guard !refreshing, selectedInitialItem, !userSelected else { return }
            selection = order.first?.id
        }
    }

    private var titleStrip: some View {
        HStack {
            Text(NotificationsWindow.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.leading, PullRequestsWindow.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: PullRequestsWindow.titleStripHeight)
        .frame(maxWidth: .infinity)
        .background(StudioStyle.chrome)
    }

    // MARK: Header

    private func header(_ counts: NotificationCounts, total: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(counts, total: total))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(subtitle(counts, total: total))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(StudioStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            bannersButton
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel("Refresh")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    func headline(_ counts: NotificationCounts, total: Int) -> String {
        if model.phase != .loaded && total == 0 { return "Notifications" }
        // Only the newest threads were read, so nothing here is not the same as nothing at all.
        if counts.needsYou == 0, !model.truncatedAccounts.isEmpty { return "Nothing needs you in the newest threads" }
        switch counts.needsYou {
        case 0: return total == 0 ? "Inbox clear" : "Nothing needs you"
        case 1: return "1 needs you"
        default: return "\(counts.needsYou.formatted()) need you"
        }
    }

    private func subtitle(_ counts: NotificationCounts, total: Int) -> String {
        if case .failed = model.phase, total == 0 { return "Nothing loaded yet" }
        if model.phase != .loaded && total == 0 { return "Reading your notifications from GitHub…" }
        var parts = [
            "\(counts.toYou.formatted()) to you",
            "\(counts.viaTeams.formatted()) via your teams",
            "\(counts.watching.formatted()) watching",
        ]
        if counts.settled > 0 { parts.append("\(counts.settled.formatted()) already merged, closed, or withdrawn") }
        if counts.answered > 0 { parts.append("\(counts.answered.formatted()) you’ve answered") }
        if counts.quiet > 0 { parts.append("\(counts.quiet.formatted()) quiet") }
        if !model.accounts.isEmpty { parts.append(model.accounts.filter { !$0.isEmpty }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var bannersButton: some View {
        let enabled = NotificationBand.allCases.filter(model.bannersEnabled(for:))
        return Button {
            editingBanners.toggle()
        } label: {
            Label(enabled.isEmpty || model.bannersAllowed == false ? "Banners Off" : "Banners",
                  systemImage: enabled.isEmpty || model.bannersAllowed == false ? "bell.slash" : "bell")
                .lineLimit(1)
        }
        .help(model.bannersAllowed == false ? "Banners are turned off for Copilot Notifications in System Settings."
              : enabled.isEmpty ? "No banners. Choose which notifications raise one."
              : "Banners for \(enabled.map { $0.title.lowercased() }.joined(separator: ", "))")
        .popover(isPresented: $editingBanners, arrowEdge: .bottom) {
            BannersEditor(model: model)
        }
    }

    private func filterBar(visibleCount: Int, totalCount: Int) -> some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(NotificationsFilter.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Its natural width, starting on the 14pt edge the headline and columns share.
            .fixedSize()
            .disabled(model.phase != .loaded)
            Text("\(visibleCount.formatted()) of \(totalCount.formatted()) threads")
                .monospacedDigit()
            clearedNote
            Spacer(minLength: 8)
            refreshStatus
            switch model.workspace {
            case .connecting:
                Text("Connecting to Copilot Projects…")
            case .disconnected:
                Text("Copilot Projects unavailable · sessions not linked")
                    .lineLimit(2)
                    .help("Open Copilot Projects to go to the sessions working on these pull requests.")
            case .connected:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(StudioStyle.secondaryText)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// Threads marked done because the user had already answered them, so
    /// nothing disappears without a trace.
    @ViewBuilder
    private var clearedNote: some View {
        let cleared = model.clearedAnswered
        if !cleared.isEmpty {
            Label {
                Text(cleared.count == 1 ? "Cleared 1 you’d answered" : "Cleared \(cleared.count.formatted()) you’d answered")
                    .monospacedDigit()
                    .lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .help(clearedHelp(cleared))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cleared \(cleared.count) notifications you’d already answered")
            .accessibilityHint(clearedHelp(cleared))
        }
    }

    private func clearedHelp(_ cleared: [NotificationThread]) -> String {
        var lines = ["Marked done on GitHub because you reviewed, replied, merged, or closed after you were last asked:"]
        lines += cleared.prefix(10).map { "• \($0.shortName): \($0.title)" }
        if cleared.count > 10 { lines.append("and \((cleared.count - 10).formatted()) more") }
        lines.append("A new mention, request, or assignment brings a thread back. GitHub’s Done view keeps the rest.")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if model.isRefreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.threads.isEmpty ? "Loading…" : "Refreshing…")
            }
            .accessibilityElement(children: .combine)
        }
        if let updated = model.lastUpdated {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("GitHub checked \(updated, format: .relative(presentation: .named))")
                    .monospacedDigit()
            }
        }
    }

    // MARK: Footer

    /// The window's keys, only those that can act right now.
    private func footer(_ order: [NotificationItem]) -> some View {
        let selected = order.first { $0.id == selection }
        let canGoToSession = selected?.session != nil && model.isConnected
        return HStack(spacing: 14) {
            if !order.isEmpty {
                keyHint("↑↓", "Move")
                if let selected {
                    keyHint("↩", canGoToSession ? "Go to Session" : "Open on GitHub")
                    if canGoToSession { keyHint("⌘↩", "Open on GitHub") }
                    keyHint("E", "Done")
                    if selected.thread.unread { keyHint("⇧I", "Mark Read") }
                    keyHint("⇧M", "Unsubscribe")
                }
            }
            keyHint("⌘R", "Refresh")
            Spacer(minLength: 12)
            if let note = model.storageNote {
                Label {
                    Text(note).lineLimit(1).truncationMode(.tail)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .help(note)
            }
            if !model.truncatedAccounts.isEmpty {
                HStack(spacing: 4) {
                    Text("Older unread threads aren’t shown ·")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Link("Open GitHub Inbox", destination: NotificationsWindow.inboxURL)
                        .foregroundStyle(.link)
                        .fixedSize()
                }
                .help("Each refresh reads the newest unread threads. Older ones stay in your inbox on GitHub.")
            }
        }
        .font(.caption)
        .foregroundStyle(StudioStyle.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(StudioStyle.sidebar)
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ layout: NotificationLayout, order: [NotificationItem], now: Date, hasThreads: Bool) -> some View {
        switch model.phase {
        case .failed(let error) where !hasThreads:
            ContentUnavailableView {
                Label(error.title, systemImage: error == .cliUnavailable ? "terminal" : "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") { model.refresh() }
            }
        case .idle, .loading where !hasThreads:
            lanes(Self.placeholderLayout, order: [], now: now, placeholder: true)
        default:
            if layout.isEmpty, hasThreads {
                ContentUnavailableView {
                    Label("No Unread Notifications", systemImage: "checkmark.circle")
                } description: {
                    Text("Everything here has been read. Mark threads done to clear them from your inbox.")
                } actions: {
                    Button("Show All") { filter = .all }
                }
            } else if layout.isEmpty {
                ContentUnavailableView {
                    Label("Inbox Clear", systemImage: "tray")
                } description: {
                    Text("Review requests, mentions, and activity on your work land here, sorted by how they reached you.")
                }
            } else {
                lanes(layout, order: order, now: now, placeholder: false)
            }
        }
    }

    private func lanes(_ layout: NotificationLayout, order: [NotificationItem], now: Date, placeholder: Bool) -> some View {
        let lookedAt = placeholder ? nil : model.columnsLookedAt
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(layout.bands) { band in
                            bandHeader(band)
                            ForEach(band.lanes) { lane in
                                laneRow(lane, lookedAt: lookedAt, now: now, placeholder: placeholder)
                                Divider()
                            }
                        }
                    } header: {
                        stageHeader(layout, lookedAt: lookedAt, now: now, placeholder: placeholder)
                    }
                }
            }
            .redacted(reason: placeholder ? .placeholder : [])
            .allowsHitTesting(!placeholder)
            .accessibilityHidden(placeholder)
            .focusable(!placeholder)
            .focused($lanesFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: order, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: order, proxy: proxy) }
            .onKeyPress(.return, phases: .down) { press in
                guard let item = order.first(where: { $0.id == selection }) else { return .ignored }
                if let session = item.session, model.isConnected, !press.modifiers.contains(.command) {
                    model.goToSession(session, for: item)
                } else {
                    model.open(item)
                }
                return .handled
            }
            .onKeyPress(characters: .letters, phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                      let item = order.first(where: { $0.id == selection }) else { return .ignored }
                switch press.characters {
                case "e":
                    markDone([item], in: order, proxy: proxy)
                case "I":
                    model.markRead([item])
                case "M":
                    advanceSelection(past: [item.id], in: order, proxy: proxy)
                    model.unsubscribe(item)
                default:
                    return .ignored
                }
                return .handled
            }
            .onKeyPress(.escape) {
                guard selection != nil else { return .ignored }
                selection = nil
                userSelected = true
                return .handled
            }
            .onAppear {
                guard !placeholder, !selectedInitialItem else { return }
                // The most urgent thread is selected, so Return acts on it at once.
                selection = order.first?.id
                selectedInitialItem = true
                lanesFocused = true
            }
            .id(scrollerStyle)
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStyle = NSScroller.preferredScrollerStyle
            }
        }
    }

    private func markDone(_ items: [NotificationItem], in order: [NotificationItem], proxy: ScrollViewProxy) {
        advanceSelection(past: Set(items.map(\.id)), in: order, proxy: proxy)
        model.markDone(items)
    }

    /// Done moves on to the next thread, so E clears a column one key at a time.
    private func advanceSelection(past keys: Set<NotificationThread.Key>, in order: [NotificationItem], proxy: ScrollViewProxy) {
        guard let selection, keys.contains(selection), let index = order.firstIndex(where: { $0.id == selection }) else { return }
        let next = order[(index + 1)...].first { !keys.contains($0.id) } ?? order[..<index].last { !keys.contains($0.id) }
        self.selection = next?.id
        userSelected = true
        if let next { proxy.scrollTo(next.id) }
    }

    private func move(_ delta: Int, in order: [NotificationItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let current = order.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : order.count)
        let next = order[min(max(current + delta, 0), order.count - 1)]
        selection = next.id
        userSelected = true
        proxy.scrollTo(next.id)
        AccessibilityNotification.Announcement(
            "\(next.thread.shortName), \(next.thread.title). \(NotificationChip.statusText(next, primaryAccount: model.primaryAccount))"
        ).post()
        return .handled
    }

    /// The chips the keyboard walks: band by band, lane by lane, column by
    /// column, only those a cell shows.
    private func readingOrder(_ layout: NotificationLayout, now: Date) -> [NotificationItem] {
        layout.lanes.flatMap { lane in
            NotificationFreshness.allCases.flatMap { column in
                shown(lane.items(in: column, lookedAt: model.columnsLookedAt, now: now), lane: lane.lane, column: column)
            }
        }
    }

    private func shown(_ items: [NotificationItem], lane: NotificationLane, column: NotificationFreshness) -> [NotificationItem] {
        expanded.contains(Self.cellID(lane, column)) ? items : Array(items.prefix(Self.cellLimit))
    }

    private static func cellID(_ lane: NotificationLane, _ column: NotificationFreshness) -> String {
        "\(lane.rawValue)-\(column.rawValue)"
    }

    private func stageHeader(_ layout: NotificationLayout, lookedAt: Date?, now: Date, placeholder: Bool) -> some View {
        HStack(spacing: 0) {
            Text("Reasons")
                .padding(.horizontal, 14)
                .frame(width: Self.reasonColumnWidth, alignment: .leading)
            ForEach(NotificationFreshness.allCases) { column in
                Divider()
                let count = layout.lanes.reduce(0) { $0 + $1.items(in: column, lookedAt: lookedAt, now: now).count }
                HStack(spacing: 6) {
                    Text(column.title)
                        .lineLimit(1)
                    if count > 0, !placeholder {
                        Text(count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(column == .sinceYouLooked ? sinceYouLookedHelp(lookedAt) : column.title)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(StudioStyle.secondaryText)
        .frame(height: 28)
        .background(StudioStyle.chrome)
        .overlay(alignment: .bottom) { Divider() }
        .unredacted()
        .accessibilityAddTraits(.isHeader)
    }

    private func sinceYouLookedHelp(_ lookedAt: Date?) -> String {
        guard let lookedAt else { return "Unread threads you haven’t seen here yet" }
        return "Unread threads that changed after you last looked, \(lookedAt.formatted(.relative(presentation: .named)))"
    }

    private func bandHeader(_ band: NotificationLayout.Band) -> some View {
        HStack(spacing: 6) {
            Text(band.band.title)
            if let count = Self.countText(needsYou: band.needsYouCount, settled: band.settledCount,
                                          unread: band.unreadCount, needsYouBand: band.band.needsYou) {
                Text(count)
                    .monospacedDigit()
                    .fontWeight(.regular)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(StudioStyle.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(StudioStyle.chrome)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func laneRow(_ lane: NotificationLayout.Lane, lookedAt: Date?, now: Date, placeholder: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            laneSummary(lane)
                .frame(width: Self.reasonColumnWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(StudioStyle.sidebar)
            ForEach(NotificationFreshness.allCases) { column in
                Divider()
                let items = lane.items(in: column, lookedAt: lookedAt, now: now)
                let visible = shown(items, lane: lane.lane, column: column)
                VStack(spacing: 6) {
                    ForEach(visible) { item in
                        chip(item, placeholder: placeholder)
                    }
                    if items.count > visible.count {
                        Button("Show \((items.count - visible.count).formatted()) more") {
                            expanded.insert(Self.cellID(lane.lane, column))
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                    } else if items.count > Self.cellLimit {
                        Button("Show fewer") { expanded.remove(Self.cellID(lane.lane, column)) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(column.title), \(lane.lane.title), \(lane.lane.band.title)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.lane.title), \(lane.lane.band.title)")
    }

    private func laneSummary(_ lane: NotificationLayout.Lane) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(lane.lane.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu {
                    Button("Mark All as Read") { model.markRead(lane.items) }
                        .disabled(lane.unreadCount == 0)
                    Button("Mark All as Done") {
                        if let selection, lane.items.contains(where: { $0.id == selection }) { self.selection = nil }
                        model.markDone(lane.items)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("\(lane.lane.title) actions")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mark every thread in \(lane.lane.title.lowercased()) read or done")
            }
            Text(lane.lane.explanation)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(laneCount(lane))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(StudioStyle.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func laneCount(_ lane: NotificationLayout.Lane) -> String {
        let threads = lane.items.count == 1 ? "1 thread" : "\(lane.items.count.formatted()) threads"
        let count = Self.countText(needsYou: lane.needsYouCount, settled: lane.settledCount,
                                   unread: lane.unreadCount, needsYouBand: lane.lane.band.needsYou)
        return [threads, count].compactMap { $0 }.joined(separator: " · ")
    }

    /// Bands and lanes count what the Dock badge counts; unread threads already
    /// merged, closed, or withdrawn are named apart, and quiet ones are only unread.
    static func countText(needsYou: Int, settled: Int, unread: Int, needsYouBand: Bool) -> String? {
        guard needsYouBand else { return unread > 0 ? "\(unread.formatted()) unread" : nil }
        var parts: [String] = []
        if needsYou > 0 { parts.append(needsYou == 1 ? "1 needs you" : "\(needsYou.formatted()) need you") }
        if settled > 0 { parts.append("\(settled.formatted()) merged, closed, or withdrawn") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func chip(_ item: NotificationItem, placeholder: Bool) -> some View {
        let chip = NotificationChip(
            item: item,
            primaryAccount: model.primaryAccount,
            isSelected: item.id == selection,
            onSelect: { selection = item.id; userSelected = true; lanesFocused = true },
            onOpen: { model.open(item) },
            onGoToSession: model.isConnected ? { session in model.goToSession(session, for: item) } : nil
        )
        .contextMenu { menu(item) }
        .id(item.id)
        if !reduceMotion && !placeholder {
            chip.matchedGeometryEffect(id: item.id, in: chips)
        } else {
            chip.transition(.opacity)
        }
    }

    @ViewBuilder
    private func menu(_ item: NotificationItem) -> some View {
        Button("Open on GitHub") { model.open(item) }
        if let session = item.session, model.isConnected {
            Button("Go to Session") { model.goToSession(session, for: item) }
        }
        Divider()
        if item.thread.unread {
            Button("Mark as Read") { model.markRead([item]) }
        }
        Button("Mark as Done") {
            if selection == item.id { selection = nil }
            model.markDone([item])
        }
        Button("Unsubscribe") {
            if selection == item.id { selection = nil }
            model.unsubscribe(item)
        }
        Divider()
        Button("Copy Link") { model.copyLink(item) }
    }

    /// Three quiet lanes under the real stage row while the first read runs.
    static let placeholderLayout: NotificationLayout = {
        let now = Date()
        func thread(_ id: Int, _ reason: String, hours: Double) -> NotificationThread {
            NotificationThread(
                key: .init(account: "placeholder", id: "\(id)"), unread: true, reason: NotificationReason(reason),
                updatedAt: now.addingTimeInterval(-hours * 3600), title: "Loading notification title text",
                kind: .pullRequest, repository: "owner/repository", subjectAPIURL: nil, number: 1000 + id
            )
        }
        let threads = [
            thread(1, "review_requested", hours: 2), thread(2, "review_requested", hours: 30),
            thread(3, "mention", hours: 5), thread(4, "team_mention", hours: 80),
        ]
        return NotificationLayout(items: threads.map { NotificationItem(thread: $0, detail: nil, detailsSettled: true) })
    }()
}

/// Which notifications raise a banner.
private struct BannersEditor: View {
    @ObservedObject var model: NotificationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Banners")
                .font(.headline)
            Text("Show a banner when an unread thread arrives that needs you. Quiet threads never do.")
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(NotificationBand.toYou.title, isOn: $model.bannersToYou)
            Toggle(NotificationBand.viaTeams.title, isOn: $model.bannersViaTeams)
            Toggle(NotificationBand.watching.title, isOn: $model.bannersWatching)
            Divider()
            Toggle("Show the count in the menu bar", isOn: $model.showsMenuBarCount)
            if model.bannersAllowed == false {
                Label {
                    Text("Banners are turned off for Copilot Notifications in System Settings.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// A notification thread inside its lane.
struct NotificationChip: View {
    let item: NotificationItem
    let primaryAccount: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    /// Present while Copilot Projects answers, so the session line can take you there.
    var onGoToSession: ((PullRequestSession) -> Void)? = nil
    @State private var isHovering = false

    private var showsAccount: Bool {
        primaryAccount.map { $0.lowercased() != item.thread.account.lowercased() } ?? false
    }

    static func statusText(_ item: NotificationItem, primaryAccount: String?) -> String {
        let showsAccount = primaryAccount.map { $0.lowercased() != item.thread.account.lowercased() } ?? false
        var parts = [item.thread.unread ? "Unread" : "Read", item.lane.title, item.lane.band.title]
        parts += item.detailParts(showsAccount: showsAccount)
        if let session = item.session { parts.append("Session \(session.title), \(session.attentionLabel)") }
        return parts.joined(separator: ", ")
    }

    /// Orange for unread threads that need you, quiet for unread CI and threads
    /// already merged, closed, or withdrawn, nothing once read. Hover only strengthens a quiet edge; selection
    /// adds its own ring outside, so the edge stays visible.
    private var edge: Color {
        if item.needsYou { return .orange.opacity(0.85) }
        if item.thread.unread { return StudioStyle.secondaryText.opacity(isHovering ? 0.8 : 0.45) }
        return isHovering && !isSelected ? StudioStyle.secondaryText.opacity(0.8) : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Narrow columns drop the age before they cut into the repository name.
            ViewThatFits(in: .horizontal) {
                identity(showsAge: true)
                identity(showsAge: false)
            }
            Text(item.thread.title)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            let parts = item.detailParts(showsAccount: showsAccount)
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let session = item.session {
                sessionLine(session)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? StudioStyle.selection : StudioStyle.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(edge, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? StudioStyle.selectionEdge : .clear, lineWidth: 1)
                .padding(-2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.thread.shortName), \(item.thread.title)")
        .accessibilityValue(Self.statusText(item, primaryAccount: primaryAccount))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Open on GitHub", onOpen)
        .accessibilityActions {
            if let session = item.session, let onGoToSession {
                Button("Go to Session") { onGoToSession(session) }
            }
        }
    }

    /// The session working on the pull request: its state, then its project when
    /// that fits whole. A click goes there while Copilot Projects answers.
    @ViewBuilder
    private func sessionLine(_ session: PullRequestSession) -> some View {
        let line = ViewThatFits(in: .horizontal) {
            sessionLabel(session, text: "\(session.attentionLabel) · \(session.projectName)")
            sessionLabel(session, text: session.attentionLabel)
        }
        .font(.caption)
        if let onGoToSession {
            Button { onGoToSession(session) } label: { line.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Go to “\(session.title)” in \(session.projectName)")
                .accessibilityHidden(true)
        } else {
            line.help("Copilot session “\(session.title)” in \(session.projectName) works on this pull request")
        }
    }

    private func sessionLabel(_ session: PullRequestSession, text: String) -> some View {
        HStack(spacing: 6) {
            if PullRequestSessionIndicator.shows(session) {
                PullRequestSessionIndicator(session: session)
                    .frame(width: 9, height: 9)
            } else {
                Image(systemName: "terminal")
                    .foregroundStyle(StudioStyle.secondaryText)
            }
            Text(text)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Unread mark, kind, `repo#number`, then how long ago it changed when that fits too.
    @ViewBuilder
    private func identity(showsAge: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if item.thread.unread {
                // Unread is a shape too, not only the edge's color.
                Circle()
                    .fill(item.needsYou ? Color.orange : StudioStyle.secondaryText)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
            }
            Image(systemName: item.thread.kind.symbol)
                .foregroundStyle(StudioStyle.secondaryText)
                .help(item.thread.kind.label)
                .accessibilityHidden(true)
            Text(item.thread.shortName)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(showsAge ? 1 : 0)
            if showsAge {
                Spacer(minLength: 4)
                Text(item.thread.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(StudioStyle.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
    }

    private var help: String {
        var lines = ["\(item.thread.repository)\(item.thread.number.map { "#\($0)" } ?? ""): \(item.thread.title)"]
        lines.append("\(item.lane.title) · \(item.lane.explanation)")
        let parts = item.detailParts(showsAccount: showsAccount)
        if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        lines.append("\(item.thread.unread ? "Unread" : "Read") · updated \(item.thread.updatedAt.formatted(.relative(presentation: .named)))")
        lines.append("Double-click to open on GitHub")
        return lines.joined(separator: "\n")
    }
}
