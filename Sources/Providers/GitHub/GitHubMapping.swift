import Foundation

// GitHub wire types → neutral `Domain` types, plus GitHub's own HTTP
// conventions. Every GitHub-specific string state ("APPROVED", "SUCCESS",
// "completed", …) is interpreted here and nowhere else.

extension GitHubPullRequest {
    var domain: PullRequest {
        PullRequest(
            number: id, title: title, author: user.login,
            state: GitHubMapping.pullRequestState(rest: state, mergedAt: mergedAt), isDraft: draft,
            requestedReviewers: requestedReviewers.map(\.login),
            sourceBranch: head.ref, targetBranch: base.ref, headSHA: head.sha ?? "",
            body: body ?? "", createdAt: createdAt, webURL: htmlURL,
            diffURL: htmlURL?.appendingPathComponent("files"),
            labels: (labels ?? []).map(\.domain)
        )
    }
}

extension GitHubLabel {
    var domain: ItemLabel { ItemLabel(name: name, colorHex: color) }
}

extension GitHubPullRequestFile {
    var domain: PullRequestFileChange {
        PullRequestFileChange(filename: filename, status: GitHubMapping.fileStatus(status),
                              additions: additions, deletions: deletions, patch: patch,
                              previousFilename: previousFilename)
    }
}

extension GitHubIssue {
    var domain: Issue {
        Issue(number: id, title: title, author: user.login, createdAt: createdAt,
              labels: (labels ?? []).map(\.domain), assignees: (assignees ?? []).map(\.login),
              commentCount: comments ?? 0, webURL: htmlURL, body: body ?? "")
    }
}

extension GitHubCheckRun {
    var domain: CheckRun {
        CheckRun(name: name, status: GitHubMapping.checkRunStatus(status: status, conclusion: conclusion),
                 detailsURL: detailsURL)
    }
}

extension GitHubStatusContext {
    var domain: CheckRun {
        CheckRun(name: context, status: GitHubMapping.statusContextStatus(state),
                 detailsURL: targetURL.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                 summary: description.flatMap { $0.isEmpty ? nil : $0 })
    }
}

extension GitHubComment {
    var domain: Comment {
        Comment(author: user.login, body: body, createdAt: createdAt)
    }
}

extension GitHubMapping {
    static func codeReview(_ pr: GitHubGQLReviewPullRequest) -> CodeReview {
        let threads = pr.reviewThreads.nodes.map { thread -> ReviewThread in
            let anchor = thread.line.map { line in
                thread.diffSide == "LEFT" ? DiffAnchor(path: thread.path, oldLine: line, newLine: nil)
                                          : DiffAnchor(path: thread.path, oldLine: nil, newLine: line)
            }
            let notes = thread.comments.nodes.map {
                ReviewNote(id: $0.id, author: $0.author?.login ?? "ghost", body: $0.body,
                           createdAt: $0.createdAt, isPending: $0.state == "PENDING")
            }
            return ReviewThread(id: thread.id, path: thread.path, anchor: anchor, notes: notes,
                                isResolved: thread.isResolved,
                                canResolve: thread.isResolved ? thread.viewerCanUnresolve == true
                                                              : thread.viewerCanResolve == true)
        }
        return CodeReview(threads: threads, hasPendingReview: !pr.reviews.nodes.isEmpty)
    }
}

extension GitHubNotification {
    /// `webBase` is the instance's site root ("https://github.com").
    func domain(webBase: String) -> InboxItem {
        let repo = repository.fullName
        let lastComponent = subject.url?.lastPathComponent
        let number = lastComponent.flatMap(Int.init)
        let kind: InboxItem.Kind
        let path: String
        switch subject.type {
        case "PullRequest":
            kind = .pullRequest; path = number.map { "/pull/\($0)" } ?? "/pulls"
        case "Issue":
            kind = .issue; path = number.map { "/issues/\($0)" } ?? "/issues"
        case "Release":
            kind = .release; path = "/releases"
        case "Discussion":
            kind = .discussion; path = number.map { "/discussions/\($0)" } ?? "/discussions"
        case "Commit":
            kind = .commit; path = lastComponent.map { "/commit/\($0)" } ?? ""
        case "CheckSuite":
            kind = .checkSuite; path = "/actions"
        default:
            kind = .other(subject.type); path = ""
        }
        return InboxItem(
            id: id, repoPath: repo, title: subject.title, kind: kind,
            number: (kind == .pullRequest || kind == .issue || kind == .discussion) ? number : nil,
            reason: InboxItem.Reason(rawValue: reason) ?? .other,
            isUnread: unread, updatedAt: updatedAt,
            webURL: URL(string: "\(webBase)/\(repo)\(path)")
        )
    }
}

