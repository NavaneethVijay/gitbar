import Foundation

/// The GitHub module's `ProviderClient` — github.com or GitHub Enterprise
/// Server, REST plus a little GraphQL. Knows GitHub's endpoints and hands
/// back `Domain` types; all HTTP mechanics (ETag/304 caching, decoding,
/// status handling) are the shared `HTTPTransport`.
actor GitHubClient: ProviderClient {
    nonisolated let kind = ProviderKind.github
    nonisolated let capabilities = ProviderCapabilities(supportsRequestChanges: true, supportsNotifications: true)

    private let transport: HTTPTransport
    /// Site root for building browser links ("https://github.com").
    private let webBase: String
    private let isFineGrainedToken: Bool
    /// GraphQL search pages by cursor, the protocol by page number: the
    /// cursor for page N+1 is remembered when page N arrives.
    private var authorSearchCursors: [String: String] = [:]
    private let restBase: String
    private let graphQLURL: URL

    /// Adds `body_html` alongside the raw `body` on any endpoint that
    /// renders one — GitHub's own server-side Markdown rendering, the same
    /// output github.com shows, in the same response. Only requested where
    /// a body actually reaches a screen.
    private static let fullMediaType = ["Accept": "application/vnd.github.full+json"]

    init(host: String, token: String) {
        webBase = "https://\(host)"
        isFineGrainedToken = token.hasPrefix("github_pat_")
        // github.com's API lives on its own host; Enterprise Server serves it
        // under /api/v3 (REST) and /api/graphql on the instance itself.
        if host == "github.com" {
            restBase = "https://api.github.com"
            graphQLURL = URL(string: "https://api.github.com/graphql")!
        } else {
            restBase = "https://\(host)/api/v3"
            graphQLURL = URL(string: "https://\(host)/api/graphql") ?? URL(string: "https://api.github.com/graphql")!
        }
        transport = HTTPTransport(policy: HTTPPolicy(
            kind: .github,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            ],
            classifyError: GitHubMapping.classifyError,
            rateLimit: GitHubMapping.rateLimit
        ))
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: restBase + path) else { throw ProviderError.unexpectedStatus(.github, 0) }
        return url
    }

    private func get<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> (value: T, hasNextPage: Bool) {
        try await transport.get(url(path), headers: headers)
    }

    private struct GraphQLQuery: Encodable {
        let query: String
        let variables: [String: String?]
    }

    private func graphQL<T: Decodable>(_ query: String, variables: [String: String?]) async throws -> T {
        try await transport.send("POST", graphQLURL, body: GraphQLQuery(query: query, variables: variables))
    }

    // MARK: - Account

    func validate() async throws -> AccountProfile {
        let user: GitHubUser = try await get("/user").value
        return AccountProfile(login: user.login, name: user.name, avatarURL: user.avatarURL)
    }

    /// Pages through everything (100 at a time, capped at 10 pages) rather
    /// than stopping at the first 100.
    func repositories() async throws -> [RemoteRepo] {
        var repos: [RemoteRepo] = []
        for page in 1...10 {
            let result: (value: [GitHubRepo], hasNextPage: Bool) = try await get(
                "/user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100&page=\(page)")
            repos += result.value.map { RemoteRepo(path: $0.fullName, isPrivate: $0.isPrivate) }
            if !result.hasNextPage { break }
        }
        return repos
    }

    // MARK: - Lists

    func recentPullRequests(repo: String, limit: Int) async throws -> [PullRequest] {
        let pulls: [GitHubPullRequest] = try await get("/repos/\(repo)/pulls?state=open&per_page=\(limit)").value
        return pulls.map(\.domain)
    }

    /// GitHub's `/issues` list includes PRs too — anything with a
    /// `pull_request` marker is filtered out.
    func recentIssues(repo: String, limit: Int) async throws -> [Issue] {
        let issues: [GitHubIssue] = try await get("/repos/\(repo)/issues?state=open&per_page=\(limit)").value
        return issues.filter { $0.pullRequest == nil }.map(\.domain)
    }

    func pullRequests(repo: String, page: Int) async throws -> Page<PullRequest> {
        let result: (value: [GitHubPullRequest], hasNextPage: Bool) =
            try await get("/repos/\(repo)/pulls?state=open&per_page=20&page=\(page)", headers: Self.fullMediaType)
        return Page(items: result.value.map(\.domain), hasNextPage: result.hasNextPage)
    }

    func issues(repo: String, page: Int) async throws -> Page<Issue> {
        let result: (value: [GitHubIssue], hasNextPage: Bool) =
            try await get("/repos/\(repo)/issues?state=open&per_page=20&page=\(page)")
        return Page(items: result.value.filter { $0.pullRequest == nil }.map(\.domain), hasNextPage: result.hasNextPage)
    }

    func pullRequest(repo: String, number: Int) async throws -> PullRequest {
        let pr: GitHubPullRequest = try await get("/repos/\(repo)/pulls/\(number)", headers: Self.fullMediaType).value
        return pr.domain
    }

    /// GitHub's REST PR list can't filter by author, so this is a GraphQL
    /// search — one request that returns everything a PR row and screen need.
    func pullRequests(repo: String, page: Int, author: String) async throws -> Page<PullRequest> {
        let cursorKey = { (page: Int) in "\(repo)|\(author)|\(page)" }
        let after: String? = page > 1 ? authorSearchCursors[cursorKey(page)] : nil
        guard page == 1 || after != nil else { return Page(items: [], hasNextPage: false) }

        struct Response: Decodable {
            struct DataField: Decodable { let search: Search }
            struct Search: Decodable { let pageInfo: PageInfo; let nodes: [Node] }
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Login: Decodable { let login: String? }
            struct ReviewRequests: Decodable {
                struct Request: Decodable { let requestedReviewer: Login? }
                let nodes: [Request]
            }
            /// Search can match non-PR nodes; those decode with every field nil.
            struct Node: Decodable {
                let number: Int?
                let title: String?
                let isDraft: Bool?
                let createdAt: Date?
                let body: String?
                let bodyHTML: String?
                let headRefName: String?
                let baseRefName: String?
                let headRefOid: String?
                let author: Login?
                let reviewRequests: ReviewRequests?
            }
            let data: DataField?
        }
        let query = """
        query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: 20, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { ... on PullRequest { number title isDraft createdAt body bodyHTML headRefName baseRefName headRefOid
            author { login } reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } } } } } }
        """
        let response: Response = try await graphQL(query, variables: [
            "q": "repo:\(repo) is:pr is:open author:\(author) sort:created-desc",
            "after": after,
        ])
        guard let search = response.data?.search else { return Page(items: [], hasNextPage: false) }
        if search.pageInfo.hasNextPage, let end = search.pageInfo.endCursor {
            authorSearchCursors[cursorKey(page + 1)] = end
        }
        let items = search.nodes.compactMap { node -> PullRequest? in
            guard let number = node.number, let title = node.title, let createdAt = node.createdAt else { return nil }
            return PullRequest(
                number: number, title: title, author: node.author?.login ?? author,
                isDraft: node.isDraft ?? false,
                requestedReviewers: node.reviewRequests?.nodes.compactMap { $0.requestedReviewer?.login } ?? [],
                sourceBranch: node.headRefName ?? "", targetBranch: node.baseRefName ?? "",
                headSHA: node.headRefOid ?? "", body: node.body ?? "", bodyHTML: node.bodyHTML,
                createdAt: createdAt)
        }
        return Page(items: items, hasNextPage: search.pageInfo.hasNextPage)
    }

    // MARK: - PR details

    /// `statusCheckRollup` on each PR's head commit — the same summary
    /// github.com's PR list shows, covering check runs and legacy commit
    /// statuses. One aliased GraphQL query for the whole page.
    func checkSummaries(repo: String, numbers: [Int]) async throws -> [Int: CheckSummary] {
        guard !numbers.isEmpty, let (owner, name) = Self.split(repo) else { return [:] }
        struct Response: Decodable {
            struct DataField: Decodable { let repository: [String: PullRequestNode?]? }
            struct PullRequestNode: Decodable {
                struct Commits: Decodable { let nodes: [CommitNode] }
                struct CommitNode: Decodable { let commit: Commit }
                struct Commit: Decodable { let statusCheckRollup: Rollup? }
                struct Rollup: Decodable { let state: String }
                let number: Int
                let commits: Commits
            }
            let data: DataField?
        }
        let fields = numbers.map {
            "p\($0): pullRequest(number: \($0)) { number commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }"
        }
        let query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(fields.joined(separator: " ")) } }"
        let response: Response = try await graphQL(query, variables: ["owner": owner, "name": name])

        var result: [Int: CheckSummary] = [:]
        for case let node? in (response.data?.repository ?? [:]).values {
            result[node.number] = GitHubMapping.checkSummary(rollupState: node.commits.nodes.first?.commit.statusCheckRollup?.state)
        }
        return result
    }

    func checks(repo: String, pullRequest: PullRequest) async throws -> [CheckRun] {
        let list: GitHubCheckRunList = try await get("/repos/\(repo)/commits/\(pullRequest.headSHA)/check-runs").value
        return list.checkRuns.map(\.domain)
    }

    /// A PR's conversation comments are issue comments on GitHub.
    func comments(repo: String, number: Int) async throws -> [Comment] {
        let comments: [GitHubComment] =
            try await get("/repos/\(repo)/issues/\(number)/comments?per_page=50", headers: Self.fullMediaType).value
        return comments.map(\.domain)
    }

    func reviewers(repo: String, pullRequest: PullRequest) async throws -> [Reviewer] {
        let reviews: [GitHubReview] = try await get("/repos/\(repo)/pulls/\(pullRequest.number)/reviews").value
        return GitHubMapping.reviewers(requested: pullRequest.requestedReviewers, reviews: reviews)
    }

    // MARK: - Writes

    func submitReview(repo: String, number: Int, decision: ReviewDecision, body: String?) async throws {
        struct Submission: Encodable { let body: String?; let event: String }
        struct Ignored: Decodable {}
        let _: Ignored = try await transport.send(
            "POST", url("/repos/\(repo)/pulls/\(number)/reviews"),
            body: Submission(body: body, event: GitHubMapping.reviewEvent(decision)))
    }

    func createFormData(repo: String) async throws -> CreatePullRequestFormData {
        async let info: (value: GitHubRepoInfo, hasNextPage: Bool) = get("/repos/\(repo)")
        async let branches = branchNames(repo: repo)
        // Best-effort: a template that can't be fetched shouldn't block
        // opening a PR at all.
        async let templates = try? pullRequestTemplates(repo: repo)
        let (repoInfo, names, templateList) = try await (info, branches, templates)
        return CreatePullRequestFormData(branches: names, defaultBranch: repoInfo.value.defaultBranch,
                                         templates: templateList ?? [])
    }

    func createPullRequest(repo: String, draft: CreatePullRequestDraft) async throws -> PullRequest {
        struct NewPullRequest: Encodable { let title: String; let head: String; let base: String; let body: String? }
        let created: GitHubPullRequest = try await transport.send(
            "POST", url("/repos/\(repo)/pulls"),
            body: NewPullRequest(title: draft.title, head: draft.sourceBranch, base: draft.targetBranch, body: draft.body),
            headers: Self.fullMediaType)
        return created.domain
    }

    func rateLimitStatus() async -> RateLimitStatus? {
        await transport.lastKnownRateLimit
    }

    // MARK: - Token access

    func tokenAccess() async throws -> TokenAccess {
        let result: (value: GitHubUser, hasNextPage: Bool, response: HTTPURLResponse) =
            try await transport.getWithResponse(url("/user"))
        return GitHubMapping.tokenAccess(scopesHeader: result.response.value(forHTTPHeaderField: "X-OAuth-Scopes"),
                                         isFineGrained: isFineGrainedToken)
    }

    // MARK: - Notifications

    /// Unread threads (GitHub's default `all=false`). Unchanged inboxes come
    /// back as ETag 304s, which don't count against the rate limit.
    func notifications(participatingOnly: Bool) async throws -> InboxFetch {
        let result: (value: [GitHubNotification], hasNextPage: Bool, response: HTTPURLResponse) =
            try await transport.getWithResponse(url("/notifications?participating=\(participatingOnly)&per_page=50"))
        let pollInterval = result.response.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init)
        return InboxFetch(items: result.value.map { $0.domain(webBase: webBase) }, pollInterval: pollInterval)
    }

    func markNotificationRead(id: String) async throws {
        try await transport.sendEmpty("PATCH", url("/notifications/threads/\(id)"))
    }

    func markAllNotificationsRead() async throws {
        try await transport.sendEmpty("PUT", url("/notifications"))
    }

    // MARK: - Helpers

    /// Every branch, 100 at a time — capped so a repo with thousands of
    /// stale branches can't turn one form open into dozens of requests.
    private func branchNames(repo: String) async throws -> [String] {
        var names: [String] = []
        for page in 1...10 {
            let result: (value: [GitHubBranch], hasNextPage: Bool) =
                try await get("/repos/\(repo)/branches?per_page=100&page=\(page)")
            names += result.value.map(\.name)
            if !result.hasNextPage { break }
        }
        return names
    }

    /// The REST create-PR call doesn't apply templates (only github.com's
    /// web form does); GraphQL's `pullRequestTemplates` resolves every
    /// location and filename casing in one request.
    private func pullRequestTemplates(repo: String) async throws -> [PullRequestTemplate] {
        guard let (owner, name) = Self.split(repo) else { return [] }
        struct Response: Decodable {
            struct DataField: Decodable { let repository: Repository? }
            struct Repository: Decodable { let pullRequestTemplates: [GitHubPullRequestTemplate]? }
            let data: DataField?
        }
        let response: Response = try await graphQL(
            "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { pullRequestTemplates { filename body } } }",
            variables: ["owner": owner, "name": name])
        return GitHubMapping.templates(response.data?.repository?.pullRequestTemplates ?? [])
    }

    private static func split(_ path: String) -> (owner: String, name: String)? {
        let parts = path.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}
