import Combine
import Foundation
import Observation
import SwiftUI

/// Live data for every favorited repo across all accounts and providers.
/// Provider-neutral: decides *when* to fetch (throttling, pagination,
/// staleness, backoff); provider modules decide *what* and *how*.
///
/// Two tiers: `refresh()` fetches a few items per repo for the status ring;
/// the repo screen pages through everything only once opened.
///
/// `@Observable`: each view re-renders only for the properties it reads.
/// Every UI-visible write goes through `assign`, which skips unchanged
/// values — most background refreshes are ETag 304s that change nothing,
/// and an unconditional write would still redraw the whole popover.
@MainActor
@Observable
final class LiveRepoStore {
    private(set) var snapshots: [RepoSnapshot] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Set when a fetch was skipped because the rate limit is nearly spent.
    private(set) var rateLimitWarning: String?

    // Repo-detail pagination state, keyed by repo.
    private(set) var detailPullRequests: [RepoRef: [RepoPullRequest]] = [:]
    private(set) var detailIssues: [RepoRef: [RepoIssue]] = [:]
    private(set) var hasMorePullRequests: [RepoRef: Bool] = [:]
    private(set) var hasMoreIssues: [RepoRef: Bool] = [:]
    private(set) var isLoadingMorePullRequests: [RepoRef: Bool] = [:]
    private(set) var isLoadingMoreIssues: [RepoRef: Bool] = [:]

    // "Only mine": the account's own open PRs, fetched server-side and paged
    // separately from the full list.
    private(set) var minePullRequests: [RepoRef: [RepoPullRequest]] = [:]
    private(set) var hasMoreMinePullRequests: [RepoRef: Bool] = [:]
    private(set) var isLoadingMoreMinePullRequests: [RepoRef: Bool] = [:]

    // PR-number search: only PRs fetched by number because they weren't loaded.
    /// The Issues tab's "Assigned to me" list, fetched server-side.
    private(set) var assignedIssues: [RepoRef: [RepoIssue]] = [:]
    private(set) var hasMoreAssignedIssues: [RepoRef: Bool] = [:]
    private(set) var isLoadingMoreAssignedIssues: [RepoRef: Bool] = [:]
    /// An issue fetched by number because it wasn't in the loaded pages.
    private(set) var issueSearchResults: [RepoRef: RepoIssue] = [:]
    private(set) var isSearchingIssue: [RepoRef: Bool] = [:]
    private(set) var issueSearchError: [RepoRef: String] = [:]
    /// Issue screens (repo window). Keyed by repo + issue number — separate
    /// from the PR dictionaries, since GitLab's `#5` and `!5` can coexist.
    private(set) var issueComments: [PRRef: [PRComment]] = [:]
    private(set) var loadingIssueCommentsFor: Set<PRRef> = []
    private(set) var isPostingIssueComment: [PRRef: Bool] = [:]
    private(set) var issueCommentError: [PRRef: String] = [:]
    /// The repo screen's summary strip (description, default-branch CI,
    /// latest release, stars).
    private(set) var repoSummaries: [RepoRef: RepoSummary] = [:]
    private(set) var prSearchResults: [RepoRef: RepoPullRequest] = [:]
    private(set) var isSearchingPR: [RepoRef: Bool] = [:]
    private(set) var prSearchError: [RepoRef: String] = [:]

    // Per-PR lazy loading, per section.
    private(set) var loadingChecksFor: Set<PRRef> = []
    private(set) var loadingCommentsFor: Set<PRRef> = []
    private(set) var loadingReviewersFor: Set<PRRef> = []
    private(set) var loadingFilesFor: Set<PRRef> = []

    private(set) var isSubmittingReview: [PRRef: Bool] = [:]
    private(set) var reviewSubmitError: [PRRef: String] = [:]

    private(set) var isRefreshingPRDetail: [PRRef: Bool] = [:]

    @ObservationIgnored private var prPageCursor: [RepoRef: Int] = [:]
    @ObservationIgnored private var issuePageCursor: [RepoRef: Int] = [:]
    @ObservationIgnored private var minePageCursor: [RepoRef: Int] = [:]
    @ObservationIgnored private var lastMineRefreshAt: [RepoRef: Date] = [:]
    @ObservationIgnored private var assignedPageCursor: [RepoRef: Int] = [:]
    @ObservationIgnored private var lastAssignedRefreshAt: [RepoRef: Date] = [:]
    @ObservationIgnored private var isLoadingOverview: Set<RepoRef> = []
    @ObservationIgnored private var lastIssueDetailRefreshAt: [PRRef: Date] = [:]

    // `refresh()` joins an in-flight run and skips within
    // `minimumRefreshInterval` of the last; detail screens use the same
    // interval to decide whether a revisit re-fetches.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt: Date?
    /// The favorites the last refresh covered — a change (a repo just
    /// favorited in Settings) bypasses the throttle so it shows up at once.
    @ObservationIgnored private var lastRefreshedRepos: Set<RepoRef> = []
    @ObservationIgnored private var lastRepoDetailRefreshAt: [RepoRef: Date] = [:]
    @ObservationIgnored private var lastPRDetailRefreshAt: [PRRef: Date] = [:]
    @ObservationIgnored private var isRefreshingRepoDetail: Set<RepoRef> = []
    private static let minimumRefreshInterval: TimeInterval = 60

    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private let favoriteStore: FavoriteRepoStore

    /// One client per account, reused: rate-limit and ETag state live on the instance.
    @ObservationIgnored private var clientCache: [UUID: any ProviderClient] = [:]

    /// Below this many requests remaining, new batches are skipped.
    private static let rateLimitFloor = 50

    /// How many PRs/issues the cheap tier fetches per repo.
    nonisolated private static let quickPageLimit = 5

    init(accountStore: AccountStore, favoriteStore: FavoriteRepoStore) {
        self.accountStore = accountStore
        self.favoriteStore = favoriteStore
        // Mirrored as observed state so a color picked in Settings repaints
        // an open popover at once (`AccountStore` is an ObservableObject the
        // popover doesn't watch). `$accounts` emits the new value on willSet.
        accountsSubscription = accountStore.$accounts.sink { [weak self] accounts in
            self?.assign(\.accountBadges, Self.badges(for: accounts))
        }
    }

    @ObservationIgnored private var accountsSubscription: AnyCancellable?

