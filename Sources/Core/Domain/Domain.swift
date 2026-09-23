import Foundation

// Provider-neutral data. A provider module (`Sources/Providers/*`) maps its
// own wire format into these; everything above the module — the store, the
// display mapper, every view — only ever sees these types.

/// One repo on one connected account. `path` is the provider's own full
/// path — "owner/repo" on GitHub, "group/subgroup/project" on GitLab — and
/// is only unique *within* an account, which is why the account is part of
/// the identity: the same path favorited under two accounts (or two
/// providers) is two different repos.
struct RepoRef: Hashable, Codable, Sendable {
    let accountID: UUID
    let path: String

    /// The last path component — what the UI shows as the repo's name.
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// One pull/merge request, addressed by its repo and per-repo number.
struct PRRef: Hashable, Sendable {
    let repo: RepoRef
    let number: Int
}

/// Who a token belongs to, from the provider's "current user" endpoint.
struct AccountProfile: Sendable {
    let login: String
    let name: String?
    let avatarURL: URL?
}

/// A repo the account can see — the Settings favorites picker's rows.
struct RemoteRepo: Identifiable, Sendable {
    let path: String
    let isPrivate: Bool
    var id: String { path }
}

struct PullRequest: Equatable, Sendable {
    /// Per-repo number (GitHub `#12`, GitLab `!12`) — also the id the store
    /// and the UI key rows by.
    let number: Int
    let title: String
    let author: String
    let isDraft: Bool
    /// Logins currently asked to review.
    let requestedReviewers: [String]
    let sourceBranch: String
    let targetBranch: String
    /// The source branch's head commit — what CI results hang off.
    let headSHA: String
    let body: String
    /// The provider's own server-rendered HTML for `body`, when it offers
    /// one — rendered by `RenderedBodyText`, falling back to `body`.
    let bodyHTML: String?
    let createdAt: Date
}

struct Issue: Equatable, Sendable {
    let number: Int
    let title: String
    let author: String
    let createdAt: Date
}

/// One PR's combined CI result — the single line on a PR row.
enum CheckSummary: Equatable, Sendable {
    case passed
    case failing
    case running
    /// The head commit has no CI configured at all.
    case none
    /// A state the provider reported that doesn't fit the above.
    case other(String)
}

/// One individual CI job/check on a PR — the PR screen's Checks list.
struct CheckRun: Equatable, Sendable {
    let name: String
    let passed: Bool
    let isRunning: Bool
    let detailsURL: URL?
}

enum ReviewState: Equatable, Sendable {
    /// Requested and hasn't reviewed yet — also a past reviewer who has
    /// been re-requested since (GitHub's "awaiting requested review").
    case pending
    case approved
    case changesRequested
    case commented
}

/// One person's current standing on a PR — the module reduces its own
/// review history/requests to exactly one of these per person.
struct Reviewer: Equatable, Sendable {
    let login: String
    let state: ReviewState
}

struct Comment: Equatable, Sendable {
    let author: String
    let body: String
    let bodyHTML: String?
    let createdAt: Date
}

/// A formal review verdict — what the PR screen's composer submits.
enum ReviewDecision: Sendable {
    case approve
    case requestChanges
    case comment
}

struct CreatePullRequestDraft: Sendable {
    let title: String
    let sourceBranch: String
    let targetBranch: String
    let body: String?
}

/// What the create form loads when it opens.
struct CreatePullRequestFormData: Sendable {
    let branches: [String]
    let defaultBranch: String
    /// Description templates, the one the provider would prefill first.
    let templates: [PullRequestTemplate]
}

struct PullRequestTemplate: Hashable, Sendable {
    /// Shown in the picker when a repo has more than one.
    let name: String
    let body: String
}

/// One page of a list endpoint, and whether the provider says there's more.
struct Page<Item: Sendable>: Sendable {
    let items: [Item]
    let hasNextPage: Bool
}

/// The last rate-limit budget a client learned from a response.
struct RateLimitStatus: Equatable, Sendable {
    let remaining: Int
    let reset: Date
}

/// What a provider can do, so the UI hides actions it can't — e.g. not
/// every provider has a separate "request changes" review verdict.
struct ProviderCapabilities: Sendable {
    var supportsRequestChanges = true
    var supportsNotifications = false
}

/// What one account's token is actually allowed to do, as far as the
/// provider reveals — checked when the account is added (and on demand).
struct TokenAccess: Codable, Equatable, Sendable {
    enum Level: String, Codable, Sendable {
        case yes
        case no
        /// The provider doesn't say up front (e.g. fine-grained tokens,
        /// whose permissions are per repository).
        case unknown
    }

    /// e.g. "Classic token" / "Fine-grained token".
    var tokenKind: String
    var readRepositories: Level
    var writePullRequests: Level
    var notifications: Level
    /// Why a level is what it is, keyed by the same names — shown in Settings.
    var notes: [String: String] = [:]
    /// Raw scopes, when the provider lists them.
    var scopes: [String] = []
}

// MARK: - Notifications

/// One inbox thread — a PR, issue, release… something happened on.
struct InboxItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pullRequest, issue, release, discussion, commit, checkSuite
        case other(String)
    }

    /// Why it's in the inbox. Raw values double as settings keys.
    enum Reason: String, CaseIterable, Sendable {
        case reviewRequested = "review_requested"
        case mention
        case teamMention = "team_mention"
        case assign
        case author
        case comment
        case ciActivity = "ci_activity"
        case stateChange = "state_change"
        case subscribed
        case manual
        case securityAlert = "security_alert"
        case other
    }

    /// The provider's thread id — what "mark read" takes.
    let id: String
    let repoPath: String
    let title: String
    let kind: Kind
    /// PR/issue number, when the subject has one.
    let number: Int?
    let reason: Reason
    let isUnread: Bool
    let updatedAt: Date
    /// Where to open it in a browser.
    let webURL: URL?
}

struct InboxFetch: Sendable {
    let items: [InboxItem]
    /// The provider's requested minimum seconds between polls, if it sent one.
    let pollInterval: TimeInterval?
}
