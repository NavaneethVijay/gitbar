import Foundation

/// The GitLab module's `ProviderClient` — GitLab.com or a self-managed
/// instance, REST v4 plus one GraphQL query. Knows GitLab's endpoints and
/// hands back `Domain` types; all HTTP mechanics (ETag/304 caching,
/// decoding, status handling) are the shared `HTTPTransport`.
///
/// Projects are addressed by their URL-encoded full path
/// (`group%2Fsubgroup%2Fproject`), so `RepoRef.path` is used as-is with no
/// numeric-id lookup.
actor GitLabClient: ProviderClient {
    nonisolated let kind = ProviderKind.gitlab
    /// GitLab's REST API has no "request changes" verdict (approve, or
    /// leave a comment), and its To-Do List is the inbox.
    nonisolated let capabilities = ProviderCapabilities(supportsRequestChanges: false, supportsNotifications: true)

    private let transport: HTTPTransport
    private let restBase: String
    private let graphQLURL: URL
    /// Set once an instance's GraphQL schema rejects the approval fields
    /// (very old versions) — later summaries ask for CI status only.
    private var approvalFieldsUnsupported = false

    init(host: String, token: String) {
        // Same layout on GitLab.com and self-managed (including instances
        // served under a relative path like `example.com/gitlab`).
        restBase = "https://\(host)/api/v4"
        graphQLURL = URL(string: "https://\(host)/api/graphql") ?? URL(string: "https://gitlab.com/api/graphql")!
        transport = HTTPTransport(policy: HTTPPolicy(
            kind: .gitlab,
            headers: [
                // Bearer works for personal/project/group access tokens on
                // REST and is the documented form for GraphQL.
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
            ],
            classifyError: GitLabMapping.classifyError,
            rateLimit: GitLabMapping.rateLimit,
            hasNextPage: GitLabMapping.hasNextPage
        ))
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: restBase + path) else { throw ProviderError.unexpectedStatus(.gitlab, 0) }
        return url
    }

    private func get<T: Decodable>(_ path: String) async throws -> (value: T, hasNextPage: Bool) {
        try await transport.get(url(path))
    }

    /// `group/sub/project` → `group%2Fsub%2Fproject`, GitLab's project id form.
    private static func project(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
    }

    private static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private struct Empty: Codable {}

    // MARK: - Account

    func validate() async throws -> AccountProfile {
        let user: GitLabUser = try await get("/user").value
        return AccountProfile(login: user.username, name: user.name, avatarURL: user.avatarURL)
    }

    /// Projects you're a member of (directly or through a group), most
    /// recently active first — 100 at a time, capped at 10 pages.
    func repositories() async throws -> [RemoteRepo] {
        var repos: [RemoteRepo] = []
        for page in 1...10 {
            let result: (value: [GitLabProject], hasNextPage: Bool) = try await get(
                "/projects?membership=true&archived=false&order_by=last_activity_at&per_page=100&page=\(page)")
            repos += result.value.map { RemoteRepo(path: $0.pathWithNamespace, isPrivate: $0.visibility != "public") }
            if !result.hasNextPage { break }
        }
        return repos
    }

    // MARK: - Lists

    private func mergeRequestsPath(_ repo: String, perPage: Int, page: Int, author: String? = nil) -> String {
        var path = "/projects/\(Self.project(repo))/merge_requests?state=opened&order_by=created_at&sort=desc&per_page=\(perPage)&page=\(page)"
        if let author { path += "&author_username=\(Self.query(author))" }
        return path
    }

    func recentPullRequests(repo: String, limit: Int) async throws -> [PullRequest] {
        let mrs: [GitLabMergeRequest] = try await get(mergeRequestsPath(repo, perPage: limit, page: 1)).value
        return mrs.map(\.domain)
    }

    func recentIssues(repo: String, limit: Int) async throws -> [Issue] {
        try await issues(repo: repo, perPage: limit, page: 1).items
    }

    func pullRequests(repo: String, page: Int) async throws -> Page<PullRequest> {
        let result: (value: [GitLabMergeRequest], hasNextPage: Bool) = try await get(mergeRequestsPath(repo, perPage: 20, page: page))
        return Page(items: result.value.map(\.domain), hasNextPage: result.hasNextPage)
    }

    func issues(repo: String, page: Int) async throws -> Page<Issue> {
        try await issues(repo: repo, perPage: 20, page: page)
    }

    /// A project with issues turned off (common when a team tracks work
    /// elsewhere) answers 403/404 — that's "no issues", not a failure.
    private func issues(repo: String, perPage: Int, page: Int) async throws -> Page<Issue> {
        do {
            let result: (value: [GitLabIssue], hasNextPage: Bool) = try await get(
                "/projects/\(Self.project(repo))/issues?state=opened&order_by=created_at&sort=desc&per_page=\(perPage)&page=\(page)")
            return Page(items: result.value.map(\.domain), hasNextPage: result.hasNextPage)
        } catch ProviderError.forbidden {
            return Page(items: [], hasNextPage: false)
        } catch ProviderError.unexpectedStatus(_, 404) {
            return Page(items: [], hasNextPage: false)
        }
    }

    func pullRequest(repo: String, number: Int) async throws -> PullRequest {
        let mr: GitLabMergeRequest = try await get("/projects/\(Self.project(repo))/merge_requests/\(number)").value
        return mr.domain
    }

    /// GitLab's MR list filters by author server-side — same endpoint.
    func pullRequests(repo: String, page: Int, author: String) async throws -> Page<PullRequest> {
        let result: (value: [GitLabMergeRequest], hasNextPage: Bool) =
            try await get(mergeRequestsPath(repo, perPage: 20, page: page, author: author))
        return Page(items: result.value.map(\.domain), hasNextPage: result.hasNextPage)
    }

    // MARK: - PR details

    private struct GraphQLQuery<Variables: Encodable>: Encodable {
        let query: String
        let variables: Variables
    }

    /// Each MR's head pipeline status and approval state for a whole page,
    /// in one GraphQL query (REST would need a request per MR).
    func statusSummaries(repo: String, numbers: [Int]) async throws -> [Int: PullRequestStatusSummary] {
        guard !numbers.isEmpty else { return [:] }
        struct Variables: Encodable { let path: String; let iids: [String] }
        struct Response: Decodable {
            struct DataField: Decodable { let project: Project? }
            struct Project: Decodable { let mergeRequests: Connection? }
            struct Connection: Decodable { let nodes: [Node?] }
            struct Node: Decodable {
                struct Pipeline: Decodable { let status: String? }
                struct Approvers: Decodable { let nodes: [Login?]? }
                struct Login: Decodable { let username: String? }
                let iid: String
                let approved: Bool?
                let approvedBy: Approvers?
                let headPipeline: Pipeline?
            }
            struct GraphQLError: Decodable { let message: String? }
            let data: DataField?
            let errors: [GraphQLError]?
        }

        func run(withApprovals: Bool) async throws -> Response {
            let approvalFields = withApprovals ? "approved approvedBy { nodes { username } }" : ""
            let query = """
            query($path: ID!, $iids: [String!]) { project(fullPath: $path) {
              mergeRequests(iids: $iids, first: 100) { nodes { iid \(approvalFields) headPipeline { status } } } } }
            """
            return try await transport.send("POST", graphQLURL, body: GraphQLQuery(
                query: query, variables: Variables(path: repo, iids: numbers.map(String.init))))
        }

        var response = try await run(withApprovals: !approvalFieldsUnsupported)
        if response.data?.project == nil, !(response.errors ?? []).isEmpty, !approvalFieldsUnsupported {
            approvalFieldsUnsupported = true
            response = try await run(withApprovals: false)
        }

        var result: [Int: PullRequestStatusSummary] = [:]
        for case let node? in response.data?.project?.mergeRequests?.nodes ?? [] {
            guard let number = Int(node.iid) else { continue }
            let approverCount = node.approvedBy?.nodes?.compactMap { $0?.username }.count
            result[number] = PullRequestStatusSummary(
                checks: GitLabMapping.checkSummary(pipelineStatus: node.headPipeline?.status),
                review: GitLabMapping.reviewStatus(approved: node.approved, approverCount: approverCount))
        }
        return result
    }

    /// The jobs of the MR's latest pipeline (newest first in GitLab's list).
    /// Retried attempts are left out, as GitLab's own pipeline view does.
    /// Jobs are read from the pipeline's own project — for an MR from a
    /// fork that's the fork, and asking the MR's project for them 404s.
    func checks(repo: String, pullRequest: PullRequest) async throws -> [CheckRun] {
        let project = Self.project(repo)
        let pipelines: [GitLabPipeline] = try await get(
            "/projects/\(project)/merge_requests/\(pullRequest.number)/pipelines?per_page=1").value
        guard let latest = pipelines.first else { return [] }
        let owner = latest.projectID.map(String.init) ?? project
        let jobs: [GitLabJob] = try await get("/projects/\(owner)/pipelines/\(latest.id)/jobs?per_page=100").value
        // GitLab lists jobs newest-first; show them in pipeline order.
        return jobs.reversed().map(\.domain)
    }

    /// The conversation: human comments and thread replies, oldest first.
    /// System notes ("added 1 commit") and inline code comments are left
    /// out, matching what the GitHub module shows.
    func comments(repo: String, number: Int) async throws -> [Comment] {
        let notes: [GitLabNote] = try await get(
            "/projects/\(Self.project(repo))/merge_requests/\(number)/notes?sort=asc&order_by=created_at&per_page=50").value
        return notes.filter { $0.system != true && $0.type != "DiffNote" }.map(\.domain)
    }

    /// Requested reviewers with their own review state (GitLab 16+), plus
    /// approvals. Both best-effort: an older instance without the reviewers
    /// endpoint still gets approvals, and the requested list always shows.
    func reviewers(repo: String, pullRequest: PullRequest) async throws -> [Reviewer] {
        let base = "/projects/\(Self.project(repo))/merge_requests/\(pullRequest.number)"
        async let statesTask: (value: [GitLabReviewerState], hasNextPage: Bool)? = try? get("\(base)/reviewers")
        async let approvalsTask: (value: GitLabApprovals, hasNextPage: Bool)? = try? get("\(base)/approvals")
        let (states, approvals) = await (statesTask, approvalsTask)
        return GitLabMapping.reviewers(
            requested: pullRequest.requestedReviewers,
            states: states?.value,
            approvers: approvals?.value.approvedBy?.map(\.user.username) ?? [])
    }

    /// One page (100 files), like the GitHub module. `/diffs` is 15.7+;
    /// older instances only have the deprecated `/changes`.
    func files(repo: String, number: Int) async throws -> [PullRequestFileChange] {
        let base = "/projects/\(Self.project(repo))/merge_requests/\(number)"
        do {
            let diffs: [GitLabDiff] = try await get("\(base)/diffs?per_page=100").value
            return diffs.map(\.domain)
        } catch ProviderError.unexpectedStatus(_, 404) {
            let changes: GitLabChanges = try await get("\(base)/changes").value
            return changes.changes.prefix(100).map(\.domain)
        }
    }

    // MARK: - Writes

    /// Approve is its own endpoint; a review's text is posted as a comment
    /// alongside (GitLab has no review body). `.comment` is just the comment.
    func submitReview(repo: String, number: Int, decision: ReviewDecision, body: String?) async throws {
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch decision {
        case .approve:
            let _: Empty = try await transport.send(
                "POST", url("/projects/\(Self.project(repo))/merge_requests/\(number)/approve"), body: Empty())
            if !text.isEmpty { _ = try await addComment(repo: repo, number: number, body: text) }
        case .comment:
            guard !text.isEmpty else { throw ProviderError.validationFailed("Write a comment first.") }
            _ = try await addComment(repo: repo, number: number, body: text)
        case .requestChanges:
            throw ProviderError.validationFailed("GitLab doesn't support requesting changes here — leave a comment instead.")
        }
    }

    func addComment(repo: String, number: Int, body: String) async throws -> Comment {
        struct NewNote: Encodable { let body: String }
        let created: GitLabNote = try await transport.send(
            "POST", url("/projects/\(Self.project(repo))/merge_requests/\(number)/notes"), body: NewNote(body: body))
        return created.domain
    }

    func createFormData(repo: String) async throws -> CreatePullRequestFormData {
        async let info: (value: GitLabProjectInfo, hasNextPage: Bool) = get("/projects/\(Self.project(repo))")
        async let branches = branchNames(repo: repo)
        // Best-effort: a template that can't be fetched shouldn't block
        // opening an MR at all.
        async let templates = try? mergeRequestTemplates(repo: repo)
        let (projectInfo, names, templateList) = try await (info, branches, templates)
        return CreatePullRequestFormData(
            branches: names,
            defaultBranch: projectInfo.value.defaultBranch ?? names.first ?? "",
            templates: GitLabMapping.templates(projectDefault: projectInfo.value.mergeRequestsTemplate,
                                               templates: templateList ?? []))
    }

    func createPullRequest(repo: String, draft: CreatePullRequestDraft) async throws -> PullRequest {
        struct NewMergeRequest: Encodable {
            let title: String
            let sourceBranch: String
            let targetBranch: String
            let description: String?
            enum CodingKeys: String, CodingKey {
                case title, description
                case sourceBranch = "source_branch"
                case targetBranch = "target_branch"
            }
        }
        let created: GitLabMergeRequest = try await transport.send(
            "POST", url("/projects/\(Self.project(repo))/merge_requests"),
            body: NewMergeRequest(title: draft.title, sourceBranch: draft.sourceBranch,
                                  targetBranch: draft.targetBranch, description: draft.body))
        return created.domain
    }

    func rateLimitStatus() async -> RateLimitStatus? {
        await transport.lastKnownRateLimit
    }

    // MARK: - Token access

    /// `/personal_access_tokens/self` is GitLab 15.5+; an older instance
    /// (404) gets an honest "unknown" rather than a guess.
    func tokenAccess() async throws -> TokenAccess {
        do {
            let info: GitLabTokenInfo = try await get("/personal_access_tokens/self").value
            return GitLabMapping.tokenAccess(info)
        } catch ProviderError.unexpectedStatus(_, 404) {
            return GitLabMapping.tokenAccess(nil)
        } catch ProviderError.forbidden {
            return GitLabMapping.tokenAccess(nil)
        }
    }

    // MARK: - Notifications (To-Do List)

    /// Pending To-Do items — GitLab's inbox: review requests, mentions,
    /// assignments, failed pipelines. To-Dos are only ever things you're
    /// involved in, so `participatingOnly` changes nothing here.
    func notifications(participatingOnly: Bool) async throws -> InboxFetch {
        let todos: [GitLabTodo] = try await get("/todos?state=pending&per_page=50").value
        return InboxFetch(items: todos.map(\.domain), pollInterval: nil)
    }

    func markNotificationRead(id: String) async throws {
        try await transport.sendEmpty("POST", url("/todos/\(Self.query(id))/mark_as_done"))
    }

    func markAllNotificationsRead() async throws {
        try await transport.sendEmpty("POST", url("/todos/mark_as_done"))
    }

    // MARK: - Helpers

    /// Every branch, 100 at a time — capped so a project with thousands of
    /// stale branches can't turn one form open into dozens of requests.
    private func branchNames(repo: String) async throws -> [String] {
        var names: [String] = []
        for page in 1...10 {
            let result: (value: [GitLabBranch], hasNextPage: Bool) =
                try await get("/projects/\(Self.project(repo))/repository/branches?per_page=100&page=\(page)")
            names += result.value.map(\.name)
            if !result.hasNextPage { break }
        }
        return names
    }

    /// `.gitlab/merge_request_templates/*.md` — listed, then fetched (at
    /// most 10) in parallel, since the list carries names only.
    private func mergeRequestTemplates(repo: String) async throws -> [GitLabTemplate] {
        let project = Self.project(repo)
        let summaries: [GitLabTemplateSummary] = try await get("/projects/\(project)/templates/merge_requests?per_page=100").value
        return await withTaskGroup(of: GitLabTemplate?.self) { group in
            for summary in summaries.prefix(10) {
                let key = Self.query(summary.key ?? summary.name)
                group.addTask {
                    try? await self.get("/projects/\(project)/templates/merge_requests/\(key)").value
                }
            }
            var templates: [GitLabTemplate] = []
            for await template in group { if let template { templates.append(template) } }
            return templates
        }
    }
}
