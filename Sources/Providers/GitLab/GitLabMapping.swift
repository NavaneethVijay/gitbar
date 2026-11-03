import Foundation

// GitLab wire types → neutral `Domain` types, plus GitLab's own HTTP
// conventions. Every GitLab-specific string state ("opened", "success",
// "requested_changes", "review_requested", …) is interpreted here and
// nowhere else.

extension GitLabMergeRequest {
    var domain: PullRequest {
        PullRequest(
            number: iid, title: title, author: author?.username ?? "",
            state: GitLabMapping.mergeRequestState(state),
            isDraft: draft ?? workInProgress ?? false,
            requestedReviewers: (reviewers ?? []).map(\.username),
            sourceBranch: sourceBranch, targetBranch: targetBranch, headSHA: sha ?? "",
            body: description ?? "", createdAt: createdAt, webURL: webURL,
            diffURL: webURL?.appendingPathComponent("diffs"))
    }
}

extension GitLabIssue {
    var domain: Issue {
        Issue(number: iid, title: title, author: author?.username ?? "", createdAt: createdAt)
    }
}

extension GitLabJob {
    var domain: CheckRun {
        CheckRun(name: name, status: GitLabMapping.jobStatus(status, allowFailure: allowFailure ?? false),
                 detailsURL: webURL)
    }
}

extension GitLabNote {
    var domain: Comment {
        Comment(author: author?.username ?? "", body: body, createdAt: createdAt)
    }
}

extension GitLabDiff {
    var domain: PullRequestFileChange {
        let status: FileChangeStatus
        if newFile == true { status = .added }
        else if deletedFile == true { status = .removed }
        else if renamedFile == true { status = .renamed }
        else { status = .modified }
        let patch = (diff?.isEmpty == false && tooLarge != true) ? diff : nil
        let (additions, deletions) = GitLabMapping.lineCounts(patch)
        return PullRequestFileChange(filename: newPath, status: status,
                                     additions: additions, deletions: deletions, patch: patch)
    }
}

extension GitLabTodo {
    var domain: InboxItem {
        let kind: InboxItem.Kind
        switch targetType {
        case "MergeRequest": kind = .pullRequest
        case "Issue": kind = .issue
        case "Commit": kind = .commit
        default: kind = .other(targetType)
        }
        let title = target?.title ?? body ?? targetType
        return InboxItem(
            id: String(id), repoPath: project?.pathWithNamespace ?? "", title: title, kind: kind,
            number: (kind == .pullRequest || kind == .issue) ? target?.iid : nil,
            reason: GitLabMapping.todoReason(actionName),
            isUnread: state != "done", updatedAt: updatedAt ?? createdAt,
            webURL: targetURL)
    }
}

enum GitLabMapping {
    /// "opened" / "closed" / "merged" / "locked" (a transient state while
    /// merging) — REST and GraphQL (`opened`, uppercase-insensitive) alike.
    static func mergeRequestState(_ state: String?) -> PullRequestState {
        switch state?.lowercased() {
        case "merged": return .merged
        case "closed": return .closed
        default: return .open
        }
    }

