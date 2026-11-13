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
    let description: String?
    let stargazersCount: Int?
    let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case description
        case htmlURL = "html_url"
        case defaultBranch = "default_branch"
        case stargazersCount = "stargazers_count"
    }
}

struct GitHubLabel: Decodable {
    let name: String
    /// Hex without `#`, e.g. "d73a4a".
    let color: String?
}

struct GitHubRelease: Decodable {
    let tagName: String
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
    }
}

/// Legacy commit statuses, combined — `/commits/{ref}/status`.
struct GitHubCombinedStatus: Decodable {
    /// "success" / "failure" / "error" / "pending" (also when there are none).
    let state: String
    let totalCount: Int
    /// The latest status per context; optional so a body cached before this
    /// field was read still decodes.
    let statuses: [GitHubStatusContext]?

    enum CodingKeys: String, CodingKey {
        case state, statuses
        case totalCount = "total_count"
    }
}

/// One legacy commit status (third-party CI, visual review, deploy previews).
struct GitHubStatusContext: Decodable {
    let context: String
    let state: String       // "success" / "pending" / "failure" / "error"
    let description: String?
    /// A string, not `URL`: GitHub sends "" when there's no link, which
    /// `URL` refuses to decode.
    let targetURL: String?

    enum CodingKeys: String, CodingKey {
        case context, state, description
        case targetURL = "target_url"
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
    /// "open" / "closed" — a merged PR is "closed" with `mergedAt` set.
    let state: String?
    let mergedAt: Date?
    let draft: Bool
    let requestedReviewers: [GitHubUserRef]
    let head: Ref
    let base: Ref
    let body: String?
    let createdAt: Date
    let htmlURL: URL?
    let labels: [GitHubLabel]?

    struct Ref: Decodable {
        let ref: String
        let sha: String?

        enum CodingKeys: String, CodingKey { case ref, sha }
    }

    enum CodingKeys: String, CodingKey {
        case id = "number"
        case title, user, state, draft, head, base, body, labels
        case mergedAt = "merged_at"
        case requestedReviewers = "requested_reviewers"
        case createdAt = "created_at"
        case htmlURL = "html_url"
    }
}

struct GitHubIssue: Decodable {
    let id: Int  // decoded from `number`
    let title: String
    let user: GitHubUserRef
    let createdAt: Date
    let labels: [GitHubLabel]?
    let assignees: [GitHubUserRef]?
    let comments: Int?
    let htmlURL: URL?
    let body: String?
    /// Present (non-nil) only when the issues endpoint is actually returning
    /// a PR — GitHub's `/issues` list includes PRs too. `fetchOpenIssues`
    /// filters these out before returning.
    let pullRequest: PullRequestMarker?

    struct PullRequestMarker: Decodable {}

    enum CodingKeys: String, CodingKey {
        case id = "number"
        case title, user, labels, assignees, comments, body
        case createdAt = "created_at"
        case htmlURL = "html_url"
        case pullRequest = "pull_request"
    }
}

struct GitHubReview: Decodable {
    let id: Int
    let user: GitHubUserRef
    let state: String  // "APPROVED" / "CHANGES_REQUESTED" / "COMMENTED" / "DISMISSED" / "PENDING"
    let body: String?
    let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, user, state, body
        case submittedAt = "submitted_at"
    }
}

struct GitHubPullRequestFile: Decodable {
    let filename: String
    let status: String  // "added" / "removed" / "modified" / "renamed" / "copied" / "changed" / "unchanged"
    let additions: Int
    let deletions: Int
    /// Unified-diff hunks for this file. GitHub leaves it out for binary
    /// files and for diffs too large to show.
    let patch: String?
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
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case user, body
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
