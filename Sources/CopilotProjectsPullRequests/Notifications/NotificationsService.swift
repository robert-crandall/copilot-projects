import Foundation

/// GitHub's notifications REST API, called with the gh token of each account.
struct GitHubNotificationsAPI: Sendable {
    var base = URL(string: "https://api.github.com")!
    var timeout: TimeInterval = 30
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    struct Failure: Error, Equatable, LocalizedError {
        let status: Int?
        let message: String

        var isUnauthorized: Bool { status == 401 }
        var errorDescription: String? { message }
    }

    struct Page: Sendable {
        let threads: [NotificationThread]
        let next: URL?
        /// The number of the last page, when GitHub says.
        var lastPage: Int? = nil
        let lastModified: String?
        let pollInterval: TimeInterval?
    }

    enum Listing: Sendable {
        case page(Page)
        /// Nothing changed since `If-Modified-Since`.
        case notModified
    }

    func list(
        account: GitHubAccount, query: [URLQueryItem], ifModifiedSince: String? = nil
    ) async throws -> Listing {
        var components = URLComponents(url: base.appendingPathComponent("notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return try await list(account: account, url: components.url!, ifModifiedSince: ifModifiedSince)
    }

    func list(account: GitHubAccount, url: URL, ifModifiedSince: String? = nil) async throws -> Listing {
        var request = self.request(url, account: account, method: "GET")
        if let ifModifiedSince { request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since") }
        // A conditional poll must reach GitHub, never a local cache's answer.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 304 { return .notModified }
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let link = http?.value(forHTTPHeaderField: "Link")
        return .page(Page(
            threads: try Self.decode(data, account: account.login),
            next: Self.link("next", in: link),
            lastPage: Self.link("last", in: link).flatMap(Self.pageNumber),
            lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
            pollInterval: http?.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init)
        ))
    }

    /// Marks the thread read on GitHub, as opening it there would.
    func markRead(account: GitHubAccount, threadId: String) async throws {
        try await act(account: account, path: "notifications/threads/\(threadId)", method: "PATCH")
    }

    /// Marks the thread done: it leaves the inbox until something new happens on it.
    func markDone(account: GitHubAccount, threadId: String) async throws {
        try await act(account: account, path: "notifications/threads/\(threadId)", method: "DELETE")
    }

    /// Stops notifications for the thread unless the user is mentioned or asked again.
    func unsubscribe(account: GitHubAccount, threadId: String) async throws {
        try await act(account: account, path: "notifications/threads/\(threadId)/subscription", method: "DELETE")
    }

    private func act(account: GitHubAccount, path: String, method: String) async throws {
        let (data, response) = try await send(request(base.appendingPathComponent(path), account: account, method: method))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
    }

    private func request(_ url: URL, account: GitHubAccount, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("copilot-projects", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func failure(status: Int, data: Data) -> Failure {
        struct Body: Decodable { let message: String? }
        let detail = (try? JSONDecoder().decode(Body.self, from: data))?.message
        switch status {
        case 401: return Failure(status: status, message: "GitHub rejected the gh token. Run gh auth login again.")
        case 403 where detail?.localizedCaseInsensitiveContains("rate limit") == true:
            return Failure(status: status, message: "GitHub’s rate limit was reached. Notifications refresh again shortly.")
        default:
            return Failure(status: status, message: detail.map { "GitHub returned HTTP \(status): \($0)" } ?? "GitHub returned HTTP \(status).")
        }
    }

    private struct Thread: Decodable {
        struct Subject: Decodable {
            let title: String?
            let url: String?
            let type: String?
        }
        struct Repository: Decodable {
            let full_name: String
        }
        let id: String
        let unread: Bool
        let reason: String
        let updated_at: Date
        let last_read_at: Date?
        let subject: Subject
        let repository: Repository
    }

    static func decode(_ data: Data, account: String) throws -> [NotificationThread] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Thread].self, from: data).map { thread in
            let apiURL = thread.subject.url.flatMap(URL.init(string:))
            return NotificationThread(
                key: .init(account: account, id: thread.id), unread: thread.unread,
                reason: NotificationReason(thread.reason), updatedAt: thread.updated_at,
                lastReadAt: thread.last_read_at, title: thread.subject.title ?? "", kind: NotificationSubjectKind(thread.subject.type ?? ""),
                repository: thread.repository.full_name, subjectAPIURL: apiURL,
                number: NotificationThread.number(apiURL: apiURL)
            )
        }
    }

    /// The `rel="next"` URL of a `Link` header.
    static func nextLink(_ header: String?) -> URL? { link("next", in: header) }

    static func link(_ relation: String, in header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == "rel=\"\(relation)\"" }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">") else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }

    static func pageNumber(_ url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init)
    }

    /// `url` asking for page `number` instead.
    static func page(_ number: Int, of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(number)")]
        return components.url
    }
}