    /// A pipeline's overall status (REST lowercase, GraphQL uppercase).
    static func checkSummary(pipelineStatus: String?) -> CheckSummary {
        guard let status = pipelineStatus?.lowercased() else { return .none }
        switch status {
        case "success": return .passed
        case "failed": return .failing
        case "created", "waiting_for_resource", "preparing", "waiting_for_callback",
             "pending", "running", "scheduled", "canceling":
            return .running
        case "canceled": return .other("canceled")
        default: return .other(status.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// One job's status. A failed job marked `allow_failure` doesn't fail
    /// the pipeline, so it reads as neutral rather than failed; a manual job
    /// that nobody started hasn't run and won't on its own.
    static func jobStatus(_ status: String, allowFailure: Bool) -> CheckRunStatus {
        switch status {
        case "success": return .passed
        case "failed": return allowFailure ? .neutral : .failed
        case "canceled": return .failed
        case "skipped": return .skipped
        case "manual": return .neutral
        default: return .running  // created, pending, running, preparing, scheduled, waiting_for_resource, canceling
        }
    }

    /// GitLab keeps "who's asked to review" (with a per-reviewer state on
    /// 16+) and "who's approved" separately. One state per person: a
    /// reviewer's own state when known, approval otherwise; approvers who
    /// weren't requested come after the requested ones.
    static func reviewers(requested: [String], states: [GitLabReviewerState]?, approvers: [String]) -> [Reviewer] {
        let stateByLogin = Dictionary((states ?? []).map { ($0.user.username, $0.state ?? "") },
                                      uniquingKeysWith: { first, _ in first })
        let approverSet = Set(approvers)
        var order: [String] = []
        var seen = Set<String>()
        for login in requested + (states ?? []).map(\.user.username) + approvers where !seen.contains(login) {
            order.append(login); seen.insert(login)
        }
        return order.map { login in
            let state: ReviewState
            switch stateByLogin[login] {
            case "approved": state = .approved
            case "requested_changes": state = .changesRequested
            case "reviewed": state = approverSet.contains(login) ? .approved : .commented
            case nil:
                state = approverSet.contains(login) ? .approved : .pending
            default:  // unreviewed, review_started, unapproved
                state = approverSet.contains(login) ? .approved : .pending
            }
            return Reviewer(login: login, state: state, body: nil)
        }
    }

    /// The MR-level verdict from GraphQL: `approved` is true whenever the
    /// approval rules are met — including when there are none — so it only
    /// counts as "Approved" once somebody actually approved.
    static func reviewStatus(approved: Bool?, approverCount: Int?) -> PullRequestReviewStatus? {
        switch approved {
        case false?: return .reviewRequired
        case true? where (approverCount ?? 0) > 0: return .approved
        default: return nil
        }
    }

    static func todoReason(_ action: String) -> InboxItem.Reason {
        switch action {
        case "review_requested", "approval_required": return .reviewRequested
        case "mentioned", "directly_addressed": return .mention
        case "assigned": return .assign
        case "build_failed": return .ciActivity
        case "unmergeable", "merge_train_removed": return .stateChange
        case "review_submitted": return .author
        case "marked": return .manual
        default: return .other
        }
    }

    /// GitLab's diffs don't carry line counts — count the hunks' own +/− lines.
    static func lineCounts(_ patch: String?) -> (additions: Int, deletions: Int) {
        guard let patch else { return (0, 0) }
        var additions = 0, deletions = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    /// Non-empty templates in the order GitLab's own form would pick them:
    /// the project's configured default description, then a template named
    /// "Default" (which GitLab preselects), then the rest by name.
    static func templates(projectDefault: String?, templates: [GitLabTemplate]) -> [PullRequestTemplate] {
        var result: [PullRequestTemplate] = []
        if let projectDefault, !projectDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(PullRequestTemplate(name: "Project default", body: projectDefault))
        }
        let usable = templates.compactMap { template -> PullRequestTemplate? in
            guard let body = template.content, !body.isEmpty else { return nil }
            return PullRequestTemplate(name: template.name, body: body)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let preferred = usable.filter { $0.name.lowercased() == "default" }
        return result + preferred + usable.filter { !preferred.contains($0) }
    }

    /// Personal, project and group access tokens all report their scopes
    /// at `/personal_access_tokens/self`. `read_api` covers everything the
    /// app reads (including the To-Do List); writes need `api`.
    static func tokenAccess(_ info: GitLabTokenInfo?) -> TokenAccess {
        guard let info else {
            return TokenAccess(
                tokenKind: "Access token",
                readRepositories: .unknown, writePullRequests: .unknown, notifications: .unknown,
                notes: [
                    "readRepositories": "This GitLab version doesn't report token scopes. Needs read_api (or api).",
                    "writePullRequests": "Needs the api scope to comment, approve and open merge requests.",
                    "notifications": "Your To-Do List needs read_api (or api); marking items done needs api.",
                ])
        }
        let scopes = info.scopes
        let hasAPI = scopes.contains("api")
        let canRead = hasAPI || scopes.contains("read_api")
        var notes: [String: String] = [:]
        if !canRead {
            notes["readRepositories"] = "Add the read_api (or api) scope to this token."
            notes["notifications"] = "Add the read_api (or api) scope to read your To-Do List."
        } else if !hasAPI {
            notes["notifications"] = "Read-only — add the api scope to mark To-Do items done."
        }
        if !hasAPI { notes["writePullRequests"] = "Add the api scope to comment, approve and open merge requests." }
        return TokenAccess(
            tokenKind: "Personal access token",
            readRepositories: canRead ? .yes : .no,
            writePullRequests: hasAPI ? .yes : .no,
            notifications: canRead ? .yes : .no,
            notes: notes, scopes: scopes)
    }

    // MARK: - HTTP conventions

    static func errorMessage(_ data: Data) -> String? {
        guard let text = (try? JSONDecoder().decode(GitLabErrorBody.self, from: data))?.text,
              !text.isEmpty else { return nil }
        return text
    }

    /// GitLab's non-2xx semantics beyond the shared defaults.
    @Sendable static func classifyError(_ response: HTTPURLResponse, _ data: Data) -> ProviderError? {
        let message = errorMessage(data)
        switch response.statusCode {
        case 401:
            // Approving answers 401 when *this user* may not approve (own MR,
            // already approved, not eligible) — a refusal, not a bad token.
            let path = response.url?.path ?? ""
            if path.hasSuffix("/approve") || path.hasSuffix("/unapprove") {
                return .validationFailed(message ?? "You can't approve this merge request.")
            }
            return nil
        case 403:
            return .forbidden(.gitlab, message)
        case 400, 405, 409, 422:
            // A write GitLab rejected on its merits (an MR already open for
            // the branch, no changes between branches…) — shown verbatim.
            return message.map { .validationFailed($0) }
        default:
            return nil
        }
    }

    /// Sent by GitLab.com (and self-managed instances with rate limits on).
    @Sendable static func rateLimit(_ response: HTTPURLResponse) -> RateLimitStatus? {
        guard let remaining = response.value(forHTTPHeaderField: "RateLimit-Remaining").flatMap(Int.init),
              let reset = response.value(forHTTPHeaderField: "RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        return RateLimitStatus(remaining: remaining, reset: Date(timeIntervalSince1970: reset))
    }

    /// `X-Next-Page` (empty on the last page), else the `Link` header —
    /// GitLab omits `X-Next-Page` past 10,000 results but keeps `Link`.
    @Sendable static func hasNextPage(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        if let next = response.value(forHTTPHeaderField: "X-Next-Page") {
            return !next.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return HTTPTransport.linkHeaderHasNext(response)
    }
}
