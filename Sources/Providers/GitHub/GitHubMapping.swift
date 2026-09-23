import Foundation

// GitHub wire types → neutral `Domain` types, plus GitHub's own HTTP
// conventions. Every GitHub-specific string state ("APPROVED", "SUCCESS",
// "completed", …) is interpreted here and nowhere else.

extension GitHubPullRequest {
    var domain: PullRequest {
        PullRequest(
            number: id, title: title, author: user.login, isDraft: draft,
            requestedReviewers: requestedReviewers.map(\.login),
            sourceBranch: head.ref, targetBranch: base.ref, headSHA: head.sha ?? "",
            body: body ?? "", bodyHTML: bodyHTML, createdAt: createdAt
        )
    }
}

extension GitHubIssue {
    var domain: Issue {
        Issue(number: id, title: title, author: user.login, createdAt: createdAt)
    }
}

extension GitHubCheckRun {
    var domain: CheckRun {
        CheckRun(name: name, passed: conclusion == "success", isRunning: status != "completed", detailsURL: detailsURL)
    }
}

extension GitHubComment {
    var domain: Comment {
        Comment(author: user.login, body: body, bodyHTML: bodyHTML, createdAt: createdAt)
    }
}

enum GitHubMapping {
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
            return Reviewer(login: login, state: state)
        }
    }

    /// `statusCheckRollup.state` — covers check runs and legacy statuses.
    static func checkSummary(rollupState: String?) -> CheckSummary {
        switch rollupState {
        case "SUCCESS": return .passed
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .running
        case nil: return .none
        case let other?: return .other(other.lowercased())
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
            // A `Retry-After` header means the secondary (abuse-detection)
            // limit; without one, the primary hourly quota.
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(.github, retryAfter: retryAfter)
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
