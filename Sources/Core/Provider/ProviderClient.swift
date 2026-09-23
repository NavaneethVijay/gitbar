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

    // One PR's details.
    /// Combined CI result per PR, for a whole page at once — ideally one
    /// request, however the provider can manage it.
    func checkSummaries(repo: String, numbers: [Int]) async throws -> [Int: CheckSummary]
    func checks(repo: String, pullRequest: PullRequest) async throws -> [CheckRun]
    func comments(repo: String, number: Int) async throws -> [Comment]
    /// One state per person, already reduced from the provider's own
    /// requested-reviewer and review-history lists.
    func reviewers(repo: String, pullRequest: PullRequest) async throws -> [Reviewer]

    // Writes.
    func submitReview(repo: String, number: Int, decision: ReviewDecision, body: String?) async throws
    func createFormData(repo: String) async throws -> CreatePullRequestFormData
    func createPullRequest(repo: String, draft: CreatePullRequestDraft) async throws -> PullRequest

    /// The last budget seen on a response, `nil` before the first request
    /// (or for a provider that doesn't report one).
    func rateLimitStatus() async -> RateLimitStatus?
}
