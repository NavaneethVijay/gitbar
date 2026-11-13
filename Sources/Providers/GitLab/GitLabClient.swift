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
        var path = "/projects/\(Self.project(repo))/merge_requests?state=opened&order_by=created_at&sort=desc&with_labels_details=true&per_page=\(perPage)&page=\(page)"
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
    private func issues(repo: String, perPage: Int, page: Int, assignee: String? = nil) async throws -> Page<Issue> {
        var path = "/projects/\(Self.project(repo))/issues?state=opened&order_by=created_at&sort=desc&with_labels_details=true&per_page=\(perPage)&page=\(page)"
        if let assignee { path += "&assignee_username=\(Self.query(assignee))" }
        do {
            let result: (value: [GitLabIssue], hasNextPage: Bool) = try await get(path)
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

    func issues(repo: String, page: Int, assignee: String) async throws -> Page<Issue> {
        try await issues(repo: repo, perPage: 20, page: page, assignee: assignee)
    }

    func issue(repo: String, number: Int) async throws -> Issue {
        let issue: GitLabIssue = try await get("/projects/\(Self.project(repo))/issues/\(number)").value
        return issue.domain
    }

    /// The project, its newest release and the default branch's latest
    /// pipeline — plain GETs, all ETag-cacheable. Releases and pipelines are
    /// best-effort (either feature can be turned off for a project).
    func overview(repo: String) async throws -> RepoOverview {
        let project = Self.project(repo)
        let info: GitLabProjectInfo = try await get("/projects/\(project)").value
        let branch = info.defaultBranch ?? "main"
        async let releasesTask: (value: [GitLabRelease], hasNextPage: Bool)? = try? get("/projects/\(project)/releases?per_page=1")
        async let pipelinesTask: (value: [GitLabPipeline], hasNextPage: Bool)? =
            try? get("/projects/\(project)/pipelines?ref=\(Self.query(branch))&per_page=1")
        let (releases, pipelines) = await (releasesTask, pipelinesTask)
        return RepoOverview(
            description: info.description,
            stars: info.starCount,
            defaultBranch: branch,
            defaultBranchChecks: pipelines.map { GitLabMapping.checkSummary(pipelineStatus: $0.value.first?.status) },
            latestRelease: releases?.value.first.map { RepoOverview.Release(tag: $0.tagName, publishedAt: $0.releasedAt) },
            webURL: info.webURL)
    }

    /// Human comments only — system notes ("changed the label") left out.
    func issueComments(repo: String, number: Int) async throws -> [Comment] {
        let notes: [GitLabNote] = try await get(
            "/projects/\(Self.project(repo))/issues/\(number)/notes?sort=asc&order_by=created_at&per_page=50").value
        return notes.filter { $0.system != true }.map(\.domain)
    }

    func addIssueComment(repo: String, number: Int, body: String) async throws -> Comment {
        struct NewNote: Encodable { let body: String }
        let created: GitLabNote = try await transport.send(
            "POST", url("/projects/\(Self.project(repo))/issues/\(number)/notes"), body: NewNote(body: body))
        return created.domain
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

    /// Diff discussions (one page of 100) plus your draft notes — GitLab's
    /// pending review. Drafts are best-effort: an instance without the
    /// draft-notes API just shows posted threads.
    func codeReview(repo: String, number: Int) async throws -> CodeReview {
        let base = "/projects/\(Self.project(repo))/merge_requests/\(number)"
        async let draftsTask: (value: [GitLabDraftNote], hasNextPage: Bool)? = try? get("\(base)/draft_notes?per_page=100")
        let discussions: [GitLabDiscussion] = try await get("\(base)/discussions?per_page=100").value
        let drafts = await draftsTask?.value ?? []
        return GitLabMapping.codeReview(discussions: discussions, drafts: drafts)
    }

    // MARK: - Writes

    /// "Submit review": publishes your draft notes, then the summary as a
    /// comment (GitLab reviews have no body of their own), then approves.
    func submitReview(repo: String, number: Int, decision: ReviewDecision, body: String?) async throws {
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decision == .requestChanges {
            throw ProviderError.validationFailed("GitLab doesn't support requesting changes here — leave a comment instead.")
        }
        let base = "/projects/\(Self.project(repo))/merge_requests/\(number)"
        let drafts = (try? await get("\(base)/draft_notes?per_page=100").value as [GitLabDraftNote]) ?? []
        if decision == .comment, text.isEmpty, drafts.isEmpty {
            throw ProviderError.validationFailed("Write a comment first.")
        }
        if !drafts.isEmpty {
            try await transport.sendEmpty("POST", url("\(base)/draft_notes/bulk_publish"))
        }
        if !text.isEmpty { _ = try await addComment(repo: repo, number: number, body: text) }
        if decision == .approve {
            let _: Empty = try await transport.send("POST", url("\(base)/approve"), body: Empty())
        }
    }

    /// `pending`: a draft note ("Start a review" / "Add to review");
    /// otherwise a diff discussion, posted now ("Add comment now"). Both are
    /// pinned to the MR's current diff (`diff_refs`).
    func addReviewComment(repo: String, pullRequest: PullRequest, comment: NewReviewComment, pending: Bool) async throws {
        let base = "/projects/\(Self.project(repo))/merge_requests/\(pullRequest.number)"
        let mr: GitLabMergeRequest = try await get(base).value
        guard let refs = mr.diffRefs else {
            throw ProviderError.validationFailed("This GitLab version doesn't report the diff's commits — can't place line comments.")
        }
        let anchor = comment.anchor
        let position = GitLabPosition(
            baseSHA: refs.baseSHA, startSHA: refs.startSHA, headSHA: refs.headSHA,
            oldPath: anchor.oldPath ?? anchor.path, newPath: anchor.path,
            oldLine: anchor.oldLine, newLine: anchor.newLine)
        if pending {
            struct NewDraft: Encodable { let note: String; let position: GitLabPosition }
            let _: GitLabDraftNote = try await transport.send(
                "POST", url("\(base)/draft_notes"), body: NewDraft(note: comment.body, position: position))
        } else {
            struct NewDiscussion: Encodable { let body: String; let position: GitLabPosition }
            let _: GitLabDiscussion = try await transport.send(
                "POST", url("\(base)/discussions"), body: NewDiscussion(body: comment.body, position: position))
        }
    }

    func updatePendingComment(repo: String, number: Int, noteID: String, body: String) async throws {
        struct Update: Encodable { let note: String }
        let _: GitLabDraftNote = try await transport.send(
            "PUT", url("/projects/\(Self.project(repo))/merge_requests/\(number)/draft_notes/\(noteID)"),
            body: Update(note: body))
    }

    func deletePendingComment(repo: String, number: Int, noteID: String) async throws {
        try await transport.sendEmpty("DELETE", url("/projects/\(Self.project(repo))/merge_requests/\(number)/draft_notes/\(noteID)"))
    }

    /// GitLab has no "discard review" call — each draft is deleted.
    func discardPendingReview(repo: String, number: Int) async throws {
        let base = "/projects/\(Self.project(repo))/merge_requests/\(number)"
        let drafts: [GitLabDraftNote] = try await get("\(base)/draft_notes?per_page=100").value
        for draft in drafts {
            try await transport.sendEmpty("DELETE", url("\(base)/draft_notes/\(draft.id)"))
        }
    }

    func replyToReviewThread(repo: String, number: Int, threadID: String, body: String) async throws {
        struct NewNote: Encodable { let body: String }
        let _: GitLabNote = try await transport.send(
            "POST", url("/projects/\(Self.project(repo))/merge_requests/\(number)/discussions/\(threadID)/notes"),
            body: NewNote(body: body))
    }

    func setReviewThreadResolved(repo: String, number: Int, threadID: String, resolved: Bool) async throws {
        struct Update: Encodable { let resolved: Bool }
        let _: GitLabDiscussion = try await transport.send(
            "PUT", url("/projects/\(Self.project(repo))/merge_requests/\(number)/discussions/\(threadID)"),
            body: Update(resolved: resolved))
    }

    func updatePullRequest(repo: String, number: Int, edit: PullRequestEdit) async throws -> PullRequest {
        struct Update: Encodable {
            let title: String?
            let description: String?
            let targetBranch: String?
            enum CodingKeys: String, CodingKey {
                case title, description
                case targetBranch = "target_branch"
            }
        }
        let updated: GitLabMergeRequest = try await transport.send(
            "PUT", url("/projects/\(Self.project(repo))/merge_requests/\(number)"),
            body: Update(title: edit.title, description: edit.body, targetBranch: edit.targetBranch))
        return updated.domain
    }

    func branches(repo: String) async throws -> [String] {
        try await branchNames(repo: repo)
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
