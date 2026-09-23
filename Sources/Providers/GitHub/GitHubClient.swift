import Foundation

/// The GitHub module's `ProviderClient` — github.com or GitHub Enterprise
/// Server, REST plus a little GraphQL. Knows GitHub's endpoints and hands
/// back `Domain` types; all HTTP mechanics (ETag/304 caching, decoding,
/// status handling) are the shared `HTTPTransport`.
actor GitHubClient: ProviderClient {
    nonisolated let kind = ProviderKind.github
    nonisolated let capabilities = ProviderCapabilities(supportsRequestChanges: true)

    private let transport: HTTPTransport
    private let restBase: String
    private let graphQLURL: URL

    /// Adds `body_html` alongside the raw `body` on any endpoint that
    /// renders one — GitHub's own server-side Markdown rendering, the same
    /// output github.com shows, in the same response. Only requested where
    /// a body actually reaches a screen.
    private static let fullMediaType = ["Accept": "application/vnd.github.full+json"]

    init(host: String, token: String) {
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
        let variables: [String: String]
    }

    private func graphQL<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
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
