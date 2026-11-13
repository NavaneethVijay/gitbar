import Foundation

/// The whole contract a git provider module implements — one instance per
/// connected account (so rate-limit and ETag state stay per token). Every
/// input and output is a neutral `Domain` type; `repo` is always the
/// `RepoRef.path` within this client's own account.
///
/// A module decides *what* to request and *how* to map the response. It
/// never decides *when*: throttling, pagination bookkeeping, background
/// refresh and display formatting all live above it, shared by every
/// provider. See CLAUDE.md → "Adding a provider".
protocol ProviderClient: Actor {
    nonisolated var kind: ProviderKind { get }
    nonisolated var capabilities: ProviderCapabilities { get }

    /// The token's owner — validates the token when adding an account.
    func validate() async throws -> AccountProfile
    /// Every repo the account can see, for the favorites picker.
    func repositories() async throws -> [RemoteRepo]

    // Lists. `recent*` is the cheap repo-list tier (a few items, just enough
    // for the status ring); `page` variants are the repo screen's real
    // pagination, 1-based.
    func recentPullRequests(repo: String, limit: Int) async throws -> [PullRequest]
    func recentIssues(repo: String, limit: Int) async throws -> [Issue]
    func pullRequests(repo: String, page: Int) async throws -> Page<PullRequest>
    func issues(repo: String, page: Int) async throws -> Page<Issue>
    func pullRequest(repo: String, number: Int) async throws -> PullRequest
    /// Open PRs by one author, paged like `pullRequests(repo:page:)` — the
    /// repo screen's "Only mine" filter, done server-side.
    func pullRequests(repo: String, page: Int, author: String) async throws -> Page<PullRequest>
    /// Open issues assigned to one login — the Issues tab's "Assigned to me".
    func issues(repo: String, page: Int, assignee: String) async throws -> Page<Issue>
    /// One issue by number, for the Issues tab's number search. Throws when
    /// it doesn't exist (or the number is a PR).
    func issue(repo: String, number: Int) async throws -> Issue
    /// Description, stars, default branch + its CI, latest release — the
    /// repo screen's summary strip. Ideally ETag-cacheable GETs only.
    func overview(repo: String) async throws -> RepoOverview
    /// An issue's conversation, oldest first (like `comments` for a PR).
    func issueComments(repo: String, number: Int) async throws -> [Comment]
    func addIssueComment(repo: String, number: Int, body: String) async throws -> Comment

    // One PR's details.
    /// Combined CI result and review verdict per PR, for a whole page at
    /// once — ideally one request, however the provider can manage it.
    func statusSummaries(repo: String, numbers: [Int]) async throws -> [Int: PullRequestStatusSummary]
    func checks(repo: String, pullRequest: PullRequest) async throws -> [CheckRun]
    func comments(repo: String, number: Int) async throws -> [Comment]
    /// One state per person, already reduced from the provider's own
    /// requested-reviewer and review-history lists.
    func reviewers(repo: String, pullRequest: PullRequest) async throws -> [Reviewer]
    /// Every file the PR touches, with its status and line counts.
    func files(repo: String, number: Int) async throws -> [PullRequestFileChange]

    /// Inline code-review threads on the diff, oldest first, including the
    /// notes of your own pending (unsubmitted) review.
    func codeReview(repo: String, number: Int) async throws -> CodeReview

    // Writes.
    /// Finishes a review: submits your pending review (with all its inline
    /// comments) when there is one, else a review with just the verdict and
    /// text.
    func submitReview(repo: String, number: Int, decision: ReviewDecision, body: String?) async throws
    /// An inline comment. `pending`: add it to your pending review (starting
    /// one if needed — "Start a review"); otherwise post it on its own right
    /// away ("Add single comment").
    func addReviewComment(repo: String, pullRequest: PullRequest, comment: NewReviewComment, pending: Bool) async throws
    func updatePendingComment(repo: String, number: Int, noteID: String, body: String) async throws
    func deletePendingComment(repo: String, number: Int, noteID: String) async throws
    /// Throws away your pending review and every comment in it.
    func discardPendingReview(repo: String, number: Int) async throws
    /// A reply in an existing inline thread (`ReviewThread.id`), posted now.
    func replyToReviewThread(repo: String, number: Int, threadID: String, body: String) async throws
    func setReviewThreadResolved(repo: String, number: Int, threadID: String, resolved: Bool) async throws
    /// Title, description and/or target branch of an existing PR.
    func updatePullRequest(repo: String, number: Int, edit: PullRequestEdit) async throws -> PullRequest
    /// Every branch name (capped), for the edit form's target picker.
    func branches(repo: String) async throws -> [String]
    /// A plain reply into the conversation thread (what `comments` lists) —
    /// no review verdict attached.
    func addComment(repo: String, number: Int, body: String) async throws -> Comment
    func createFormData(repo: String) async throws -> CreatePullRequestFormData
    func createPullRequest(repo: String, draft: CreatePullRequestDraft) async throws -> PullRequest

    /// The last budget seen on a response, `nil` before the first request
    /// (or for a provider that doesn't report one).
    func rateLimitStatus() async -> RateLimitStatus?

    /// What this token can do — see `TokenAccess`.
    func tokenAccess() async throws -> TokenAccess

    // Notifications (only called when `capabilities.supportsNotifications`).
    func notifications(participatingOnly: Bool) async throws -> InboxFetch
    func markNotificationRead(id: String) async throws
    func markAllNotificationsRead() async throws
}