enum GitHubMapping {
    /// Classic tokens list their scopes in `X-OAuth-Scopes`; fine-grained
    /// ones (`github_pat_…`) don't, and can't read notifications at all.
    static func tokenAccess(scopesHeader: String?, isFineGrained: Bool) -> TokenAccess {
        guard let scopesHeader, !isFineGrained else {
            return TokenAccess(
                tokenKind: isFineGrained ? "Fine-grained token" : "Token",
                readRepositories: .unknown, writePullRequests: .unknown, notifications: .no,
                notes: [
                    "readRepositories": "Set per repository in the token's settings.",
                    "writePullRequests": "Needs \u{201C}Pull requests: Read and write\u{201D} on each repository.",
                    "notifications": "GitHub doesn't let fine-grained tokens read notifications. Use a classic token with the notifications (or repo) scope.",
                ])
        }
        let scopes = scopesHeader.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hasRepo = scopes.contains("repo")
        let hasPublicRepo = scopes.contains("public_repo")
        var notes: [String: String] = [:]
        if !hasRepo {
            notes["readRepositories"] = "Public repositories only — add the repo scope for private ones."
            notes["writePullRequests"] = hasPublicRepo
                ? "Public repositories only — add the repo scope for private ones."
                : "Add the repo (or public_repo) scope to review and open pull requests."
        }
        let notificationsOK = hasRepo || scopes.contains("notifications")
        if !notificationsOK { notes["notifications"] = "Add the notifications scope to this token." }
        return TokenAccess(
            tokenKind: "Classic token",
            readRepositories: .yes,
            writePullRequests: (hasRepo || hasPublicRepo) ? .yes : .no,
            notifications: notificationsOK ? .yes : .no,
            notes: notes, scopes: scopes)
    }

    /// GitHub tracks "who's asked to review" and "who's reviewed" as two
    /// separate lists that can both mention the same person — someone can be
    /// re-requested after already approving once, in which case GitHub's own
    /// UI shows them as pending again, not still-approved. This reduces both
    /// lists to one state per person, with `requested` taking priority for
    /// exactly that reason.
    static func reviewers(requested: [String], reviews: [GitHubReview]) -> [Reviewer] {
        var latestByReviewer: [String: GitHubReview] = [:]
        for review in reviews where review.state != "DISMISSED" && review.state != "PENDING" {
            if let existing = latestByReviewer[review.user.login],
               let existingDate = existing.submittedAt, let newDate = review.submittedAt,
               existingDate > newDate { continue }
            latestByReviewer[review.user.login] = review
        }

        // Requested reviewers first (in their given order), then anyone
        // who's reviewed but isn't currently requested — order is stable
        // rather than dictionary-random.
        var order: [String] = []
        var seen = Set<String>()
        for login in requested where !seen.contains(login) { order.append(login); seen.insert(login) }
        for login in latestByReviewer.keys.sorted() where !seen.contains(login) { order.append(login); seen.insert(login) }

        return order.map { login in
            let state: ReviewState
            if requested.contains(login) {
                state = .pending
            } else {
                switch latestByReviewer[login]?.state {
                case "APPROVED": state = .approved
                case "CHANGES_REQUESTED": state = .changesRequested
                default: state = .commented
                }
            }
            let latest = latestByReviewer[login]
            return Reviewer(login: login, state: state, body: latest?.body)
        }
    }

    /// GitHub's file-status strings on a PR's changed-files list.
    static func fileStatus(_ raw: String) -> FileChangeStatus {
        switch raw {
        case "added": return .added
        case "removed": return .removed
        case "renamed": return .renamed
        case "copied": return .copied
        case "changed": return .changed
        case "unchanged": return .unchanged
        default: return .modified
        }
    }

    /// REST reports merged PRs as "closed" plus a `merged_at` timestamp.
    static func pullRequestState(rest state: String?, mergedAt: Date?) -> PullRequestState {
        if mergedAt != nil { return .merged }
        return state == "closed" ? .closed : .open
    }

    /// GraphQL's `PullRequestState` enum.
    static func pullRequestState(graphQL state: String?) -> PullRequestState {
        switch state {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .open
        }
    }

