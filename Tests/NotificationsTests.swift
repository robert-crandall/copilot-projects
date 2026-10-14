import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsPullRequests

/// GitHub's notifications API, answered from memory.
final class FakeGitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var passes: [String: [[[String: Any]]]] = [:]
    private var _actions: [String] = []
    private var failing: Set<String> = []
    private var unchanged = false
    private var revoked: Set<String> = []

    /// Pages for one pass: `participating`, `unread`, or `read`.
    func answer(_ pass: String, pages: [[[String: Any]]]) { lock.withLock { passes[pass] = pages } }
    func fail(_ method: String) { lock.withLock { _ = failing.insert(method) } }
    func succeed() { lock.withLock { failing = [] } }
    func reportUnchanged(_ value: Bool) { lock.withLock { unchanged = value } }
    /// Answers 401 to reads made with `token`.
    func revoke(_ token: String) { lock.withLock { _ = revoked.insert(token) } }
    func restore(_ token: String) { lock.withLock { _ = revoked.remove(token) } }
    private var _bodies: [String: String] = [:]
    var bodies: [String: String] { lock.withLock { _bodies } }
    private var current: [String: [String: Any]] = [:]
    /// What `GET /notifications/threads/{id}` answers, when it differs from the listed copy.
    func setCurrent(_ thread: [String: Any]) { lock.withLock { current[thread["id"] as! String] = thread } }
    var actions: [String] { lock.withLock { _actions } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let method = request.httpMethod ?? "GET"
        func reply(_ status: Int, _ body: Data = Data("[]".utf8), headers: [String: String] = [:]) -> (Data, URLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if method != "GET" {
            return lock.withLock {
                _actions.append("\(method) \(url.path)")
                if let body = request.httpBody { _bodies["\(method) \(url.path)"] = String(decoding: body, as: UTF8.self) }
                if failing.contains(method) { return reply(500, Data(#"{"message":"boom"}"#.utf8)) }
                return reply(method == "PATCH" ? 205 : 204, Data())
            }
        }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        if lock.withLock({ revoked.contains(token) }) { return reply(401, Data(#"{"message":"Bad credentials"}"#.utf8)) }
        let modified = ["Last-Modified": "Tue, 13 Oct 2026 22:52:51 GMT"]
        if url.path.hasPrefix("/notifications/threads/") {
            let id = url.lastPathComponent
            let thread: [String: Any]? = lock.withLock {
                current[id] ?? passes.values.flatMap { $0.flatMap { $0 } }.first { $0["id"] as? String == id }
            }
            guard let thread else { return reply(404, Data(#"{"message":"Not Found"}"#.utf8)) }
            return reply(200, try JSONSerialization.data(withJSONObject: thread))
        }
        if query["per_page"] == "1" {
            let stale = lock.withLock { unchanged }
            if request.value(forHTTPHeaderField: "If-Modified-Since") != nil, stale { return reply(304, Data()) }
            return reply(200, headers: modified)
        }
        let pass = query["participating"] == "true" ? "participating" : query["all"] == "true" ? "read" : "unread"
        let page = Int(query["page"] ?? "1") ?? 1
        let pages = lock.withLock { passes[pass] ?? [] }
        let threads = page <= pages.count ? pages[page - 1] : []
        var headers = modified
        if page < pages.count {
            var next = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            next.queryItems = (next.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(page + 1)")]
            var last = next
            last.queryItems = (last.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(pages.count)")]
            headers["Link"] = "<\(next.url!.absoluteString)>; rel=\"next\", <\(last.url!.absoluteString)>; rel=\"last\""
        }
        return reply(200, try JSONSerialization.data(withJSONObject: threads), headers: headers)
    }

    static func thread(
        _ id: String, reason: String, type: String = "PullRequest", repo: String = "octo/app", number: Int? = 1,
        unread: Bool = true, updated: Date, title: String = "A thread"
    ) -> [String: Any] {
        let collection = type == "Issue" ? "issues" : "pulls"
        var subject: [String: Any] = ["title": title, "type": type]
        subject["url"] = number.map { "https://api.github.com/repos/\(repo)/\(collection)/\($0)" } ?? NSNull()
        return [
            "id": id, "unread": unread, "reason": reason,
            "updated_at": ISO8601DateFormatter().string(from: updated),
            "subject": subject, "repository": ["full_name": repo],
        ]
    }
}

@MainActor
final class FakeBanners: NotificationBannerPosting {
    var posted: [[NotificationBanner]] = []
    func post(_ banners: [NotificationBanner]) { posted.append(banners) }
}

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class NotificationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_900_000)

    private func thread(
        _ id: String, _ reason: String, kind: NotificationSubjectKind = .pullRequest, unread: Bool = true,
        minutesAgo: Double = 10, account: String = "octocat", repo: String = "octo/app", number: Int? = 1
    ) -> NotificationThread {
        NotificationThread(
            key: .init(account: account, id: id), unread: unread, reason: NotificationReason(reason),
            updatedAt: now.addingTimeInterval(-minutesAgo * 60), title: "Thread \(id)", kind: kind,
            repository: repo, subjectAPIURL: number.map { URL(string: "https://api.github.com/repos/\(repo)/pulls/\($0)")! },
            number: number
        )
    }

    private func makeModel(
        _ github: FakeGitHub, clock: TestClock, defaults: UserDefaults? = nil,
        workspace: PullRequestsWorkspace = FakeWorkspace(), opened: ((URL) -> Void)? = nil,
        plan: NotificationsFetchPlan = NotificationsFetchPlan()
    ) -> NotificationsModel {
        let model = NotificationsModel(
            workspace: workspace, defaults: defaults ?? UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send), plan: plan,
            // Nothing listens there: details fail fast without leaving the machine.
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "token")] },
            transcriptPath: { _ in nil },
            clock: { clock.now },
            openURL: opened ?? { _ in },
            isVisible: { false }
        )
        model.setBadge = { _ in }
        return model
    }

    // MARK: Decoding

    func testDecodesThreadsAndTheNextPage() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            FakeGitHub.thread("1", reason: "review_requested", repo: "Octo/App", number: 42, updated: now, title: "Add lanes"),
            FakeGitHub.thread("2", reason: "ci_activity", type: "CheckSuite", number: nil, unread: false, updated: now),
        ])
        let threads = try GitHubNotificationsAPI.decode(json, account: "octocat")
        XCTAssertEqual(threads.map(\.key.id), ["1", "2"])
        XCTAssertEqual(threads[0].reason, .reviewRequested)
        XCTAssertEqual(threads[0].pullRequestKey?.description, "octo/app#42")
        XCTAssertEqual(threads[0].shortName, "App#42")
        XCTAssertEqual(threads[0].webURL.absoluteString, "https://github.com/Octo/App/pull/42")
        XCTAssertEqual(threads[1].kind, .checkSuite)
        XCTAssertNil(threads[1].number)
        XCTAssertEqual(threads[1].webURL.absoluteString, "https://github.com/octo/app/actions")
        XCTAssertFalse(threads[1].unread)

        XCTAssertEqual(
            GitHubNotificationsAPI.nextLink(#"<https://api.github.com/notifications?page=2>; rel="next", <https://api.github.com/notifications?page=9>; rel="last""#)?.absoluteString,
            "https://api.github.com/notifications?page=2"
        )
        XCTAssertNil(GitHubNotificationsAPI.nextLink(#"<https://api.github.com/notifications?page=9>; rel="last""#))
    }

    func testWebURLsForEachSubject() {
        func web(_ path: String?, _ kind: NotificationSubjectKind) -> String {
            NotificationThread.webURL(apiURL: path.map { URL(string: "https://api.github.com\($0)")! }, repository: "o/r", kind: kind).absoluteString
        }
        XCTAssertEqual(web("/repos/o/r/issues/7", .issue), "https://github.com/o/r/issues/7")
        XCTAssertEqual(web("/repos/o/r/commits/abc123", .commit), "https://github.com/o/r/commit/abc123")
        XCTAssertEqual(web("/repos/o/r/releases/991", .release), "https://github.com/o/r/releases")
        XCTAssertEqual(web(nil, .discussion), "https://github.com/o/r/discussions")
        XCTAssertEqual(web(nil, .securityAlert), "https://github.com/o/r/security")
        XCTAssertEqual(NotificationThread.number(apiURL: URL(string: "https://api.github.com/repos/o/r/issues/12")), 12)
        XCTAssertNil(NotificationThread.number(apiURL: URL(string: "https://api.github.com/repos/o/r/releases/12")))
    }

    // MARK: Lanes

    func testReviewRequestsAreYoursUntilHistoryShowsOnlyATeam() {
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: nil), .reviewRequested)
        var direct = NotificationSubjectDetail()
        direct.viewerRequested = true
        direct.requestedTeams = ["octo/reviewers"]
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: direct), .reviewRequested)
        var team = NotificationSubjectDetail()
        team.requestedTeams = ["octo/reviewers", "octo/owners"]
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: team), .teamReviewRequested)
        // No request in the history at all stays with the user.
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: NotificationSubjectDetail()), .reviewRequested)

        let unknown = NotificationItem(thread: thread("1", "review_requested"), detail: nil, detailsSettled: false)
        XCTAssertTrue(unknown.isClassifying)
        XCTAssertEqual(unknown.detailParts(showsAccount: false), ["Checking who was asked…"])
        let unanswered = NotificationItem(thread: thread("1", "review_requested"), detail: nil, detailsSettled: true)
        XCTAssertFalse(unanswered.isClassifying)
        XCTAssertEqual(unanswered.detailParts(showsAccount: false), ["Couldn’t check who was asked"])

        team.viewerTeam = "octo/owners"
        team.state = .merged
        let item = NotificationItem(thread: thread("2", "review_requested", account: "hubot"), detail: team, detailsSettled: true)
        XCTAssertEqual(item.lane.band, .viaTeams)
        XCTAssertEqual(item.detailParts(showsAccount: true), ["@octo/owners", "Merged", "as hubot"])
    }

    func testOnlyReviewRequestsSettleWhenTheirPullRequestCloses() {
        var merged = NotificationSubjectDetail()
        merged.state = .merged
        let mention = NotificationItem(thread: thread("m", "mention"), detail: merged, detailsSettled: true)
        XCTAssertTrue(mention.needsYou, "a new mention on a merged pull request can still need an answer")
        let assigned = NotificationItem(thread: thread("a", "assign", kind: .issue), detail: merged, detailsSettled: true)
        XCTAssertTrue(assigned.needsYou)
        let review = NotificationItem(thread: thread("r", "review_requested"), detail: merged, detailsSettled: true)
        XCTAssertFalse(review.needsYou)
    }

    func testAnIncompleteRequestHistoryIsNotProofOfATeamRequest() throws {
        let json = """
        {"state":"OPEN","timelineItems":{"pageInfo":{"hasPreviousPage":true},"nodes":[
          {"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}}
        ]}}
        """
        let subject = try JSONDecoder().decode(NotificationDetailsFetcher.Subject.self, from: Data(json.utf8))
        let detail = NotificationDetailsFetcher.detail(subject, viewer: "octocat")
        XCTAssertFalse(detail.requestHistoryComplete)
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: detail), .reviewRequested,
                       "a direct request may be among the older events")
        let complete = try JSONDecoder().decode(
            NotificationDetailsFetcher.Subject.self, from: Data(json.replacingOccurrences(of: "true", with: "false").utf8)
        )
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: NotificationDetailsFetcher.detail(complete, viewer: "octocat")),
                       .teamReviewRequested)
    }

    func testEveryReasonHasALaneAndBand() {
        let expected: [(String, NotificationLane, NotificationBand)] = [
            ("mention", .mentioned, .toYou), ("assign", .assigned, .toYou), ("author", .yourWork, .toYou),
            ("comment", .conversations, .toYou), ("state_change", .conversations, .toYou),
            ("approval_requested", .reviewRequested, .toYou), ("team_mention", .teamMentioned, .viaTeams),
            ("subscribed", .watchedRepositories, .watching), ("manual", .subscribedThreads, .watching),
            ("ci_activity", .ciActivity, .quiet), ("security_alert", .other, .quiet), ("something_new", .other, .quiet),
        ]
        for (reason, lane, band) in expected {
            let result = NotificationItem.lane(for: NotificationReason(reason), detail: nil)
            XCTAssertEqual(result, lane, reason)
            XCTAssertEqual(result.band, band, reason)
        }
    }

    func testFreshnessIsMeasuredFromTheLastLook() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
        let looked = noon.addingTimeInterval(-3600)
        func column(_ hoursAgo: Double, unread: Bool, looked: Date? = looked) -> NotificationFreshness {
            .of(updatedAt: noon.addingTimeInterval(-hoursAgo * 3600), unread: unread, lookedAt: looked, now: noon, calendar: calendar)
        }
        XCTAssertEqual(column(0.5, unread: true), .sinceYouLooked)
        XCTAssertEqual(column(0.5, unread: false), .today, "read since the look is no longer new")
        XCTAssertEqual(column(2, unread: true), .today, "unread but already seen")
        XCTAssertEqual(column(14, unread: true), .thisWeek, "yesterday")
        XCTAssertEqual(column(6 * 24, unread: false), .thisWeek)
        XCTAssertEqual(column(8 * 24, unread: true), .older)
        XCTAssertEqual(column(8 * 24, unread: true, looked: nil), .sinceYouLooked, "never looked: every unread thread is new")
    }

    func testLayoutKeepsBandOrderAndLeadsWithUnread() {
        let items = [
            thread("ci", "ci_activity", kind: .checkSuite, minutesAgo: 1),
            thread("old", "mention", unread: false, minutesAgo: 1),
            thread("new", "mention", minutesAgo: 30),
            thread("team", "team_mention"),
            thread("watch", "subscribed"),
        ].map { NotificationItem(thread: $0, detail: nil, detailsSettled: true) }
        let layout = NotificationLayout(items: items)
        XCTAssertEqual(layout.bands.map(\.band), [.toYou, .viaTeams, .watching, .quiet])
        XCTAssertEqual(layout.bands[0].lanes[0].items.map(\.thread.key.id), ["new", "old"])
        let counts = NotificationCounts(items: items)
        XCTAssertEqual([counts.toYou, counts.viaTeams, counts.watching, counts.quiet, counts.needsYou], [1, 1, 1, 1, 3])
        XCTAssertEqual(counts.badgeLabel, "3")
        var many = counts
        many.toYou = 2_000
        XCTAssertEqual(many.badgeLabel, "999+")
        XCTAssertNil(NotificationCounts(items: []).badgeLabel)

        var merged = NotificationSubjectDetail()
        merged.state = .merged
        var draft = NotificationSubjectDetail()
        draft.state = .draft
        let review = [
            NotificationItem(thread: thread("m", "review_requested"), detail: merged, detailsSettled: true),
            NotificationItem(thread: thread("d", "review_requested"), detail: draft, detailsSettled: true),
        ]
        XCTAssertFalse(review[0].needsYou, "a merged pull request has nothing left to review")
        XCTAssertTrue(review[1].needsYou)
        let settled = NotificationCounts(items: review)
        XCTAssertEqual([settled.toYou, settled.settled, settled.needsYou], [1, 1, 1])
    }

    // MARK: Details

    func testDetailsReadDirectAndTeamRequestsFromHistory() throws {
        let json = """
        {"state":"OPEN","isDraft":true,"headRefName":"octo/lanes","timelineItems":{"nodes":[
          {"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}},
          {"requestedReviewer":{"__typename":"User","login":"OctoCat"}},
          {"requestedReviewer":{"__typename":"Team","slug":"owners","organization":{"login":"octo"}}},
          {"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}},
          {}
        ]}}
        """
        let subject = try JSONDecoder().decode(NotificationDetailsFetcher.Subject.self, from: Data(json.utf8))
        let detail = NotificationDetailsFetcher.detail(subject, viewer: "octocat")
        XCTAssertEqual(detail.state, .draft)
        XCTAssertEqual(detail.headRefName, "octo/lanes")
        XCTAssertTrue(detail.viewerRequested)
        XCTAssertEqual(detail.requestedTeams, ["octo/reviewers", "octo/owners"], "most recent first, once each")

        let teamOnly = NotificationDetailsFetcher.detail(subject, viewer: "someone-else")
        XCTAssertFalse(teamOnly.viewerRequested)

        let issue = try JSONDecoder().decode(
            NotificationDetailsFetcher.Subject.self, from: Data(#"{"state":"CLOSED","stateReason":"NOT_PLANNED"}"#.utf8)
        )
        XCTAssertEqual(NotificationDetailsFetcher.detail(issue, viewer: nil).state, .notPlanned)
    }

    // MARK: Fetching

    func testFetchPlanMergesPassesAndReportsWhatItLeftOut() async throws {
        let github = FakeGitHub()
        let shared = FakeGitHub.thread("1", reason: "mention", updated: now.addingTimeInterval(-600))
        let newer = FakeGitHub.thread("1", reason: "mention", updated: now)
        github.answer("participating", pages: [[shared]])
        github.answer("unread", pages: [[newer], [FakeGitHub.thread("2", reason: "ci_activity", updated: now)], [FakeGitHub.thread("3", reason: "ci_activity", updated: now)]])
        github.answer("read", pages: [[FakeGitHub.thread("4", reason: "author", unread: false, updated: now)]])
        var plan = NotificationsFetchPlan()
        plan.unreadPages = 2
        let result = try await plan.fetch(
            account: GitHubAccount(login: "octocat", token: "t"), api: GitHubNotificationsAPI(send: github.send), now: now
        )
        XCTAssertEqual(Set(result.threads.map(\.key.id)), ["1", "2", "4"])
        XCTAssertEqual(result.threads.first { $0.key.id == "1" }?.updatedAt, now, "the newest copy wins")
        XCTAssertTrue(result.truncated)
    }

    func testPageLinksOffTheAPIAreNotFollowedWithTheToken() async {
        final class Sent: @unchecked Sendable {
            var urls: [URL] = []
        }
        let sent = Sent()
        let api = GitHubNotificationsAPI(send: { request in
            sent.urls.append(request.url!)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let account = GitHubAccount(login: "octocat", token: "secret")
        for link in ["https://evil.example/notifications?page=2", "http://api.github.com/notifications?page=2",
                     "https://api.github.com:8443/notifications?page=2"] {
            do {
                _ = try await api.list(account: account, url: URL(string: link)!)
                XCTFail("followed \(link)")
            } catch {}
        }
        XCTAssertTrue(sent.urls.isEmpty, "\(sent.urls)")
        _ = try? await api.list(account: account, url: URL(string: "https://API.github.com/notifications?page=2")!)
        XCTAssertEqual(sent.urls.count, 1, "the API's own links are still followed")
    }

    func testRefreshShowsThreadsAndPublishesCounts() async {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now),
            FakeGitHub.thread("2", reason: "team_mention", type: "Issue", number: 2, updated: now),
        ]])
        github.answer("unread", pages: [[FakeGitHub.thread("3", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now)]])
        let summary = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: summary) }
        let clock = TestClock(now)
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            summaryURL: summary, api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "t")] }, transcriptPath: { _ in nil }, clock: { clock.now }
        )
        var badge: String?
        model.setBadge = { badge = $0 }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.threads.count, 3)
        XCTAssertEqual(badge, "2", "CI never counts")
        let written = NotificationsSummary.read(from: summary)
        XCTAssertEqual(written?.needsYou, 2)
        XCTAssertEqual(written?.toYou, 1)
        XCTAssertEqual(written?.viaTeams, 1)
    }

    func testFailureBeforeAnythingLoadedIsShownAndLaterOnesAreWarnings() async {
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            loadAccounts: { throw NotificationsFetchError.notSignedIn }, transcriptPath: { _ in nil }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .failed(.notSignedIn))
    }

    // MARK: Actions

    func testOpeningMarksReadAndDoneRemovesUntilSomethingNewHappens() async throws {
        let github = FakeGitHub()
        let first = FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)
        github.answer("participating", pages: [[first, FakeGitHub.thread("2", reason: "author", type: "Issue", number: 2, updated: now)]])
        let clock = TestClock(now)
        var opened: [URL] = []
        let model = makeModel(github, clock: clock, opened: { opened.append($0) })
        await model.refreshNow()
        let item = try XCTUnwrap(model.items.first { $0.id.id == "1" })
        model.open(item)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/octo/app/issues/1"])
        XCTAssertEqual(model.threads.first { $0.key.id == "1" }?.unread, false, "read at once, before GitHub answers")

        model.markDone([try XCTUnwrap(model.items.first { $0.id.id == "2" })])
        XCTAssertFalse(model.threads.contains { $0.key.id == "2" })
        try await waitUntil { github.actions.count == 2 }
        XCTAssertEqual(Set(github.actions), ["PATCH /notifications/threads/1", "DELETE /notifications/threads/2"])

        // A refresh that read GitHub before it saw either change keeps both.
        await model.refreshNow()
        XCTAssertEqual(model.threads.first { $0.key.id == "1" }?.unread, false)
        XCTAssertFalse(model.threads.contains { $0.key.id == "2" })

        // New activity brings a done thread back, unread.
        github.answer("participating", pages: [[first, FakeGitHub.thread("2", reason: "author", type: "Issue", number: 2, updated: now.addingTimeInterval(60))]])
        await model.refreshNow()
        XCTAssertEqual(model.threads.first { $0.key.id == "2" }?.unread, true)
    }

    func testAFailedDoneComesBackWithAWarning() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        github.fail("DELETE")
        model.markDone(model.items)
        XCTAssertTrue(model.threads.isEmpty)
        try await waitUntil { !model.threads.isEmpty }
        XCTAssertTrue(model.warning?.contains("Couldn’t mark as done") == true, model.warning ?? "no warning")
    }

    func testReadCoversACopyDatedAheadOfThisClock() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(120))]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        model.markRead(model.items)
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/1") }
        // A refresh that read GitHub before it saw the read keeps it read.
        await model.refreshNow()
        XCTAssertEqual(model.threads.first?.unread, false)
    }

    func testDoneCoversActivityUpToTheClickNotJustTheCopyOnScreen() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-600))]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        // Activity the window hasn't shown yet arrives before the click.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-300))]])
        model.markDone(model.items)
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        await model.refreshNow()
        XCTAssertTrue(model.threads.isEmpty, "the done covered it")

        // A copy dated ahead of this clock stays done too.
        github.answer("participating", pages: [[FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(120))]])
        await model.refreshNow()
        model.markDone(model.items)
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/2") }
        await model.refreshNow()
        XCTAssertTrue(model.threads.isEmpty)

        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(60))]])
        await model.refreshNow()
        XCTAssertEqual(model.threads.map(\.key.id), ["1"], "activity after the click brings it back")
    }

    func testOneRevokedAccountDoesNotBlockActingForTheOthers() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)]])
        github.revoke("stale")
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "stale")] },
            transcriptPath: { _ in nil }, clock: { self.now }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.warning?.contains("hubot") == true, model.warning ?? "no warning")
        let item = try XCTUnwrap(model.items.first { $0.thread.account == "octocat" })
        model.markDone([item])
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.threads.contains { $0.key == item.id }, "the healthy account's done stuck")
        XCTAssertFalse(model.warning?.contains("no longer signed in") == true)
    }

    // MARK: Looking and banners

    func testColumnsCatchUpWithTheLastLookWhenTheUserComesBack() {
        let clock = TestClock(now)
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let model = makeModel(FakeGitHub(), clock: clock, defaults: defaults)
        XCTAssertNil(model.lookedAt)
        model.beganLooking()
        clock.now += 5
        model.finishedLooking()
        XCTAssertNil(model.lookedAt, "staring at the loading placeholder isn't a look")

        model.show([thread("1", "mention")], accounts: ["octocat"])
        model.beganLooking()
        clock.now += 1
        model.finishedLooking()
        XCTAssertNil(model.lookedAt, "a glance isn't a look")

        model.beganLooking()
        clock.now += 5
        model.beganLooking()
        XCTAssertNil(model.lookedAt, "coming back from the window's own popover continues the look")
        clock.now += 5
        model.finishedLooking()
        XCTAssertEqual(model.lookedAt, clock.now)
        XCTAssertNil(model.columnsLookedAt, "columns hold still while the user is away")
        model.beganLooking()
        XCTAssertEqual(model.columnsLookedAt, clock.now)
        XCTAssertEqual(defaults.double(forKey: NotificationsModel.lookedAtKey), clock.now.timeIntervalSince1970)
    }

    func testTheFirstLookStartsFromTheLastReadOnGitHub() async {
        let github = FakeGitHub()
        var read = FakeGitHub.thread("1", reason: "author", type: "Issue", unread: false, updated: now.addingTimeInterval(-7200))
        read["last_read_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        github.answer("participating", pages: [[
            FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-1800)),
            FakeGitHub.thread("3", reason: "mention", type: "Issue", number: 3, updated: now.addingTimeInterval(-5400)),
        ]])
        github.answer("read", pages: [[read]])
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let model = makeModel(github, clock: TestClock(now), defaults: defaults)
        await model.refreshNow()
        let lastRead = now.addingTimeInterval(-3600)
        XCTAssertEqual(model.lookedAt, lastRead)
        XCTAssertEqual(model.columnsLookedAt, lastRead)
        XCTAssertEqual(defaults.double(forKey: NotificationsModel.lookedAtKey), lastRead.timeIntervalSince1970)
        let columns = Dictionary(uniqueKeysWithValues: model.items.map {
            ($0.id.id, NotificationFreshness.of(updatedAt: $0.thread.updatedAt, unread: $0.thread.unread, lookedAt: model.columnsLookedAt, now: now))
        })
        XCTAssertEqual(columns["2"], .sinceYouLooked)
        XCTAssertNotEqual(columns["3"], .sinceYouLooked, "unread before the last read on GitHub was already there to see")

        // A real look is never replaced by the seed.
        model.beganLooking()
        await model.refreshNow()
        XCTAssertEqual(model.lookedAt, lastRead)
    }

    func testBannersAnnounceOnlyNewThreadsThatNeedYou() async {
        let github = FakeGitHub()
        let clock = TestClock(now)
        github.answer("participating", pages: [[FakeGitHub.thread("old", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-60))]])
        let model = makeModel(github, clock: clock)
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()
        XCTAssertTrue(banners.posted.isEmpty, "the backlog waiting at first launch isn't announced")

        clock.now += 120
        github.answer("participating", pages: [[
            FakeGitHub.thread("old", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("new", reason: "mention", type: "Issue", number: 5, updated: now.addingTimeInterval(60), title: "Composer loses focus"),
        ]])
        github.answer("unread", pages: [[FakeGitHub.thread("ci", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now.addingTimeInterval(60))]])
        await model.refreshNow()
        XCTAssertEqual(banners.posted.count, 1)
        XCTAssertEqual(banners.posted[0].map(\.title), ["You were mentioned"])
        XCTAssertEqual(banners.posted[0].first?.subtitle, "app#5")
        XCTAssertEqual(banners.posted[0].first?.body, "Composer loses focus")

        await model.refreshNow()
        XCTAssertEqual(banners.posted.count, 1, "each change is announced once")

        model.bannersToYou = false
        clock.now += 120
        github.answer("participating", pages: [[FakeGitHub.thread("later", reason: "mention", type: "Issue", updated: now.addingTimeInterval(200))]])
        await model.refreshNow()
        XCTAssertEqual(banners.posted.count, 1, "To you banners are off")
    }

    func testOneAccountsFailedRefreshDoesNotLoseItsBanners() async {
        let github = FakeGitHub()
        let clock = TestClock(now)
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "flaky")] },
            transcriptPath: { _ in nil }, clock: { clock.now }
        )
        model.setBadge = { _ in }
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()

        // hubot fails while octocat reads a newer thread; then hubot recovers
        // with an older mention that arrived while it was failing.
        clock.now += 300
        github.revoke("flaky")
        github.answer("unread", pages: [[FakeGitHub.thread("ci", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now.addingTimeInterval(200))]])
        await model.refreshNow()
        github.restore("flaky")
        github.answer("unread", pages: [])
        github.answer("participating", pages: [[FakeGitHub.thread("m", reason: "mention", type: "Issue", updated: now.addingTimeInterval(100))]])
        clock.now += 300
        await model.refreshNow()
        let titles = banners.posted.flatMap { $0 }.map(\.title)
        XCTAssertTrue(titles.contains("You were mentioned"), "\(titles)")
    }

    func testOneAccountsFailedRefreshKeepsItsTruncationCaveat() async {
        let github = FakeGitHub()
        let ci: (String) -> [[String: Any]] = { [now] id in
            [FakeGitHub.thread(id, reason: "ci_activity", type: "CheckSuite", number: nil, updated: now)]
        }
        github.answer("unread", pages: [ci("1"), ci("2")])
        var plan = NotificationsFetchPlan()
        plan.unreadPages = 1
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send), plan: plan,
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "flaky")] },
            transcriptPath: { _ in nil }, clock: { self.now }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.truncatedAccounts, ["octocat", "hubot"])

        // hubot fails while octocat's inbox now fits in what one refresh reads.
        github.revoke("flaky")
        github.answer("unread", pages: [ci("1")])
        await model.refreshNow()
        XCTAssertEqual(model.truncatedAccounts, ["hubot"], "hubot's older threads are still unseen")

        github.restore("flaky")
        await model.refreshNow()
        XCTAssertTrue(model.truncatedAccounts.isEmpty)
    }

    func testGoingToTheLinkedSessionMarksTheThreadRead() async throws {
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Ship lanes", status: .waiting, pullRequestKeys: ["octo/app#1"]),
            ]),
        ])
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "author", updated: now)]])
        let model = makeModel(github, clock: TestClock(now), workspace: FakeWorkspace(snapshot: snapshot))
        await model.pollWorkspace()
        await model.refreshNow()
        let item = try XCTUnwrap(model.items.first)
        let session = try XCTUnwrap(item.session)
        model.goToSession(session, for: item)
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/1") }
        XCTAssertEqual(model.threads.first?.unread, false)
    }

    func testGoingToASessionThatMovedProjectsShowsItWhereItIsNow() async throws {
        func snapshot(in project: String) -> WorkspaceSnapshot {
            WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: project, projects: [
                .init(id: project, name: "Workspace", sessions: [
                    .init(id: "s1", title: "Ship lanes", status: .waiting, pullRequestKeys: ["octo/app#1"]),
                ]),
            ])
        }
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "author", updated: now)]])
        let workspace = FakeWorkspace(snapshot: snapshot(in: "p"))
        let model = makeModel(github, clock: TestClock(now), workspace: workspace)
        await model.pollWorkspace()
        await model.refreshNow()
        let item = try XCTUnwrap(model.items.first)
        let session = try XCTUnwrap(item.session)
        workspace.answer(
            fetches: [.snapshot(snapshot(in: "q"))],
            reveals: [.refused(code: "conflict", message: "moved"), .done(code: "revealed", text: nil)]
        )
        model.goToSession(session, for: item)
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/1") }
        XCTAssertEqual(workspace.revealCalls.map(\.projectId), ["p", "q"])
        XCTAssertEqual(model.threads.first?.unread, false)
    }

    func testAStaleSessionMatchDoesNotOverwriteANewerOne() async throws {
        actor HeldTranscripts: PullRequestTranscriptReading {
            private var first: CheckedContinuation<Void, Never>?
            private var holding = true
            private(set) var reads = 0
            func evidence(
                for sources: [PullRequestTranscriptIndex.Source], branches: Set<String>
            ) async -> [String: TranscriptEvidence] {
                reads += 1
                if reads == 1, holding { await withCheckedContinuation { first = $0 } }
                return [:]
            }
            func release() {
                holding = false
                first?.resume()
                first = nil
            }
        }
        func snapshot(linking session: String) -> WorkspaceSnapshot {
            WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
                .init(id: "p", name: "Workspace", sessions: ["s1", "s2"].map {
                    .init(id: $0, title: $0, status: .waiting, copilotSessionId: "copilot-\($0)",
                          pullRequestKeys: $0 == session ? ["octo/app#1"] : [])
                }),
            ])
        }
        let transcripts = HeldTranscripts()
        let workspace = FakeWorkspace(snapshot: snapshot(linking: "s1"))
        let model = NotificationsModel(
            workspace: workspace, defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            loadAccounts: { [] }, transcripts: transcripts, transcriptPath: { "/nonexistent/\($0).jsonl" }
        )
        model.setBadge = { _ in }
        model.show([thread("1", "author")], accounts: ["octocat"])
        let stale = Task { await model.pollWorkspace() }
        var reads = 0
        for _ in 0..<250 where reads == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            reads = await transcripts.reads
        }
        XCTAssertEqual(reads, 1)

        // The session working on it changes while the first match reads transcripts.
        workspace.answer(fetches: [.snapshot(snapshot(linking: "s2"))])
        await model.pollWorkspace()
        XCTAssertEqual(model.links[PullRequestKey("octo/app#1")!], "s2")
        await transcripts.release()
        await stale.value
        XCTAssertEqual(model.links[PullRequestKey("octo/app#1")!], "s2", "the older match's links were dropped")
    }

    func testABannerForAThreadNotLoadedStillMarksItRead() async throws {
        let github = FakeGitHub()
        var opened: [URL] = []
        let model = makeModel(github, clock: TestClock(now), opened: { opened.append($0) })
        let url = URL(string: "https://github.com/octo/app/issues/9")!
        model.openBanner(thread: .init(account: "octocat", id: "99"), url: url)
        XCTAssertEqual(opened, [url])
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/99") }
    }

    func testUnsubscribeIgnoresTheThreadAndClearsIt() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "subscribed", type: "Issue", updated: now)]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        model.unsubscribe(try XCTUnwrap(model.items.first))
        try await waitUntil { github.actions.count == 2 }
        XCTAssertEqual(github.actions, ["PUT /notifications/threads/1/subscription", "DELETE /notifications/threads/1"])
        XCTAssertEqual(github.bodies["PUT /notifications/threads/1/subscription"], #"{"ignored":true}"#)
    }

    func testManyNewThreadsBecomeOneSummaryBanner() {
        let items = (0..<5).map { index in
            NotificationItem(thread: thread("\(index)", index < 2 ? "mention" : "team_mention"), detail: nil, detailsSettled: true)
        }
        let banners = NotificationsModel.banners(for: items)
        XCTAssertEqual(banners.count, 1)
        XCTAssertEqual(banners[0].title, "5 new notifications need you")
        XCTAssertEqual(banners[0].body, "2 to you · 3 via your teams")
        XCTAssertNil(banners[0].url)

        var team = NotificationSubjectDetail()
        team.requestedTeams = ["octo/reviewers"]
        let request = NotificationItem(thread: thread("r", "review_requested"), detail: team, detailsSettled: true)
        XCTAssertEqual(NotificationsModel.banner(request).title, "@octo/reviewers was asked to review")
    }

    // MARK: Sessions

    func testPullRequestThreadsLinkToTheSessionWorkingOnThem() async {
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Ship lanes", status: .waiting, pullRequestKeys: ["octo/app#7"]),
            ]),
        ])
        let model = makeModel(FakeGitHub(), clock: TestClock(now), workspace: FakeWorkspace(snapshot: snapshot))
        model.show([thread("1", "author", number: 7), thread("2", "author", number: 8)], accounts: ["octocat"])
        await model.pollWorkspace()
        await model.matchSessions()
        XCTAssertEqual(model.items.first { $0.id.id == "1" }?.session?.id, "s1")
        XCTAssertNil(model.items.first { $0.id.id == "2" }?.session)
    }

    // MARK: Answered

    /// A pull request's history as GitHub returns it to the Engaged fragment.
    private func subject(
        _ events: String, reviews: String = "", body: String? = nil, activityTruncated: Bool = false
    ) throws -> NotificationDetailsFetcher.Subject {
        var json = #"{"state":"OPEN","createdAt":"2026-10-14T09:00:00Z","author":{"login":"author"},"#
        if let body { json += #""body":"\#(body)","# }
        json += #""prActivity":{"pageInfo":{"hasPreviousPage":\#(activityTruncated)},"nodes":["# + events + "]},"
        json += #""reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":["# + reviews + "]}}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NotificationDetailsFetcher.Subject.self, from: Data(json.utf8))
    }

    private func answered(_ subject: NotificationDetailsFetcher.Subject, onTeam: (String) -> Bool? = { _ in nil }) -> Bool {
        NotificationDetailsFetcher.detail(subject, viewer: "octocat").isAnswered(onTeam: onTeam)
    }

    func testAThreadIsAnsweredWhenYouActedAfterTheLastAskOfYou() throws {
        // entitlements#143685: asked and mentioned, then approved; others approving later don't ask again.
        let asked = try subject("""
        {"__typename":"ReviewRequestedEvent","createdAt":"2026-10-14T16:47:22Z","requestedReviewer":{"__typename":"User","login":"OctoCat"}},
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T16:47:30Z","actor":{"login":"octocat"}},
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T16:47:31Z","actor":{"login":"hubot"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T19:05:04Z","body":"LGTM, thanks @hubot","author":{"login":"hubot"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T17:16:46Z","state":"APPROVED","author":{"login":"octocat"}},
        {"submittedAt":"2026-10-14T19:04:43Z","state":"APPROVED","body":"","author":{"login":"hubot"}}
        """)
        let detail = NotificationDetailsFetcher.detail(asked, viewer: "octocat")
        XCTAssertNotNil(detail.viewerTargetedAt)
        XCTAssertNotNil(detail.viewerActedAt)
        XCTAssertTrue(detail.isAnswered { _ in nil })

        XCTAssertFalse(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T16:47:30Z","actor":{"login":"octocat"}},
        {"__typename":"ReviewRequestedEvent","createdAt":"2026-10-14T18:00:00Z","requestedReviewer":{"__typename":"User","login":"octocat"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T17:16:46Z","state":"APPROVED","author":{"login":"octocat"}}
        """)), "re-requested")

        XCTAssertTrue(answered(try subject("""
        {"__typename":"AssignedEvent","createdAt":"2026-10-14T10:00:00Z","assignee":{"login":"octocat"}},
        {"__typename":"ClosedEvent","createdAt":"2026-10-14T11:00:00Z","actor":{"login":"octocat"}}
        """)), "closed after being assigned")

        XCTAssertFalse(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"PENDING","author":{"login":"octocat"}}
        """)), "a draft review isn't an answer")

        XCTAssertFalse(answered(try subject("""
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"on it","author":{"login":"octocat"}}
        """)), "with nothing aimed at you in the history, it can't be called answered")
    }

    func testAMentionInsideAReviewOrReviewCommentAsksAgain() throws {
        // GitHub records no mention event for these, so the text is what counts.
        let before = """
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"Looking now","author":{"login":"octocat"}}
        """
        XCTAssertTrue(answered(try subject(before)))
        XCTAssertFalse(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"COMMENTED","body":"@OctoCat fixed in the latest push, PTAL","author":{"login":"hubot"}}
        """)), "mentioned in a review body")
        XCTAssertFalse(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"COMMENTED","body":"","author":{"login":"hubot"},
         "comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"createdAt":"2026-10-14T12:00:00Z","body":"what do you think, @octocat?","author":{"login":"hubot"}}]}}
        """)), "mentioned in an inline reply")
        XCTAssertFalse(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T09:30:00Z","lastEditedAt":"2026-10-14T12:00:00Z","body":"cc @octocat","author":{"login":"hubot"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"done","author":{"login":"octocat"}}
        """)), "edited to mention you after you answered")
        XCTAssertTrue(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"APPROVED","body":"thanks octocat@example.com and @octocats","author":{"login":"hubot"}}
        """)), "an email address or a longer login isn't a mention of you")
    }

    func testAnInlineReplyCountsAsAnswering() throws {
        // A reply made inline is a review with no body, which the timeline leaves out.
        XCTAssertTrue(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"COMMENTED","body":"","author":{"login":"octocat"},
         "comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"createdAt":"2026-10-14T11:00:00Z","body":"good catch","author":{"login":"octocat"}}]}}
        """)))
    }

    func testTeamMentionsAndRequestsCountOnlyForYourTeams() throws {
        let teamMentioned = """
        {"__typename":"IssueComment","createdAt":"2026-10-14T10:00:00Z","body":"@Octo/Reviewers can someone look?","author":{"login":"hubot"}}
        """
        let replied = """
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"taking it","author":{"login":"octocat"}}
        """
        XCTAssertEqual(NotificationDetailsFetcher.detail(try subject(teamMentioned), viewer: "octocat").teamTargetedAt.keys.sorted(), ["octo/reviewers"])
        XCTAssertTrue(answered(try subject(teamMentioned + "," + replied)), "a team mention you replied to")
        XCTAssertFalse(answered(try subject(replied + "," + teamMentioned.replacingOccurrences(of: "10:00", with: "12:00"))),
                       "your team mentioned again after you replied")
        let requested = replied.replacingOccurrences(of: "taking it", with: "@octocat-bot ping") + "," + """
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},
        {"__typename":"ReviewRequestedEvent","createdAt":"2026-10-14T12:00:00Z","requestedReviewer":{"__typename":"Team","slug":"Reviewers","organization":{"login":"Octo"}}}
        """
        XCTAssertFalse(answered(try subject(requested)) , "unknown membership counts as yours")
        XCTAssertFalse(answered(try subject(requested), onTeam: { _ in true }), "your team was asked after you replied")
        XCTAssertTrue(answered(try subject(requested), onTeam: { _ in false }), "another team's request doesn't ask you")
    }

    func testACutShortHistoryNeverHidesWhatCameAfterYou() throws {
        // Only the newest events came back, and they start after your reply: what's between is unknown.
        XCTAssertFalse(answered(try subject("""
        {"__typename":"IssueComment","createdAt":"2026-10-14T12:00:00Z","body":"+1","author":{"login":"hubot"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"APPROVED","author":{"login":"octocat"}}
        """, body: "@octocat please review", activityTruncated: true)))
        XCTAssertTrue(answered(try subject("""
        {"__typename":"IssueComment","createdAt":"2026-10-14T10:30:00Z","body":"+1","author":{"login":"hubot"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"APPROVED","author":{"login":"octocat"}}
        """, body: "@octocat please review", activityTruncated: true)), "the shown stretch reaches back past your answer")
    }

    func testMentionsAreReadLikeGitHubReadsThem() {
        let found = NotificationDetailsFetcher.mentions(in: "Hey @Octocat and @github/Copilot-Reviewers, see a@b.com, `@code`, @-dash, end @hubot.")
        XCTAssertEqual(found.users, ["octocat", "hubot"])
        XCTAssertEqual(found.teams, ["github/copilot-reviewers"])
    }

    /// Details GitHub would answer, changeable between refreshes.
    final class DetailBox: @unchecked Sendable {
        private let lock = NSLock()
        private var details: [String: NotificationSubjectDetail]
        var failing = false
        init(_ details: [String: NotificationSubjectDetail]) { self.details = details }
        func set(_ id: String, _ detail: NotificationSubjectDetail) { lock.withLock { details[id] = detail } }
        subscript(_ id: String) -> NotificationSubjectDetail? { lock.withLock { details[id] } }
    }

    private func answeringFetcher(_ box: DetailBox) -> NotificationDetailsFetcher {
        var fetcher = NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2))
        fetcher.answer = { threads, account in
            var result = NotificationDetailsFetcher.Result(details: [:], settled: [], viewerLogin: account.login)
            guard !box.failing else { return result }
            for thread in threads {
                result.settled.insert(thread.key)
                result.details[thread.key] = box[thread.key.id]
            }
            return result
        }
        return fetcher
    }

    private func answeringModel(
        _ github: FakeGitHub, details box: DetailBox, clears: Bool, clock: TestClock
    ) -> NotificationsModel {
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            clearsAnswered: clears, api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: answeringFetcher(box),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "token")] },
            transcriptPath: { _ in nil }, clock: { clock.now }, isVisible: { false }
        )
        model.setBadge = { _ in }
        return model
    }

    private var answeredDetail: NotificationSubjectDetail {
        var detail = NotificationSubjectDetail(state: .open)
        detail.viewerTargetedAt = now.addingTimeInterval(-7200)
        detail.viewerActedAt = now.addingTimeInterval(-3600)
        return detail
    }

    private var askedAgainDetail: NotificationSubjectDetail {
        var detail = answeredDetail
        detail.viewerTargetedAt = now.addingTimeInterval(-30)
        return detail
    }

    func testAnsweredThreadsAreMarkedDoneUntilYoureAskedAgain() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("2", reason: "mention", number: 2, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("3", reason: "author", number: 3, updated: now.addingTimeInterval(-60)),
        ]])
        var unanswered = answeredDetail
        unanswered.viewerActedAt = nil
        let box = DetailBox(["1": answeredDetail, "2": unanswered, "3": answeredDetail])
        let clock = TestClock(now)
        let model = answeringModel(github, details: box, clears: true, clock: clock)
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        XCTAssertEqual(github.actions, ["DELETE /notifications/threads/1"], "only the answered mention; your own PR's activity is never answered")
        XCTAssertEqual(Set(model.threads.map(\.key.id)), ["2", "3"])
        XCTAssertEqual(model.clearedAnswered.map(\.key.id), ["1"])
        XCTAssertTrue(banners.posted.isEmpty)
        XCTAssertNil(model.warning)

        // The same copy comes back from a refresh that raced the done: still cleared, not done twice.
        await model.refreshNow()
        XCTAssertFalse(model.threads.contains { $0.key.id == "1" })
        XCTAssertEqual(github.actions.filter { $0.hasSuffix("/1") }.count, 1)

        // On the same model: mentioned again after the answer, dated before this clock. It comes
        // back, needs you, and is never cleared again on the old judgment.
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-30)),
        ]])
        box.set("1", askedAgainDetail)
        await model.refreshNow()
        XCTAssertTrue(model.threads.contains { $0.key.id == "1" })
        XCTAssertEqual(model.counts.needsYou, 1)
        XCTAssertEqual(github.actions.filter { $0.hasSuffix("/1") }.count, 1)
        XCTAssertEqual(model.clearedAnswered.map(\.key.id), ["1"], "listed once")
    }

    func testAThreadThatChangedSinceItWasJudgedIsLeftForTheNextLook() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60))]])
        // A new mention landed after the inbox was read.
        github.setCurrent(FakeGitHub.thread("1", reason: "mention", number: 1, updated: now))
        let model = answeringModel(github, details: DetailBox(["1": answeredDetail]), clears: true, clock: TestClock(now))
        await model.refreshNow()
        try await waitUntil { model.threads.contains { $0.key.id == "1" } && model.clearedAnswered.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(github.actions.contains { $0.hasPrefix("DELETE") }, "never done without a fresh look")
        XCTAssertNil(model.warning, "a thread that moved on isn't a failure")
    }

    func testAStaleAnswerNeverHidesANewerCopy() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60))]])
        let box = DetailBox(["1": answeredDetail])
        let model = answeringModel(github, details: box, clears: false, clock: TestClock(now))
        await model.refreshNow()
        XCTAssertEqual(model.counts.answered, 1)
        // Something new arrives, and its details can't be read.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now)]])
        box.failing = true
        await model.refreshNow()
        XCTAssertEqual(model.counts.needsYou, 1, "the old answer was for an older copy")
    }

    func testReadOnlyCopiesNeverClearAnsweredThreads() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now)]])
        let model = answeringModel(github, details: DetailBox(["1": answeredDetail]), clears: false, clock: TestClock(now))
        await model.refreshNow()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(github.actions.isEmpty)
        XCTAssertEqual(model.counts.needsYou, 0, "answered doesn't need you")
        XCTAssertEqual(model.counts.answered, 1)
        XCTAssertTrue(model.clearedAnswered.isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Native renders of the window with synthetic threads, for design review.
@MainActor
final class NotificationsDesignCaptureTests: XCTestCase {
    func testCaptureNativeDesignStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTIFICATIONS_DESIGN_CAPTURE_DIR"] else {
            throw XCTSkip("Set NOTIFICATIONS_DESIGN_CAPTURE_DIR to capture synthetic native states")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var details: [NotificationThread.Key: NotificationSubjectDetail] = [:]
        var threads: [NotificationThread] = []
        func add(
            _ id: String, _ reason: String, _ repo: String, _ number: Int?, _ title: String, minutes: Double,
            unread: Bool = true, kind: NotificationSubjectKind = .pullRequest, account: String = "octocat",
            state: NotificationSubjectDetail.State? = .open, team: String? = nil
        ) {
            let collection = kind == .issue ? "issues" : "pulls"
            let thread = NotificationThread(
                key: .init(account: account, id: id), unread: unread, reason: NotificationReason(reason),
                updatedAt: now.addingTimeInterval(-minutes * 60), title: title, kind: kind, repository: repo,
                subjectAPIURL: number.map { URL(string: "https://api.github.com/repos/\(repo)/\(collection)/\($0)")! },
                number: number
            )
            threads.append(thread)
            if kind == .pullRequest || kind == .issue {
                var detail = NotificationSubjectDetail(state: state, headRefName: "feature/\(id)")
                if let team { detail.requestedTeams = [team]; detail.viewerTeam = team }
                if reason == "review_requested", team == nil { detail.viewerRequested = true }
                details[thread.key] = detail
            }
        }
        add("1", "review_requested", "sample/workspace", 212, "Add review effort settings to the repository page", minutes: 20)
        add("2", "review_requested", "sample/api", 88, "Accept review effort in the settings API", minutes: 190)
        add("3", "review_requested", "sample/agents", 41, "Remove retired rollout flags", minutes: 2 * 1440, unread: false)
        add("4", "mention", "sample/mobile", 17, "Composer loses focus after sending a message", minutes: 45, kind: .issue)
        add("5", "author", "sample/workspace", 205, "Keep the selected conversation visible", minutes: 10)
        add("6", "author", "sample/automation", 9, "Refresh the target base before publishing", minutes: 300, state: .merged)
        add("7", "comment", "sample/api", 80, "Batch notification reads", minutes: 5 * 1440, unread: false)
        let teamTitles = [
            "Tighten review request routing", "Move inbox polling off the main thread",
            "Group workflow runs by branch", "Explain why a thread is quiet",
            "Cache team membership per organization", "Retry marking threads done",
            "Name the requested team in banners", "Remember the last look across launches",
        ]
        let teamAges: [Double] = [15, 25, 35, 50, 70, 95, 400, 3 * 1440]
        for index in teamTitles.indices {
            add("t\(index)", "review_requested", "sample/web", 330 + index, teamTitles[index], minutes: teamAges[index],
                account: index == 2 ? "hubot" : "octocat", state: index == 6 ? .draft : .open, team: "sample/review-crew")
        }
        add("8", "team_mention", "sample/platform", 77, "Quarterly reliability review", minutes: 1500, kind: .issue)
        add("9", "subscribed", "sample/docs", nil, "Release notes for 2.4", minutes: 9 * 1440, unread: false, kind: .discussion)
        add("10", "subscribed", "sample/infra", 3, "Rotate the staging certificates", minutes: 600, kind: .issue)
        add("11", "ci_activity", "sample/workspace", nil, "CI workflow run failed for main branch", minutes: 30, kind: .checkSuite)
        add("12", "ci_activity", "sample/api", nil, "Deploy workflow run succeeded for main branch", minutes: 1440 * 2, unread: false, kind: .checkSuite)
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 4242, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Features and infrastructure improvements", sessions: [
                .init(id: "s1", title: "Keep the selected conversation visible", status: .waiting),
            ]),
        ])
        let workspacePR = try XCTUnwrap(PullRequestKey("sample/workspace#205"))
        for (name, appearance, width, offline) in [
            ("mac-dark", NSAppearance.Name.darkAqua, 1280.0, false),
            ("mac-light", .aqua, 1280.0, false),
            ("mac-compact", .darkAqua, 880.0, false),
            ("mac-offline", .aqua, 880.0, true),
        ] {
            let workspace = FakeWorkspace(snapshot: snapshot)
            let model = NotificationsModel(
                workspace: workspace, defaults: UserDefaults(suiteName: "notifications-design-\(UUID().uuidString)")!,
                writesState: false, loadAccounts: { throw NotificationsFetchError.notSignedIn },
                transcriptPath: { _ in nil }, openURL: { _ in XCTFail("Capture must not open anything") }
            )
            model.setBadge = { _ in }
            await model.pollWorkspace()
            if offline { workspace.answer(fetches: [.unreachable]); await model.pollWorkspace() }
            model.show(
                threads, details: details, accounts: ["octocat", "hubot"], links: [workspacePR: "s1"],
                lookedAt: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-60),
                truncated: offline ? ["octocat"] : [],
                warning: offline ? "GitHub refresh failed. Showing the last successful results." : nil,
                cleared: Array(threads.prefix(3))
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: NotificationsView(model: model))
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            for _ in 0..<15 {
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
            }
            let view = window.contentView?.superview ?? host
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
            window.close()
        }
    }
}

/// Reads the real inbox of every gh account, without changing anything.
@MainActor
final class NotificationsLiveTests: XCTestCase {
    func testReadsTheLiveInbox() async throws {
        guard ProcessInfo.processInfo.environment["NOTIFICATIONS_LIVE"] == "1" else {
            throw XCTSkip("Set NOTIFICATIONS_LIVE=1 to read the signed-in gh accounts' notifications")
        }
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-live-\(UUID().uuidString)")!,
            writesState: false, transcriptPath: { _ in nil }, openURL: { _ in XCTFail("Must not open anything") }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .loaded, model.warning ?? "")
        let layout = NotificationLayout(items: model.items)
        for lane in layout.lanes {
            print("live lane \(lane.lane.band.title) / \(lane.lane.title): \(lane.items.count) threads, \(lane.unreadCount) unread")
        }
        let reviews = model.items.filter { $0.thread.reason == .reviewRequested }
        print("live review requests: \(reviews.filter { $0.lane == .reviewRequested }.count) to you, \(reviews.filter { $0.lane == .teamReviewRequested }.count) via teams, \(reviews.filter(\.isClassifying).count) unclassified, \(reviews.filter { $0.detail?.requestHistoryComplete == false }.count) with incomplete history")
        print("live counts: \(model.counts), accounts: \(model.accounts), truncated: \(model.truncatedAccounts)")
        let answered = model.items.filter(\.isAnswered)
        print("live answered (would clear): \(answered.count): " + answered.prefix(8).map(\.thread.shortName).joined(separator: ", "))
        XCTAssertTrue(reviews.allSatisfy { !$0.isClassifying }, "every review request is classified")
    }
}