/// How much of an inbox one refresh reads. A busy inbox gains hundreds of
/// threads a day, mostly CI, so the passes favor what reached the user.
struct NotificationsFetchPlan: Equatable, Sendable {
    /// Unread threads the user takes part in: reviews, mentions, their own work.
    var participatingPages = 10
    /// The newest unread threads of every kind, for watched repositories and CI.
    var unreadPages = 4
    /// Recently read threads that aren't done, so All shows what was opened.
    var readPages = 4
    var readWindow: TimeInterval = 3 * 86_400
    var perPage = 50

    struct Result: Sendable {
        var threads: [NotificationThread]
        /// Unread threads exist beyond the newest pages read.
        var truncated: Bool
    }

    func fetch(account: GitHubAccount, api: GitHubNotificationsAPI, now: Date) async throws -> Result {
        let since = ISO8601DateFormatter().string(from: now.addingTimeInterval(-readWindow))
        async let participating = pages(account, api, [("participating", "true")], limit: participatingPages)
        async let unread = pages(account, api, [], limit: unreadPages)
        async let read = pages(account, api, [("all", "true"), ("since", since)], limit: readPages)
        let passes = try await [participating, unread, read]
        var merged: [String: NotificationThread] = [:]
        for thread in passes.flatMap(\.threads) {
            if let existing = merged[thread.key.id], existing.updatedAt >= thread.updatedAt { continue }
            merged[thread.key.id] = thread
        }
        return Result(threads: Array(merged.values), truncated: passes[0].truncated || passes[1].truncated)
    }

    /// The first page, then the rest up to `limit` at once when GitHub says
    /// how many there are, else one after another.
    private func pages(
        _ account: GitHubAccount, _ api: GitHubNotificationsAPI, _ query: [(String, String)], limit: Int
    ) async throws -> Result {
        guard case .page(let first) = try await api.list(
            account: account, query: query.map(URLQueryItem.init) + [URLQueryItem(name: "per_page", value: "\(perPage)")]
        ) else { return Result(threads: [], truncated: false) }
        guard let next = first.next else { return Result(threads: first.threads, truncated: false) }
        guard limit > 1 else { return Result(threads: first.threads, truncated: true) }
        if let last = first.lastPage {
            let urls = (2...max(2, min(last, limit))).compactMap { GitHubNotificationsAPI.page($0, of: next) }
            let rest = try await withThrowingTaskGroup(of: [NotificationThread].self) { group in
                for url in urls {
                    group.addTask {
                        if case .page(let page) = try await api.list(account: account, url: url) { return page.threads }
                        return []
                    }
                }
                var threads: [NotificationThread] = []
                for try await page in group { threads += page }
                return threads
            }
            return Result(threads: first.threads + rest, truncated: last > limit)
        }
        var threads = first.threads
        var url: URL? = next
        var read = 1
        while let current = url {
            guard read < limit else { return Result(threads: threads, truncated: true) }
            guard case .page(let page) = try await api.list(account: account, url: current) else { break }
            threads += page.threads
            read += 1
            url = page.next
        }
        return Result(threads: threads, truncated: false)
    }
}

/// Reads who was asked to review each pull request, and each subject's state,
/// in batched GraphQL queries.
struct NotificationDetailsFetcher: Sendable {
    var graphQL = GitHubGraphQL()
    var batchSize = 20
    /// Batches in flight at once for one account.
    var concurrency = 4

    struct Result: Sendable {
        var details: [NotificationThread.Key: NotificationSubjectDetail]
        /// Threads GitHub answered for, with or without a subject it could show.
        var settled: Set<NotificationThread.Key>
        var viewerLogin: String?
    }

    /// Only review requests need who was asked; everything else needs its state.
    static let subjectFragment = """
    fragment Subject on IssueOrPullRequest {
      ... on PullRequest { state isDraft headRefName }
      ... on Issue { state stateReason }
    }
    """

    static let requestsFragment = """
    fragment Requests on IssueOrPullRequest {
      ... on PullRequest {
        state isDraft headRefName
        timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 25) {
          nodes { ... on ReviewRequestedEvent { requestedReviewer {
            __typename ... on User { login } ... on Team { slug organization { login } }
          } } }
        }
      }
      ... on Issue { state stateReason }
    }
    """

    struct Login: Decodable { let login: String? }
    struct Reviewer: Decodable {
        let __typename: String?
        let login: String?
        let slug: String?
        let organization: Login?
    }
    struct Event: Decodable { let requestedReviewer: Reviewer? }
    struct Timeline: Decodable { let nodes: [Event?]? }
    struct Subject: Decodable {
        let state: String?
        let isDraft: Bool?
        let headRefName: String?
        let stateReason: String?
        let timelineItems: Timeline?
    }
    /// Each alias: a repository holding the subject, or the viewer.
    struct Node: Decodable {
        let login: String?
        let issueOrPullRequest: Subject?
    }

