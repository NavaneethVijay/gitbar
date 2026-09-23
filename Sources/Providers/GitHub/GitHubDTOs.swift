import Foundation

// GitHub REST/GraphQL wire types — private to the GitHub module. Mapped to
// `Domain` types in GitHubMapping.swift; nothing outside Providers/GitHub
// sees these.

struct GitHubUser: Decodable {
    let login: String
    let name: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }
}

struct GitHubRepo: Decodable {
    let fullName: String
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case isPrivate = "private"
    }
}

struct GitHubRepoInfo: Decodable {
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}

struct GitHubPullRequestTemplate: Decodable, Hashable {
    let filename: String?
    let body: String?
}

struct GitHubBranch: Decodable {
    let name: String
}

struct GitHubUserRef: Decodable {
    let login: String
}

struct GitHubPullRequest: Decodable {
    let id: Int  // decoded from `number` — see CodingKeys; GitHub's own `id` is an opaque internal id we don't need
    let title: String
    let user: GitHubUserRef
    let draft: Bool
    let requestedReviewers: [GitHubUserRef]
    let head: Ref
    let base: Ref
    let body: String?
    /// GitHub's own server-rendered HTML for `body` — only present when
    /// fetched with the `full` media type (see `GitHubAPIClient.fullMediaType`).
    /// `nil` on calls that didn't ask for it (this PR's description was never
    /// going to be shown from that call anyway).
    let bodyHTML: String?
    let createdAt: Date

    struct Ref: Decodable {
        let ref: String
        let sha: String?

        enum CodingKeys: String, CodingKey { case ref, sha }
    }

    enum CodingKeys: String, CodingKey {
        case id = "number"
        case title, user, draft, head, base, body
        case bodyHTML = "body_html"
        case requestedReviewers = "requested_reviewers"
        case createdAt = "created_at"
    }
}

struct GitHubIssue: Decodable {
    let id: Int  // decoded from `number`
    let title: String
    let user: GitHubUserRef
    let createdAt: Date
    /// Present (non-nil) only when the issues endpoint is actually returning
    /// a PR — GitHub's `/issues` list includes PRs too. `fetchOpenIssues`
    /// filters these out before returning.
    let pullRequest: PullRequestMarker?

    struct PullRequestMarker: Decodable {}

    enum CodingKeys: String, CodingKey {
        case id = "number"
        case title, user
        case createdAt = "created_at"
        case pullRequest = "pull_request"
    }
}

struct GitHubReview: Decodable {
    let user: GitHubUserRef
    let state: String  // "APPROVED" / "CHANGES_REQUESTED" / "COMMENTED" / "DISMISSED" / "PENDING"
    let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case user, state
        case submittedAt = "submitted_at"
    }
}

struct GitHubCheckRunList: Decodable {
    let checkRuns: [GitHubCheckRun]
    enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
}

struct GitHubCheckRun: Decodable {
    let name: String
    let status: String      // "queued" / "in_progress" / "completed"
    let conclusion: String? // "success" / "failure" / "neutral" / ... — nil until completed
    /// Where "Details" points to — usually the CI provider's own run page
    /// (a GitHub Actions run, a third-party CI dashboard, etc.), not
    /// anything GitHub itself renders.
    let detailsURL: URL?

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion
        case detailsURL = "details_url"
    }
}

struct GitHubComment: Decodable {
    let user: GitHubUserRef
    let body: String
    /// GitHub's own server-rendered HTML for `body` — see `GitHubPullRequest.bodyHTML`.
    let bodyHTML: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case user, body
        case bodyHTML = "body_html"
        case createdAt = "created_at"
    }
}

/// GitHub's own error payload shape on a rejected request, e.g.
/// `{"message": "Can not approve your own pull request"}`.
struct GitHubErrorBody: Decodable {
    let message: String
    let errors: [Detail]?

    /// Usually `{"resource", "code", "message"}`, but GitHub sometimes
    /// sends a bare string instead — accept either rather than failing
    /// the whole decode and losing the top-level message too.
    struct Detail: Decodable {
        let message: String?

        private enum CodingKeys: String, CodingKey { case message }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                message = text
            } else {
                message = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .message)
            }
        }
    }
}

struct GitHubNotification: Decodable {
    struct Subject: Decodable {
        let title: String
        /// API URL of the subject (PR, issue, release…); `nil` for some types.
        let url: URL?
        let type: String
    }
    struct Repository: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let subject: Subject
    let repository: Repository

    enum CodingKeys: String, CodingKey {
        case id, unread, reason, subject, repository
        case updatedAt = "updated_at"
    }
}