    /// GraphQL's `reviewDecision` — `nil` when the repo requires no review
    /// and nobody has given a verdict.
    static func reviewStatus(_ decision: String?) -> PullRequestReviewStatus? {
        switch decision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return nil
        }
    }

    /// A check run's `status` ("queued"/"in_progress"/"completed"/"waiting"/
    /// "requested"/"pending") and, once completed, its `conclusion`.
    /// "waiting" is a job held for a deployment approval — nothing runs until
    /// someone approves, so it isn't drawn as running.
    static func checkRunStatus(status: String, conclusion: String?) -> CheckRunStatus {
        if status == "waiting" { return .pending }
        guard status == "completed" else { return .running }
        switch conclusion {
        case "success": return .passed
        case "skipped": return .skipped
        case "neutral": return .neutral
        default: return .failed  // failure, cancelled, timed_out, action_required, stale, startup_failure
        }
    }

    /// `statusCheckRollup.state` — covers check runs and legacy statuses.
    /// The rollup says PENDING for anything unfinished, including a commit
    /// status that waits on a person forever (e.g. "changes must be accepted
    /// as baselines") after every Actions job — skipped ones included — is
    /// done. So it only counts as running while a check run actually is
    /// (`activeCheckRuns`, from `checkRunCountsByState`).
    static func checkSummary(rollupState: String?, activeCheckRuns: Int) -> CheckSummary {
        switch rollupState {
        case "SUCCESS": return .passed
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return activeCheckRuns > 0 ? .running : .pending
        case nil: return .none
        case let other?: return .other(other.lowercased())
        }
    }

    /// The default branch's CI from both of GitHub's systems: check runs
    /// and legacy commit statuses (`nil` = that call failed).
    static func branchChecks(runs: [CheckRunStatus]?, combined: GitHubCombinedStatus?) -> CheckSummary? {
        guard runs != nil || combined != nil else { return nil }
        var statuses = runs ?? []
        if let combined, combined.totalCount > 0 {
            switch combined.state {
            case "success": statuses.append(.passed)
            case "pending": statuses.append(.pending)
            default: statuses.append(.failed)
            }
        }
        return .combining(statuses)
    }

    /// `checkRunCountsByState` states that mean a job is queued or running.
    static let activeCheckRunStates: Set<String> = ["IN_PROGRESS", "QUEUED", "PENDING", "REQUESTED"]

    /// A legacy commit status (`/commits/{sha}/status`) as a check row. A
    /// pending status can't be told apart from one waiting on a person, so
    /// it's drawn as pending, not running.
    static func statusContextStatus(_ state: String) -> CheckRunStatus {
        switch state {
        case "success": return .passed
        case "pending": return .pending
        default: return .failed  // failure, error
        }
    }

    static func reviewEvent(_ decision: ReviewDecision) -> String {
        switch decision {
        case .approve: return "APPROVE"
        case .requestChanges: return "REQUEST_CHANGES"
        case .comment: return "COMMENT"
        }
    }

    /// Non-empty templates, the plain `pull_request_template.md` first —
    /// that's the one github.com itself prefills.
    static func templates(_ templates: [GitHubPullRequestTemplate]) -> [PullRequestTemplate] {
        let usable = templates.compactMap { template -> PullRequestTemplate? in
            guard let body = template.body, !body.isEmpty else { return nil }
            return PullRequestTemplate(name: template.filename ?? "Template", body: body)
        }
        let preferred = usable.filter { $0.name.lowercased().hasSuffix("pull_request_template.md") }
        return preferred + usable.filter { !preferred.contains($0) }
    }

    // MARK: - HTTP conventions

    /// GitHub's non-2xx semantics beyond the shared defaults.
    @Sendable static func classifyError(_ response: HTTPURLResponse, _ data: Data) -> ProviderError? {
        switch response.statusCode {
        case 403:
            // Only a rate limit when GitHub says so: `Retry-After` (secondary
            // limit) or an exhausted primary quota. Otherwise it's a permission
            // problem (missing scope, fine-grained token) — not worth a retry.
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            if retryAfter != nil || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                return .rateLimited(.github, retryAfter: retryAfter)
            }
            let message = (try? JSONDecoder().decode(GitHubErrorBody.self, from: data))?.message
            return .forbidden(.github, message)
        case 422:
            // A write GitHub rejected on its merits (self-approval, no commits
            // between branches, a PR already open…) — worth showing verbatim.
            // The top-level message is often just "Validation Failed"; the
            // specific reason is in `errors`.
            guard let body = try? JSONDecoder().decode(GitHubErrorBody.self, from: data) else { return nil }
            let details = (body.errors ?? []).compactMap(\.message)
            return .validationFailed(details.isEmpty ? body.message : details.joined(separator: "\n"))
        default:
            return nil
        }
    }

    @Sendable static func rateLimit(_ response: HTTPURLResponse) -> RateLimitStatus? {
        guard let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
              let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        return RateLimitStatus(remaining: remaining, reset: Date(timeIntervalSince1970: reset))
    }
}