    func details(
        for threads: [NotificationThread], account: GitHubAccount
    ) async -> Result {
        let subjects = threads.filter { ($0.kind == .pullRequest || $0.kind == .issue) && $0.number != nil }
        let batches = stride(from: 0, to: subjects.count, by: batchSize).map {
            Array(subjects[$0..<min($0 + batchSize, subjects.count)])
        }
        var result = Result(details: [:], settled: [], viewerLogin: account.login.isEmpty ? nil : account.login)
        var answers: [([NotificationThread], [String: Node?])] = []
        await withTaskGroup(of: ([NotificationThread], [String: Node?]?).self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { (batch, await query(batch, account: account)) }
            }
            for _ in 0..<concurrency { addNext() }
            for await (batch, answer) in group {
                if let answer { answers.append((batch, answer)) }
                addNext()
            }
        }
        if result.viewerLogin == nil {
            result.viewerLogin = answers.lazy.compactMap { $0.1["viewer"]??.login }.first
        }
        for (batch, answer) in answers {
            for (index, thread) in batch.enumerated() {
                result.settled.insert(thread.key)
                guard let subject = answer["t\(index)"]??.issueOrPullRequest else { continue }
                result.details[thread.key] = Self.detail(subject, viewer: result.viewerLogin)
            }
        }
        return result
    }

    private func query(_ batch: [NotificationThread], account: GitHubAccount) async -> [String: Node?]? {
        var declarations: [String] = []
        var fields = ["viewer { login }"]
        var variables: [String: Any] = [:]
        // GitHub refuses a query that defines a fragment it doesn't use.
        var used: Set<String> = []
        for (index, thread) in batch.enumerated() {
            let parts = thread.repository.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let number = thread.number else { continue }
            let fragment = thread.reason == .reviewRequested ? "Requests" : "Subject"
            used.insert(fragment)
            declarations += ["$o\(index): String!", "$r\(index): String!", "$n\(index): Int!"]
            fields.append("t\(index): repository(owner: $o\(index), name: $r\(index)) { issueOrPullRequest(number: $n\(index)) { ...\(fragment) } }")
            variables["o\(index)"] = parts[0]
            variables["r\(index)"] = parts[1]
            variables["n\(index)"] = number
        }
        let header = declarations.isEmpty ? "" : "(\(declarations.joined(separator: ", ")))"
        let fragments = [used.contains("Subject") ? Self.subjectFragment : nil, used.contains("Requests") ? Self.requestsFragment : nil]
        let text = "query\(header) {\n\(fields.joined(separator: "\n"))\n}\n" + fragments.compactMap { $0 }.joined(separator: "\n")
        do {
            // Partial answers are kept: a subject GitHub won't show settles without detail.
            return try await graphQL.run(text, variables: variables, token: account.token, as: [String: Node?].self).data
        } catch {
            NSLog("copilot-notifications: subject details failed for \(account.login): \(error)")
            return nil
        }
    }

    static func detail(_ subject: Subject, viewer: String?) -> NotificationSubjectDetail {
        var detail = NotificationSubjectDetail()
        switch (subject.state, subject.isDraft, subject.stateReason) {
        case ("OPEN", true, _): detail.state = .draft
        case ("OPEN", _, _): detail.state = .open
        case ("MERGED", _, _): detail.state = .merged
        case ("CLOSED", _, "COMPLETED"): detail.state = .completed
        case ("CLOSED", _, "NOT_PLANNED"): detail.state = .notPlanned
        case ("CLOSED", _, _): detail.state = .closed
        default: break
        }
        detail.headRefName = subject.headRefName
        let reviewers = (subject.timelineItems?.nodes ?? []).compactMap { $0?.requestedReviewer }.reversed()
        let viewer = viewer?.lowercased()
        var teams: [String] = []
        for reviewer in reviewers {
            if reviewer.__typename == "User", let login = reviewer.login?.lowercased(), login == viewer {
                detail.viewerRequested = true
            } else if reviewer.__typename == "Team", let slug = reviewer.slug, let org = reviewer.organization?.login {
                let name = "\(org)/\(slug)"
                if !teams.contains(name) { teams.append(name) }
            }
        }
        detail.requestedTeams = teams
        return detail
    }

    /// The teams in `organization` the viewer is on, to name the right one.
    func viewerTeams(organization: String, account: GitHubAccount, login: String) async -> Set<String>? {
        struct Teams: Decodable {
            struct Organization: Decodable {
                struct Connection: Decodable { let nodes: [Login?]? }
                let teams: Connection?
            }
            let organization: Organization?
        }
        // Each team's slug arrives as `login` so it decodes like the other names.
        let text = """
        query($org: String!, $login: String!) {
          organization(login: $org) { teams(first: 100, userLogins: [$login]) { nodes { login: slug } } }
        }
        """
        guard let answer = try? await graphQL.run(
            text, variables: ["org": organization, "login": login], token: account.token, as: Teams.self
        ).data, let nodes = answer.organization?.teams?.nodes else { return nil }
        return Set(nodes.compactMap { $0?.login.map { "\(organization)/\($0)".lowercased() } })
    }
}