    /// What the repo list shows about a repo's account: its color, and a
    /// "Provider · @login" tooltip.
    struct AccountBadge: Equatable {
        let color: AccountColor
        let label: String
        /// "login · GitHub" (plus the host when self-hosted) — the main
        /// window's account group header.
        let title: String
        /// Order in Settings — account groups follow it.
        let position: Int
        /// The host's home page, for "Open on GitHub".
        let webURL: URL?
    }

    /// Per account id — the repo list tints each repo's tile by its account.
    private(set) var accountBadges: [UUID: AccountBadge] = [:]

    private static func badges(for accounts: [Account]) -> [UUID: AccountBadge] {
        Dictionary(uniqueKeysWithValues: accounts.enumerated().map { position, account in
            (account.id, AccountBadge(
                color: account.resolvedColor(position: position),
                label: "\(account.provider.displayName) · @\(account.login)" + (account.isCloud ? "" : " (\(account.host))"),
                title: "\(account.login) · " + (account.isCloud ? account.provider.displayName : account.host),
                position: position,
                webURL: URL(string: "https://\(account.host)")))
        })
    }

    var hasConnectedAccount: Bool { !accountStore.accounts.isEmpty }
    var accountCount: Int { accountStore.accounts.count }

    /// Each connected provider once, in `ProviderKind` order — for wording
    /// that depends on which hosts are in use.
    var connectedProviders: [ProviderKind] {
        let kinds = Set(accountStore.accounts.map(\.provider))
        return ProviderKind.allCases.filter(kinds.contains)
    }
    var hasFavorites: Bool {
        accountStore.accounts.contains { !favoriteStore.favoriteFullNames(for: $0.id).isEmpty }
    }

    /// Which provider a repo lives on — for wording ("PR"/"MR", `#`/`!`).
    func provider(for repo: RepoRef) -> ProviderKind {
        account(for: repo)?.provider ?? .github
    }

    /// The account's own login — for "mine" filters.
    func login(for repo: RepoRef) -> String? {
        account(for: repo)?.login
    }

    func capabilities(for repo: RepoRef) -> ProviderCapabilities {
        resolve(repo)?.client.capabilities ?? ProviderCapabilities()
    }

    private func account(for repo: RepoRef) -> Account? {
        accountStore.accounts.first { $0.id == repo.accountID }
    }

    private func client(for account: Account) -> (any ProviderClient)? {
        if let cached = clientCache[account.id] { return cached }
        guard let client = accountStore.client(for: account) else { return nil }
        clientCache[account.id] = client
        return client
    }

    /// The account and client a repo belongs to — `nil` if the account was
    /// disconnected or its token/provider is unavailable.
    private func resolve(_ repo: RepoRef) -> (account: Account, client: any ProviderClient)? {
        guard let account = account(for: repo), let client = client(for: account) else { return nil }
        return (account, client)
    }

    // MARK: - Tier 1: the cheap repo-list refresh

    /// `force` skips the 60s throttle (Retry, a just-created PR) but still
    /// joins a run already in flight.
    func refresh(force: Bool = false) async {
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }
        let favorites = currentFavorites()
        if !force, favorites == lastRefreshedRepos, let last = lastRefreshAt,
           Date().timeIntervalSince(last) < Self.minimumRefreshInterval { return }
        lastRefreshedRepos = favorites

        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
        lastRefreshAt = Date()
    }

    private func currentFavorites() -> Set<RepoRef> {
        Set(accountStore.accounts.flatMap { account in
            favoriteStore.favoriteFullNames(for: account.id).map { RepoRef(accountID: account.id, path: $0) }
        })
    }

    /// An account with no token, no module or a low rate limit just
    /// contributes nothing, rather than blocking the others.
    private func performRefresh() async {
        let accounts = accountStore.accounts
        guard !accounts.isEmpty else {
            assign(\.snapshots, [])
            assign(\.loadError, nil)
            return
        }

        var warnings: [String] = []
        var usable: [(account: Account, client: any ProviderClient)] = []
        for account in accounts {
            guard let client = client(for: account) else { continue }
            if let warning = await rateLimitGuard(client, account: account) {
                warnings.append(warning)
            } else {
                usable.append((account, client))
            }
        }
        assign(\.rateLimitWarning, warnings.first)

        let jobs: [(repo: RepoRef, account: Account, client: any ProviderClient)] = usable.flatMap { entry in
            favoriteStore.favoriteFullNames(for: entry.account.id).sorted().map {
                (RepoRef(accountID: entry.account.id, path: $0), entry.account, entry.client)
            }
        }

        guard !jobs.isEmpty else {
            if warnings.isEmpty {
                assign(\.snapshots, [])
                assign(\.loadError, nil)
            }
            return
        }

        assign(\.isLoading, true)
        assign(\.loadError, nil)

        let results = await withTaskGroup(of: (RepoRef, Result<RepoSnapshot, Error>).self) { group in
            for job in jobs {
                group.addTask {
                    do {
                        return (job.repo, .success(try await Self.fetchSnapshot(repo: job.repo, account: job.account, client: job.client)))
                    } catch {
                        return (job.repo, .failure(error))
                    }
                }
            }
            var collected: [(RepoRef, Result<RepoSnapshot, Error>)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        var ok: [RepoSnapshot] = []
        var failed: [String] = []
        for (repo, result) in results {
            switch result {
            case .success(let snapshot): ok.append(snapshot)
            case .failure: failed.append(repo.path)
            }
        }

        assign(\.snapshots, ok.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        assign(\.loadError, failed.isEmpty ? nil
            : "Couldn't load \(failed.sorted().joined(separator: ", ")) — tap to retry.")
        assign(\.isLoading, false)
    }

    /// Only your own PRs get the extra reviewers/checks calls, to bound
    /// request volume; only the small page just fetched is considered.
    private nonisolated static func fetchSnapshot(repo: RepoRef, account: Account, client: any ProviderClient) async throws -> RepoSnapshot {
        async let pullsTask = client.recentPullRequests(repo: repo.path, limit: quickPageLimit)
        async let issuesTask = client.recentIssues(repo: repo.path, limit: quickPageLimit)
        let (pulls, issues) = try await (pullsTask, issuesTask)

        let login = account.login
        var needsAttention = pulls.contains { $0.requestedReviewers.contains(login) }
        var busy = false
        for pr in pulls where pr.author == login {
            if let reviewers = try? await client.reviewers(repo: repo.path, pullRequest: pr),
               reviewers.contains(where: { $0.state == .changesRequested }) {
                needsAttention = true
            }
            if let runs = try? await client.checks(repo: repo.path, pullRequest: pr),
               runs.contains(where: \.isRunning) {
                busy = true
            }
        }

        return DisplayMapper.snapshot(
            repo: repo, provider: account.provider, login: login,
            recentPulls: pulls, recentIssues: issues, pageLimit: quickPageLimit,
            needsAttention: needsAttention, busy: busy)
    }

    // MARK: - Tier 2: real pagination once a repo is opened

    /// First visit loads page one; revisiting (or a background tick) after
    /// `minimumRefreshInterval` re-fetches it.
    func beginRepoDetail(repoID: RepoRef) {
        if detailPullRequests[repoID] == nil || detailIssues[repoID] == nil {
            lastRepoDetailRefreshAt[repoID] = Date()
            if detailPullRequests[repoID] == nil {
                Task { await loadMorePullRequests(repoID: repoID) }
            }
            if detailIssues[repoID] == nil {
                Task { await loadMoreIssues(repoID: repoID) }
            }
            Task { await loadOverview(repoID: repoID) }
        } else if isStale(lastRepoDetailRefreshAt[repoID]) {
            Task { await refreshRepoDetailFirstPage(repoID: repoID) }
        } else if repoSummaries[repoID] == nil {
            Task { await loadOverview(repoID: repoID) }
        }
        // Keep "Only mine" / "Assigned to me" fresh too, once used for this repo.
        if minePullRequests[repoID] != nil { beginMinePullRequests(repoID: repoID) }
        if assignedIssues[repoID] != nil { beginAssignedIssues(repoID: repoID) }
    }

    /// A Refresh button: re-fetches now (no 60s throttle) and returns once
    /// it's done, so the caller can confirm it.
    func refreshRepoDetail(repoID: RepoRef) async {
        lastRepoDetailRefreshAt[repoID] = Date()
        if detailPullRequests[repoID] != nil, detailIssues[repoID] != nil {
            await refreshRepoDetailFirstPage(repoID: repoID)
        } else {
            if detailPullRequests[repoID] == nil { await loadMorePullRequests(repoID: repoID) }
            if detailIssues[repoID] == nil { await loadMoreIssues(repoID: repoID) }
            await loadOverview(repoID: repoID)
        }
        if minePullRequests[repoID] != nil { await loadMoreMinePullRequests(repoID: repoID, restart: true) }
        if assignedIssues[repoID] != nil { await loadMoreAssignedIssues(repoID: repoID, restart: true) }
    }

    /// A PR's screen appearing — first visit lazily loads its sections;
    /// coming back to it once it's stale re-fetches the whole thing.
    func beginPRDetail(repoID: RepoRef, prID: Int) {
        let key = PRRef(repo: repoID, number: prID)
        if lastPRDetailRefreshAt[key] == nil {
            lastPRDetailRefreshAt[key] = Date()
            loadDetail(repoID: repoID, prID: prID)
        } else if isStale(lastPRDetailRefreshAt[key]) {
            Task { await refreshPRDetail(repoID: repoID, prID: prID) }
        }
    }

    /// For the background scheduler while the popover is open: keep
    /// whichever screen is actually showing fresh, not just the repo list.
    func refreshVisibleScreen(repoID: RepoRef?, prID: Int?) {
        guard let repoID else { return }
        if let prID {
            beginPRDetail(repoID: repoID, prID: prID)
        } else {
            beginRepoDetail(repoID: repoID)
        }
    }

    private func isStale(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) >= Self.minimumRefreshInterval
    }

    /// Merges a fresh page one over what's loaded, keeping "Load more" pages
    /// and each PR's lazily-loaded sections so nothing flashes empty.
    private func refreshRepoDetailFirstPage(repoID: RepoRef) async {
        guard !isRefreshingRepoDetail.contains(repoID), let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        isRefreshingRepoDetail.insert(repoID)
        defer { isRefreshingRepoDetail.remove(repoID) }
        lastRepoDetailRefreshAt[repoID] = Date()

        let path = repoID.path
        Task { await loadOverview(repoID: repoID) }
        async let prPage = try? withRateLimitBackoff { try await client.pullRequests(repo: path, page: 1) }
        async let issuePage = try? withRateLimitBackoff { try await client.issues(repo: path, page: 1) }
        let (prs, issues) = await (prPage, issuePage)

        if let prs {
            let old = detailPullRequests[repoID] ?? []
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let fresh = prs.items.map { item -> RepoPullRequest in
                var mapped = DisplayMapper.pullRequest(item, login: account.login)
                if let previous = oldByID[mapped.id] { mapped.keepLoadedDetail(from: previous) }
                return mapped
            }
            assign(\.detailPullRequests[repoID], Self.mergeFirstPage(fresh, into: old, oldFirstPageCount: prs.items.count))
            if (prPageCursor[repoID] ?? 0) <= 1 { assign(\.hasMorePullRequests[repoID], prs.hasNextPage) }
            prPageCursor[repoID] = max(prPageCursor[repoID] ?? 0, 1)
            Task { await loadCheckSummaries(repoID: repoID, numbers: fresh.map(\.id)) }
        }
        if let issues {
            let old = detailIssues[repoID] ?? []
            let fresh = issues.items.map { DisplayMapper.issue($0, login: account.login) }
            assign(\.detailIssues[repoID], Self.mergeFirstPage(fresh, into: old, oldFirstPageCount: fresh.count))
            if (issuePageCursor[repoID] ?? 0) <= 1 { assign(\.hasMoreIssues[repoID], issues.hasNextPage) }
            issuePageCursor[repoID] = max(issuePageCursor[repoID] ?? 0, 1)
        }
    }

    /// New page one, then what was loaded beyond the old page one, deduped.
    /// Items gone from page one are dropped (closed, or pushed to page two).
    private static func mergeFirstPage<Item: Identifiable>(_ firstPage: [Item], into old: [Item], oldFirstPageCount: Int) -> [Item] {
        let freshIDs = Set(firstPage.map(\.id))
        let beyondFirstPage = old.dropFirst(max(oldFirstPageCount, firstPage.count)).filter { !freshIDs.contains($0.id) }
        return firstPage + beyondFirstPage
    }

    func loadMorePullRequests(repoID: RepoRef) async {
        guard isLoadingMorePullRequests[repoID] != true, hasMorePullRequests[repoID] != false,
              let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        assign(\.rateLimitWarning, nil)

        isLoadingMorePullRequests[repoID] = true
        defer { isLoadingMorePullRequests[repoID] = false }

        let nextPage = (prPageCursor[repoID] ?? 0) + 1
        do {
            let page = try await withRateLimitBackoff { try await client.pullRequests(repo: repoID.path, page: nextPage) }
            let mapped = page.items.map { DisplayMapper.pullRequest($0, login: account.login) }
            // A page-one refresh can shift items across pages — dedupe.
            let existingIDs = Set((detailPullRequests[repoID] ?? []).map(\.id))
            detailPullRequests[repoID, default: []].append(contentsOf: mapped.filter { !existingIDs.contains($0.id) })
            Task { await loadCheckSummaries(repoID: repoID, numbers: mapped.map(\.id)) }
            hasMorePullRequests[repoID] = page.hasNextPage
            prPageCursor[repoID] = nextPage
        } catch {
            // A failed "load more" leaves whatever was already loaded in place.
            assign(\.loadError, Self.message(for: error, fallback: "Couldn't load more \(account.provider.pullRequestNoun)s."))
        }
    }

    /// The "Only mine" list appearing — first time loads page one; coming
    /// back to it once stale re-fetches page one (dropping extra pages).
    func beginMinePullRequests(repoID: RepoRef) {
        if minePullRequests[repoID] == nil {
            lastMineRefreshAt[repoID] = Date()
            Task { await loadMoreMinePullRequests(repoID: repoID) }
        } else if isStale(lastMineRefreshAt[repoID]) {
            lastMineRefreshAt[repoID] = Date()
            Task { await loadMoreMinePullRequests(repoID: repoID, restart: true) }
        }
    }

    func loadMoreMinePullRequests(repoID: RepoRef, restart: Bool = false) async {
        guard isLoadingMoreMinePullRequests[repoID] != true,
              restart || hasMoreMinePullRequests[repoID] != false,
              let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        isLoadingMoreMinePullRequests[repoID] = true
        defer { isLoadingMoreMinePullRequests[repoID] = false }

        let nextPage = restart ? 1 : (minePageCursor[repoID] ?? 0) + 1
        let path = repoID.path
        let login = account.login
        do {
            let page = try await withRateLimitBackoff { try await client.pullRequests(repo: path, page: nextPage, author: login) }
            let old = restart ? [] : (minePullRequests[repoID] ?? [])
            // Keep lazily-loaded detail for PRs already open elsewhere.
            let known = Dictionary((detailPullRequests[repoID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let existingIDs = Set(old.map(\.id))
            let fresh = page.items.map { item -> RepoPullRequest in
                var mapped = DisplayMapper.pullRequest(item, login: login)
                if let previous = known[mapped.id] { mapped.keepLoadedDetail(from: previous) }
                return mapped
            }.filter { !existingIDs.contains($0.id) }
            assign(\.minePullRequests[repoID], old + fresh)
            assign(\.hasMoreMinePullRequests[repoID], page.hasNextPage)
            minePageCursor[repoID] = nextPage
            Task { await loadCheckSummaries(repoID: repoID, numbers: fresh.map(\.id)) }
        } catch {
            assign(\.loadError, Self.message(for: error, fallback: "Couldn't load your \(account.provider.pullRequestNoun)s."))
        }
    }

    func loadMoreIssues(repoID: RepoRef) async {
        guard isLoadingMoreIssues[repoID] != true, hasMoreIssues[repoID] != false,
              let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        assign(\.rateLimitWarning, nil)

        isLoadingMoreIssues[repoID] = true
        defer { isLoadingMoreIssues[repoID] = false }

        let nextPage = (issuePageCursor[repoID] ?? 0) + 1
        do {
            let page = try await withRateLimitBackoff { try await client.issues(repo: repoID.path, page: nextPage) }
            let existingIDs = Set((detailIssues[repoID] ?? []).map(\.id))
            let login = account.login
            detailIssues[repoID, default: []].append(contentsOf: page.items.map { DisplayMapper.issue($0, login: login) }.filter { !existingIDs.contains($0.id) })
            hasMoreIssues[repoID] = page.hasNextPage
            issuePageCursor[repoID] = nextPage
        } catch {
            assign(\.loadError, Self.message(for: error, fallback: "Couldn't load more issues."))
        }
    }

    /// The summary strip. Best-effort: a failure just leaves the strip as it
    /// was (empty on first load) — the lists below matter more.
    private func loadOverview(repoID: RepoRef) async {
        guard !isLoadingOverview.contains(repoID), let (account, client) = resolve(repoID) else { return }
        if await rateLimitGuard(client, account: account) != nil { return }
        isLoadingOverview.insert(repoID)
        defer { isLoadingOverview.remove(repoID) }
        let path = repoID.path
        guard let overview = try? await withRateLimitBackoff({ try await client.overview(repo: path) }) else { return }
        assign(\.repoSummaries[repoID], DisplayMapper.summary(overview))
    }

    /// The "Assigned to me" list appearing — same lifecycle as "Only mine".
    func beginAssignedIssues(repoID: RepoRef) {
        if assignedIssues[repoID] == nil {
            lastAssignedRefreshAt[repoID] = Date()
            Task { await loadMoreAssignedIssues(repoID: repoID) }
        } else if isStale(lastAssignedRefreshAt[repoID]) {
            lastAssignedRefreshAt[repoID] = Date()
            Task { await loadMoreAssignedIssues(repoID: repoID, restart: true) }
        }
    }

    func loadMoreAssignedIssues(repoID: RepoRef, restart: Bool = false) async {
        guard isLoadingMoreAssignedIssues[repoID] != true,
              restart || hasMoreAssignedIssues[repoID] != false,
              let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        isLoadingMoreAssignedIssues[repoID] = true
        defer { isLoadingMoreAssignedIssues[repoID] = false }

        let nextPage = restart ? 1 : (assignedPageCursor[repoID] ?? 0) + 1
        let path = repoID.path
        let login = account.login
        do {
            let page = try await withRateLimitBackoff { try await client.issues(repo: path, page: nextPage, assignee: login) }
            let old = restart ? [] : (assignedIssues[repoID] ?? [])
            let existingIDs = Set(old.map(\.id))
            let fresh = page.items.map { DisplayMapper.issue($0, login: login) }.filter { !existingIDs.contains($0.id) }
            assign(\.assignedIssues[repoID], old + fresh)
            assign(\.hasMoreAssignedIssues[repoID], page.hasNextPage)
            assignedPageCursor[repoID] = nextPage
        } catch {
            assign(\.loadError, Self.message(for: error, fallback: "Couldn't load your issues."))
        }
    }

    /// Only called when the number isn't in the loaded issue pages.
    func searchIssue(repoID: RepoRef, number: Int) async {
        guard isSearchingIssue[repoID] != true, let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        isSearchingIssue[repoID] = true
        issueSearchError[repoID] = nil
        defer { isSearchingIssue[repoID] = false }

        let path = repoID.path
        do {
            let issue = try await withRateLimitBackoff { try await client.issue(repo: path, number: number) }
            issueSearchResults[repoID] = DisplayMapper.issue(issue, login: account.login)
        } catch ProviderError.unexpectedStatus(_, 404) {
            issueSearchResults[repoID] = nil
            issueSearchError[repoID] = "No issue #\(number) found."
        } catch {
            issueSearchResults[repoID] = nil
            issueSearchError[repoID] = Self.message(for: error, fallback: "Couldn't find issue #\(number).")
        }
    }

    func clearIssueSearch(repoID: RepoRef) {
        assign(\.issueSearchResults[repoID], nil)
        assign(\.issueSearchError[repoID], nil)
    }

    // MARK: - Issue detail (repo window)

    /// An issue from whichever list holds it — main, "Assigned to me", or a
    /// number search.
    func issue(repoID: RepoRef, number: Int) -> RepoIssue? {
        detailIssues[repoID]?.first { $0.id == number }
            ?? assignedIssues[repoID]?.first { $0.id == number }
            ?? issueSearchResults[repoID].flatMap { $0.id == number ? $0 : nil }
    }

    /// First visit loads the comments; coming back once stale re-reads them.
    func beginIssueDetail(repoID: RepoRef, number: Int, force: Bool = false) {
        let key = PRRef(repo: repoID, number: number)
        guard force || issueComments[key] == nil || isStale(lastIssueDetailRefreshAt[key]),
              !loadingIssueCommentsFor.contains(key), let (_, client) = resolve(repoID) else { return }
        lastIssueDetailRefreshAt[key] = Date()
        loadingIssueCommentsFor.insert(key)
        let path = repoID.path
        Task {
            defer { loadingIssueCommentsFor.remove(key) }
            guard let comments = try? await withRateLimitBackoff({
                try await client.issueComments(repo: path, number: number)
            }) else { return }
            assign(\.issueComments[key], comments.map(DisplayMapper.comment))
        }
    }

    /// The issue screen's Refresh: re-reads the comments now and returns when done.
    func refreshIssueDetail(repoID: RepoRef, number: Int) async {
        let key = PRRef(repo: repoID, number: number)
        guard let (_, client) = resolve(repoID) else { return }
        lastIssueDetailRefreshAt[key] = Date()
        loadingIssueCommentsFor.insert(key)
        defer { loadingIssueCommentsFor.remove(key) }
        let path = repoID.path
        guard let comments = try? await withRateLimitBackoff({
            try await client.issueComments(repo: path, number: number)
        }) else { return }
        assign(\.issueComments[key], comments.map(DisplayMapper.comment))
    }

    func addIssueComment(repoID: RepoRef, number: Int, body: String) async {
        let key = PRRef(repo: repoID, number: number)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isPostingIssueComment[key] != true, let (_, client) = resolve(repoID) else { return }
        isPostingIssueComment[key] = true
        issueCommentError[key] = nil
        defer { isPostingIssueComment[key] = false }
        let path = repoID.path
        do {
            let comment = try await withRateLimitBackoff {
                try await client.addIssueComment(repo: path, number: number, body: trimmed)
            }
            issueComments[key, default: []].append(DisplayMapper.comment(comment))
        } catch {
            issueCommentError[key] = Self.message(for: error, fallback: "Couldn't post comment.")
        }
    }

    // MARK: - Search by PR number

    /// Only called when the number isn't in the loaded pages.
    func searchPullRequest(repoID: RepoRef, number: Int) async {
        guard isSearchingPR[repoID] != true, let (account, client) = resolve(repoID) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        assign(\.rateLimitWarning, nil)

        isSearchingPR[repoID] = true
        prSearchError[repoID] = nil
        defer { isSearchingPR[repoID] = false }

        do {
            let pr = try await withRateLimitBackoff { try await client.pullRequest(repo: repoID.path, number: number) }
            prSearchResults[repoID] = DisplayMapper.pullRequest(pr, login: account.login)
            Task { await loadCheckSummaries(repoID: repoID, numbers: [pr.number]) }
        } catch {
            prSearchResults[repoID] = nil
            let label = "\(account.provider.pullRequestShort) \(account.provider.formatNumber(number))"
            prSearchError[repoID] = Self.message(for: error, fallback: "Couldn't find \(label).")
        }
    }

    /// Opening a PR that came from outside the main list (a number search,
    /// the "Only mine" list): the detail screen and its lazy loads work off
    /// `detailPullRequests`, so the PR joins it.
    func adoptPullRequest(_ pr: RepoPullRequest, repoID: RepoRef) {
        guard detailPullRequests[repoID]?.contains(where: { $0.id == pr.id }) != true else { return }
        detailPullRequests[repoID, default: []].append(pr)
    }

    /// Makes sure one PR is in its repo's detail list — for opening it from
    /// the inbox or an alert. Loads page one first (so the list isn't left
    /// holding just this PR), then fetches the PR itself if it wasn't there.
    func loadPullRequest(repoID: RepoRef, number: Int) async -> Bool {
        if detailPullRequests[repoID] == nil { await loadMorePullRequests(repoID: repoID) }
        if detailPullRequests[repoID]?.contains(where: { $0.id == number }) == true { return true }
        guard let (account, client) = resolve(repoID) else { return false }
        let path = repoID.path
        guard let pr = try? await withRateLimitBackoff({ try await client.pullRequest(repo: path, number: number) })
        else { return false }
        if detailPullRequests[repoID]?.contains(where: { $0.id == number }) != true {
            detailPullRequests[repoID, default: []].append(DisplayMapper.pullRequest(pr, login: account.login))
        }
        Task { await loadCheckSummaries(repoID: repoID, numbers: [number]) }
        return true
    }

    /// Called when the search field empties — clears any stale hit/error.
    func clearPullRequestSearch(repoID: RepoRef) {
        assign(\.prSearchResults[repoID], nil)
        assign(\.prSearchError[repoID], nil)
    }

    // MARK: - PR detail — checks, comments and reviewers, independently

    /// Loads each empty section independently, so whichever answers first renders first.
    func loadDetail(repoID: RepoRef, prID: Int) {
        let key = PRRef(repo: repoID, number: prID)
        guard let (_, client) = resolve(repoID),
              let pr = detailPullRequests[repoID]?.first(where: { $0.id == prID }) else { return }
        let path = repoID.path
        let source = pr.source

        if pr.checks.isEmpty, !loadingChecksFor.contains(key) {
            loadingChecksFor.insert(key)
            Task {
                defer { loadingChecksFor.remove(key) }
                guard let runs = try? await withRateLimitBackoff({
                    try await client.checks(repo: path, pullRequest: source)
                }) else { return }
                updatePullRequest(repoID: repoID, prID: prID) { $0.checks = runs.map(DisplayMapper.check) }
            }
        }

        if pr.comments.isEmpty, !loadingCommentsFor.contains(key) {
            loadingCommentsFor.insert(key)
            Task {
                defer { loadingCommentsFor.remove(key) }
                guard let comments = try? await withRateLimitBackoff({
                    try await client.comments(repo: path, number: prID)
                }) else { return }
                updatePullRequest(repoID: repoID, prID: prID) { $0.comments = comments.map(DisplayMapper.comment) }
            }
        }

        if pr.reviewers.isEmpty, !loadingReviewersFor.contains(key) {
            loadingReviewersFor.insert(key)
            Task {
                defer { loadingReviewersFor.remove(key) }
                await refreshReviewers(repoID: repoID, prID: prID)
            }
        }

        if pr.files.isEmpty, !loadingFilesFor.contains(key) {
            loadingFilesFor.insert(key)
            Task {
                defer { loadingFilesFor.remove(key) }
                // Threads ride along, best-effort: the diff still shows without them.
                async let reviewResult = try? withRateLimitBackoff { try await client.codeReview(repo: path, number: prID) }
                let files = try? await withRateLimitBackoff { try await client.files(repo: path, number: prID) }
                let review = await reviewResult
                updatePullRequest(repoID: repoID, prID: prID) {
                    if let files { $0.files = files.map(DisplayMapper.fileChange) }
                    if let review { $0.apply(review) }
                }
            }
        }
    }

    func isLoadingChecks(repoID: RepoRef, prID: Int) -> Bool {
        loadingChecksFor.contains(PRRef(repo: repoID, number: prID))
    }

    func isLoadingComments(repoID: RepoRef, prID: Int) -> Bool {
        loadingCommentsFor.contains(PRRef(repo: repoID, number: prID))
    }

    func isLoadingReviewers(repoID: RepoRef, prID: Int) -> Bool {
        loadingReviewersFor.contains(PRRef(repo: repoID, number: prID))
    }

    func isLoadingFiles(repoID: RepoRef, prID: Int) -> Bool {
        loadingFilesFor.contains(PRRef(repo: repoID, number: prID))
    }

    func isRefreshingPRDetail(repoID: RepoRef, prID: Int) -> Bool {
        isRefreshingPRDetail[PRRef(repo: repoID, number: prID)] == true
    }

    /// Re-fetches the PR and every section; a section whose fetch fails keeps
    /// its last value.
    func refreshPRDetail(repoID: RepoRef, prID: Int) async {
        let key = PRRef(repo: repoID, number: prID)
        guard isRefreshingPRDetail[key] != true, let (account, client) = resolve(repoID),
              let existing = detailPullRequests[repoID]?.first(where: { $0.id == prID }) else { return }
        if let warning = await rateLimitGuard(client, account: account) {
            assign(\.rateLimitWarning, warning)
            return
        }
        assign(\.rateLimitWarning, nil)

        isRefreshingPRDetail[key] = true
        defer { isRefreshingPRDetail[key] = false }
        lastPRDetailRefreshAt[key] = Date()

        let path = repoID.path
        guard let fresh = try? await withRateLimitBackoff({
            try await client.pullRequest(repo: path, number: prID)
        }) else { return }

        var mapped = DisplayMapper.pullRequest(fresh, login: account.login)
        // Keep the last known values on screen while they're re-fetched.
        mapped.keepLoadedDetail(from: existing)
        Task { await loadCheckSummaries(repoID: repoID, numbers: [prID]) }

        async let checksResult = try? withRateLimitBackoff { try await client.checks(repo: path, pullRequest: fresh) }
        async let commentsResult = try? withRateLimitBackoff { try await client.comments(repo: path, number: prID) }
        async let reviewersResult = try? withRateLimitBackoff { try await client.reviewers(repo: path, pullRequest: fresh) }
        async let filesResult = try? withRateLimitBackoff { try await client.files(repo: path, number: prID) }
        async let reviewResult = try? withRateLimitBackoff { try await client.codeReview(repo: path, number: prID) }
        let (checks, comments, reviewers, files) = await (checksResult, commentsResult, reviewersResult, filesResult)
        let review = await reviewResult

        if let checks { mapped.checks = checks.map(DisplayMapper.check) }
        if let comments { mapped.comments = comments.map(DisplayMapper.comment) }
        if let reviewers { mapped.reviewers = reviewers.map(DisplayMapper.reviewer) }
        if let files { mapped.files = files.map(DisplayMapper.fileChange) }
        if let review { mapped.apply(review) }

        updatePullRequest(repoID: repoID, prID: prID) { $0 = mapped }
    }

    // MARK: - Reviews

    /// Re-fetches one PR's reviewers — on first load, and after a review
    /// submits (the acting reviewer's own state just changed).
    private func refreshReviewers(repoID: RepoRef, prID: Int) async {
        guard let (_, client) = resolve(repoID),
              let pr = detailPullRequests[repoID]?.first(where: { $0.id == prID }) else { return }
        let path = repoID.path
        let source = pr.source
        guard let reviewers = try? await withRateLimitBackoff({
            try await client.reviewers(repo: path, pullRequest: source)
        }) else { return }
        updatePullRequest(repoID: repoID, prID: prID) { $0.reviewers = reviewers.map(DisplayMapper.reviewer) }
    }

    /// Finishes the review — your pending one with all its inline comments
    /// when there is one. On failure the provider's own message lands in
    /// `reviewSubmitError` (and the pending review stays on the provider).
    func submitReview(repoID: RepoRef, prID: Int, decision: ReviewDecision, body: String) async {
        let key = PRRef(repo: repoID, number: prID)
        guard isSubmittingReview[key] != true, let (_, client) = resolve(repoID) else { return }

        isSubmittingReview[key] = true
        reviewSubmitError[key] = nil
        defer { isSubmittingReview[key] = false }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = repoID.path
        do {
            try await withRateLimitBackoff {
                try await client.submitReview(repo: path, number: prID, decision: decision,
                                              body: trimmed.isEmpty ? nil : trimmed)
            }
            async let reviewers: Void = refreshReviewers(repoID: repoID, prID: prID)
            async let threads: Void = refreshCodeReview(repoID: repoID, prID: prID)
            async let comments: Void = refreshComments(repoID: repoID, prID: prID)
            _ = await (reviewers, threads, comments)
        } catch {
            reviewSubmitError[key] = Self.message(for: error, fallback: "Couldn't submit review.")
        }
    }

    /// The conversation — a review's summary can land there (GitLab).
    private func refreshComments(repoID: RepoRef, prID: Int) async {
        guard let (_, client) = resolve(repoID) else { return }
        let path = repoID.path
        guard let comments = try? await withRateLimitBackoff({
            try await client.comments(repo: path, number: prID)
        }) else { return }
        updatePullRequest(repoID: repoID, prID: prID) { $0.comments = comments.map(DisplayMapper.comment) }
    }

    /// Shares the review's in-flight/error state — it's the same composer.
    func addComment(repoID: RepoRef, prID: Int, body: String) async {
        let key = PRRef(repo: repoID, number: prID)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSubmittingReview[key] != true, let (_, client) = resolve(repoID) else { return }

        isSubmittingReview[key] = true
        reviewSubmitError[key] = nil
        defer { isSubmittingReview[key] = false }

        let path = repoID.path
        do {
            let comment = try await withRateLimitBackoff {
                try await client.addComment(repo: path, number: prID, body: trimmed)
            }
            updatePullRequest(repoID: repoID, prID: prID) { $0.comments.append(DisplayMapper.comment(comment)) }
        } catch {
            reviewSubmitError[key] = Self.message(for: error, fallback: "Couldn't post comment.")
        }
    }

    // MARK: - Inline review comments

    /// Re-reads threads and the pending review after every write, so what's
    /// shown is always what the provider has (shared with the web).
    func refreshCodeReview(repoID: RepoRef, prID: Int) async {
        guard let (_, client) = resolve(repoID) else { return }
        let path = repoID.path
        guard let review = try? await withRateLimitBackoff({
            try await client.codeReview(repo: path, number: prID)
        }) else { return }
        updatePullRequest(repoID: repoID, prID: prID) { $0.apply(review) }
    }

    /// Runs one review write, then re-reads the review state. Throws the
    /// provider's message for the caller to show next to its text.
    private func reviewWrite(repoID: RepoRef, prID: Int,
                             _ write: @Sendable (any ProviderClient, String) async throws -> Void) async throws {
        guard let (_, client) = resolve(repoID) else { throw ProviderError.accountUnavailable }
        let path = repoID.path
        do {
            try await withRateLimitBackoff { try await write(client, path) }
        } catch {
            // A failed write may still mean the state moved (finished on the web).
            await refreshCodeReview(repoID: repoID, prID: prID)
            throw error
        }
        await refreshCodeReview(repoID: repoID, prID: prID)
    }

    /// `pending`: "Start a review" / "Add review comment"; else "Add single comment".
    func addReviewComment(repoID: RepoRef, prID: Int, anchor: DiffAnchor, body: String, pending: Bool) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let source = detailPullRequests[repoID]?.first(where: { $0.id == prID })?.source else { return }
        let comment = NewReviewComment(anchor: anchor, body: trimmed)
        try await reviewWrite(repoID: repoID, prID: prID) { client, path in
            try await client.addReviewComment(repo: path, pullRequest: source, comment: comment, pending: pending)
        }
    }

    func updatePendingComment(repoID: RepoRef, prID: Int, noteID: String, body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await reviewWrite(repoID: repoID, prID: prID) { client, path in
            try await client.updatePendingComment(repo: path, number: prID, noteID: noteID, body: trimmed)
        }
    }

    func deletePendingComment(repoID: RepoRef, prID: Int, noteID: String) async throws {
        try await reviewWrite(repoID: repoID, prID: prID) { client, path in
            try await client.deletePendingComment(repo: path, number: prID, noteID: noteID)
        }
    }

    func discardPendingReview(repoID: RepoRef, prID: Int) async throws {
        try await reviewWrite(repoID: repoID, prID: prID) { client, path in
            try await client.discardPendingReview(repo: path, number: prID)
        }
    }

    func replyToReviewThread(repoID: RepoRef, prID: Int, threadID: String, body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await reviewWrite(repoID: repoID, prID: prID) { client, path in
            try await client.replyToReviewThread(repo: path, number: prID, threadID: threadID, body: trimmed)
        }
    }

    func setReviewThreadResolved(repoID: RepoRef, prID: Int, threadID: String, resolved: Bool) async throws {
        try await reviewWrite(repoID: repoID, prID: prID) { client, path in
            try await client.setReviewThreadResolved(repo: path, number: prID, threadID: threadID, resolved: resolved)
        }
    }

    // MARK: - Editing a pull request

    func loadBranches(repoID: RepoRef) async throws -> [String] {
        guard let (_, client) = resolve(repoID) else { throw ProviderError.accountUnavailable }
        let path = repoID.path
        return try await withRateLimitBackoff { try await client.branches(repo: path) }
    }

    /// Sends only what changed. A new target branch changes the diff, so the
    /// whole PR is re-read after.
    func editPullRequest(repoID: RepoRef, prID: Int, title: String, body: String, targetBranch: String) async throws {
        guard let (account, client) = resolve(repoID),
              let existing = detailPullRequests[repoID]?.first(where: { $0.id == prID }) else {
            throw ProviderError.accountUnavailable
        }
        let source = existing.source
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var edit = PullRequestEdit()
        if trimmedTitle != source.title { edit.title = trimmedTitle }
        if body != source.body { edit.body = body }
        if targetBranch != source.targetBranch { edit.targetBranch = targetBranch }
        guard edit.title != nil || edit.body != nil || edit.targetBranch != nil else { return }

        let path = repoID.path
        let change = edit
        let updated = try await withRateLimitBackoff {
            try await client.updatePullRequest(repo: path, number: prID, edit: change)
        }
        var mapped = DisplayMapper.pullRequest(updated, login: account.login)
        mapped.keepLoadedDetail(from: existing)
        updatePullRequest(repoID: repoID, prID: prID) { $0 = mapped }
        if var hit = prSearchResults[repoID], hit.id == prID {
            hit = mapped
            assign(\.prSearchResults[repoID], hit)
        }
        if edit.targetBranch != nil {
            await refreshPRDetail(repoID: repoID, prID: prID)
        }
        // The repo list shows titles too.
        if edit.title != nil { Task { await refresh(force: true) } }
    }

    func isSubmittingReview(repoID: RepoRef, prID: Int) -> Bool {
        isSubmittingReview[PRRef(repo: repoID, number: prID)] == true
    }

    func reviewSubmitError(repoID: RepoRef, prID: Int) -> String? {
        reviewSubmitError[PRRef(repo: repoID, number: prID)]
    }

    // MARK: - Creating a pull request

    /// Fetched fresh each time — the point is picking a just-pushed branch.
    func loadCreatePullRequestForm(repoID: RepoRef) async throws -> CreatePullRequestFormData {
        guard let (_, client) = resolve(repoID) else { throw ProviderError.accountUnavailable }
        let path = repoID.path
        return try await withRateLimitBackoff { try await client.createFormData(repo: path) }
    }

    /// Inserts the new PR at the top of the list so the caller can open it.
    func createPullRequest(repoID: RepoRef, title: String, head: String, base: String, body: String) async throws -> RepoPullRequest {
        guard let (account, client) = resolve(repoID) else { throw ProviderError.accountUnavailable }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = CreatePullRequestDraft(title: title, sourceBranch: head, targetBranch: base,
                                           body: trimmedBody.isEmpty ? nil : trimmedBody)
        let path = repoID.path
        let created = try await withRateLimitBackoff { try await client.createPullRequest(repo: path, draft: draft) }
        let mapped = DisplayMapper.pullRequest(created, login: account.login)
        detailPullRequests[repoID, default: []].insert(mapped, at: 0)
        Task { await loadCheckSummaries(repoID: repoID, numbers: [mapped.id]) }
        // Keep the repo list's status ring/count in step with the new PR.
        Task { await refresh(force: true) }
        return mapped
    }

    // MARK: - CI status per PR row

    /// One batched call per page; on failure rows keep no label.
    private func loadCheckSummaries(repoID: RepoRef, numbers: [Int]) async {
        guard !numbers.isEmpty, let (_, client) = resolve(repoID) else { return }
        let path = repoID.path
        guard let summaries = try? await withRateLimitBackoff({
            try await client.statusSummaries(repo: path, numbers: numbers)
        }) else { return }

        for (number, summary) in summaries {
            updatePullRequest(repoID: repoID, prID: number) { $0.statusSummary = summary }
            if var hit = prSearchResults[repoID], hit.id == number {
                hit.statusSummary = summary
                assign(\.prSearchResults[repoID], hit)
            }
        }
    }

    /// Re-fetches just one PR's check runs — the PR screen polls this while
    /// CI is running (REST, ETag-cached: an unchanged poll is a free 304).
    /// When the last run finishes, the row-level summary is refreshed once.
    func refreshChecks(repoID: RepoRef, prID: Int) async {
        guard let (_, client) = resolve(repoID),
              let pr = detailPullRequests[repoID]?.first(where: { $0.id == prID }) else { return }
        let path = repoID.path
        let source = pr.source
        let wasRunning = pr.areChecksRunning
        guard let runs = try? await client.checks(repo: path, pullRequest: source) else { return }
        updatePullRequest(repoID: repoID, prID: prID) { $0.checks = runs.map(DisplayMapper.check) }
        if wasRunning, !runs.contains(where: \.isRunning) {
            await loadCheckSummaries(repoID: repoID, numbers: [prID])
        }
    }

    /// Re-locates by id rather than trusting a captured index — a
    /// concurrent refresh or page load could have mutated the array.
    /// Applies to the PR wherever it's listed — the full list and "Only mine".
    private func updatePullRequest(repoID: RepoRef, prID: Int, _ mutate: (inout RepoPullRequest) -> Void) {
        if var list = detailPullRequests[repoID], let index = list.firstIndex(where: { $0.id == prID }) {
            let before = list[index]
            mutate(&list[index])
            if list[index] != before { detailPullRequests[repoID] = list }
        }
        if var list = minePullRequests[repoID], let index = list.firstIndex(where: { $0.id == prID }) {
            let before = list[index]
            mutate(&list[index])
            if list[index] != before { minePullRequests[repoID] = list }
        }
    }

    /// Writes only when the value actually changed — see the class comment.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<LiveRepoStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: - Rate limiting

    /// `account` is for the message — with several accounts each carrying
    /// its own budget, "rate limit low" alone would leave you guessing.
    private func rateLimitGuard(_ client: any ProviderClient, account: Account) async -> String? {
        guard let limit = await client.rateLimitStatus(), limit.remaining < Self.rateLimitFloor else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "@\(account.login): \(account.provider.displayName) rate limit low (\(limit.remaining) left) — resuming after \(formatter.string(from: limit.reset))."
    }

    /// One wait-and-retry: the provider's `Retry-After` (≤ 2 min), else 60s.
    /// Single-request paths only — never per repo inside `refresh()`.
    private func withRateLimitBackoff<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch ProviderError.rateLimited(_, let retryAfter) {
            try? await Task.sleep(for: .seconds(min(retryAfter ?? 60, 120)))
            return try await operation()
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

private extension RepoPullRequest {
    mutating func apply(_ review: CodeReview) {
        reviewThreads = review.threads.map(DisplayMapper.reviewThread)
        hasPendingReview = review.hasPendingReview
    }
}
