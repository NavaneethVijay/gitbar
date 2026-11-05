// The app's main window: "For You" lists across every pinned repo, then each
// repo (grouped under its account) with its PRs and issues, and the selected
// PR, issue or inbox thread beside them. The popover is the quick glance;
// anything opened "in a window" lands here. Settings stays its own window.
import AppKit
import Observation
import SwiftUI

/// What the sidebar has selected — which list the middle column shows.
enum MainSection: Hashable {
    case reviewRequested
    case createdByMe
    case assignedToMe
    case inbox
    case pullRequests(RepoRef)
    case issues(RepoRef)

    /// The repo a repo section belongs to; `nil` for the cross-repo ones.
    var repo: RepoRef? {
        switch self {
        case .pullRequests(let repo), .issues(let repo): return repo
        default: return nil
        }
    }

    var isIssues: Bool {
        switch self {
        case .assignedToMe, .issues: return true
        default: return false
        }
    }
}

/// The window's navigation.
@MainActor
@Observable
final class MainWindowState {
    var section: MainSection = .reviewRequested
    var selectedPullRequest: PRRef?
    var selectedIssue: PRRef?
    /// The inbox thread being read. Kept here, not looked up by id: opening
    /// it marks it read, which takes it out of the store's unread list.
    var selectedInbox: NotificationStore.Entry?
    var expandedRepos: Set<RepoRef> = []
    /// The floating confirmation at the bottom of the window ("Up to date").
    private(set) var toast: String?
    @ObservationIgnored private var toastToken = 0
    /// Window is on screen (not minimized/closed) — CI polling only then.
    @ObservationIgnored var isVisible = true
    /// The list's search text.
    var searchText = ""
}


/// Column and window sizes. The window starts at a share of the screen, so a
/// large display doesn't get a cramped window with three squeezed columns.
enum MainWindowMetrics {
    static let sidebar = (min: CGFloat(190), ideal: CGFloat(230), max: CGFloat(320))
    static let list = (min: CGFloat(300), ideal: CGFloat(380), max: CGFloat(560))
    /// The PR/issue screen — wide enough for diffs and review threads.
    static let detailMin: CGFloat = 460

    /// The sidebar can be hidden (toolbar toggle, like Mail), so the floor
    /// is list + detail; the sidebar adds its own width when shown.
    static let minimumSize = NSSize(width: list.min + detailMin, height: 520)
    /// Bumped when the default size changes, so a frame saved under the old
    /// rules doesn't keep reopening.
    static let autosaveName = "gitbar.mainWindow.v1"

    /// Like Mail/Notes on first open: a small display (a 1280pt laptop
    /// screen) gets nearly all of it; a large one gets a generous window,
    /// capped at what three columns with an 820pt reading column need.
    static func initialSize(on screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame.size else { return NSSize(width: 1280, height: 820) }
        let widest = sidebar.ideal + list.ideal + 820 + 60
        let widthShare: CGFloat = visible.width < 1600 ? 0.94 : 0.8
        let heightShare: CGFloat = visible.height < 1000 ? 0.94 : 0.85
        let width = min(max(visible.width * widthShare, minimumSize.width), widest, visible.width)
        let height = min(max(visible.height * heightShare, minimumSize.height), visible.height)
        return NSSize(width: width.rounded(), height: height.rounded())
    }
}

/// The one main window. Closing it keeps its state, so reopening lands
/// where it was left.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let repoStore: LiveRepoStore
    private let notificationStore: NotificationStore
    private let state = MainWindowState()
    private var window: NSWindow?
    private var isOpen = false

    init(repoStore: LiveRepoStore, notificationStore: NotificationStore) {
        self.repoStore = repoStore
        self.notificationStore = notificationStore
    }

    /// What the background refresh should keep fresh while the window is
    /// open: the repos its list draws from, and the selected PR/issue.
    var refreshTargets: (repos: [RepoRef], section: MainSection, pullRequest: PRRef?, issue: PRRef?)? {
        guard isOpen, state.isVisible else { return nil }
        let repos = state.section.repo.map { [$0] } ?? repoStore.snapshots.map(\.id)
        return (repos, state.section, state.selectedPullRequest, state.selectedIssue)
    }

    func show() {
        // An accessory app must activate first, or the window opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let isNew = self.window == nil
        let window = self.window ?? makeWindow()
        self.window = window
        isOpen = true
        state.isVisible = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Nothing focused on open (no ringed field, no accent-blue list row),
        // like Mail. AppKit/SwiftUI pick a first responder after the window
        // shows, so clear it once they have.
        if isNew {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { window.makeFirstResponder(nil) }
        }
    }

    /// A repo (its PRs), or one PR or issue in it, selected in the window.
    func open(repoID: RepoRef, pullRequest: Int? = nil, issue: Int? = nil) {
        state.expandedRepos.insert(repoID)
        if let issue {
            state.section = .issues(repoID)
            state.selectedIssue = PRRef(repo: repoID, number: issue)
        } else {
            state.section = .pullRequests(repoID)
            if let pullRequest { state.selectedPullRequest = PRRef(repo: repoID, number: pullRequest) }
        }
        show()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowView(
            repoStore: repoStore, notificationStore: notificationStore, state: state))
        // The window owns its size; the content fills it.
        hosting.sizingOptions = []
        // Toolbars and titles bridge into the unified titlebar — glass
        // buttons beside the traffic lights, like Settings.
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "gitbar"
        window.isReleasedWhenClosed = false
        window.contentMinSize = MainWindowMetrics.minimumSize
        // Remembers its size/place (AppKit saves it on every move/resize);
        // with nothing saved, fit it to the screen.
        window.setFrameAutosaveName(MainWindowMetrics.autosaveName)
        if !window.setFrameUsingName(MainWindowMetrics.autosaveName) {
            window.setContentSize(MainWindowMetrics.initialSize(on: NSScreen.main))
            window.center()
        }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) { isOpen = false }
    func windowDidMiniaturize(_ notification: Notification) { state.isVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { state.isVisible = true }
}

extension MainWindowState {
    func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard token == toastToken else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    /// A manual refresh of some repos: re-fetches now, then says so.
    func refresh(_ repos: [RepoRef], label: String, store: LiveRepoStore,
                 notifications: NotificationStore? = nil) {
        showToast("Refreshing \(label)…")
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for repo in repos {
                    group.addTask { @MainActor in await store.refreshRepoDetail(repoID: repo) }
                }
                if let notifications {
                    group.addTask { @MainActor in await notifications.refresh(force: true) }
                }
            }
            await store.refresh(force: true)
            showToast(store.rateLimitWarning ?? "\(label.prefix(1).uppercased() + label.dropFirst()) is up to date")
        }
    }
}

// MARK: - Window content

/// A PR or issue together with the repo it lives in — the cross-repo lists
/// mix several repos, and numbers are only unique within one.
private struct Scoped<Item: Identifiable & Equatable>: Identifiable, Equatable where Item.ID == Int {
    let repo: RepoRef
    let item: Item
    var id: PRRef { PRRef(repo: repo, number: item.id) }
}

/// One account's pinned repos, in the sidebar.
private struct AccountGroup: Identifiable {
    let id: UUID
    let title: String
    let color: Color
    let webURL: URL?
    let provider: ProviderKind
    let repos: [RepoSnapshot]
}

private struct MainWindowView: View {
    let repoStore: LiveRepoStore
    let notificationStore: NotificationStore
    @Bindable var state: MainWindowState

    private var searchText: String { state.searchText }
    /// The toolbar's sidebar toggle hides the sidebar to give the list room.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var repos: [RepoSnapshot] { repoStore.snapshots }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MainSidebar(repoStore: repoStore, notificationStore: notificationStore, state: state,
                        groups: accountGroups, reviewRequestedCount: reviewRequested.count)
                .navigationSplitViewColumnWidth(min: MainWindowMetrics.sidebar.min,
                                                ideal: MainWindowMetrics.sidebar.ideal,
                                                max: MainWindowMetrics.sidebar.max)
        } content: {
            Group {
                if state.section == .inbox {
                    inboxList
                } else if state.section.isIssues {
                    issueList
                } else {
                    pullRequestList
                }
            }
            // The titlebar shows the list column's title: the section, and
            // the repo path or how many repos it covers.
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            // Last, so nothing wraps it and hides the column width from the split view.
            .navigationSplitViewColumnWidth(min: MainWindowMetrics.list.min,
                                            ideal: MainWindowMetrics.list.ideal,
                                            max: MainWindowMetrics.list.max)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // Window sizes for everything inside (label chips, issue screen…).
        .environment(\.detailType, .window)
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingCapsule()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: MainWindowMetrics.minimumSize.width, maxWidth: .infinity,
               minHeight: MainWindowMetrics.minimumSize.height, maxHeight: .infinity)
        // Review Requested needs every repo's PR list — also for its count.
        .task(id: repos.map(\.id)) { loadSection(state.section) }
        .onChange(of: state.section) { _, section in
            state.searchText = ""
            // A PR/issue from another repo doesn't stay open in a repo's list.
            if let repo = section.repo {
                if state.selectedPullRequest?.repo != repo { state.selectedPullRequest = nil }
                if state.selectedIssue?.repo != repo { state.selectedIssue = nil }
            }
            loadSection(section)
        }
        // `onChange` skips the initial value — a PR chosen before the window
        // first appeared (popover → "open in window") is adopted here.
        .onAppear { adoptSelectedPullRequest(state.selectedPullRequest) }
        .onChange(of: state.selectedPullRequest) { _, ref in adoptSelectedPullRequest(ref) }
        .onChange(of: state.selectedInbox) { _, entry in openInboxEntry(entry) }
        .task(id: searchNumber) { await searchRemotelyIfNeeded() }
    }

    // MARK: Titles

    private var title: String {
        switch state.section {
        case .reviewRequested: return "Review Requested"
        case .createdByMe: return "Created by Me"
        case .assignedToMe: return "Assigned to Me"
        case .inbox: return "Inbox"
        case .pullRequests(let repo), .issues(let repo): return repo.name
        }
    }

    private var subtitle: String {
        switch state.section {
        case .inbox: return "Unread, every account"
        case .pullRequests(let repo), .issues(let repo): return repo.path
        default: return repos.count == 1 ? "1 repository" : "\(repos.count) repositories"
        }
    }

    private var searchPrompt: String {
        switch state.section {
        case .inbox: return "Title, repository"
        case .pullRequests(let repo): return "Title, \(provider(repo).formatNumber(0).dropLast())number, @author"
        case .issues: return "Title, #number, @author"
        default: return "Title, @author, repository"
        }
    }

    private func provider(_ repo: RepoRef) -> ProviderKind { repoStore.provider(for: repo) }

    // MARK: Sidebar data

    private var accountGroups: [AccountGroup] {
        let byAccount = Dictionary(grouping: repos, by: \.id.accountID)
        return byAccount.compactMap { id, repos -> AccountGroup? in
            guard let badge = repoStore.accountBadges[id], let first = repos.first else { return nil }
            return AccountGroup(id: id, title: badge.title, color: badge.color.color, webURL: badge.webURL,
                                provider: first.provider, repos: repos)
        }
        .sorted { (repoStore.accountBadges[$0.id]?.position ?? 0) < (repoStore.accountBadges[$1.id]?.position ?? 0) }
    }

    /// Visiting a list loads what it draws from (each call is throttled).
    private func loadSection(_ section: MainSection) {
        switch section {
        case .reviewRequested, .inbox:
            for repo in repos { repoStore.beginRepoDetail(repoID: repo.id) }
        case .createdByMe:
            for repo in repos { repoStore.beginMinePullRequests(repoID: repo.id) }
        case .assignedToMe:
            for repo in repos { repoStore.beginAssignedIssues(repoID: repo.id) }
        case .pullRequests(let repo), .issues(let repo):
            repoStore.beginRepoDetail(repoID: repo)
        }
    }

    private func refreshSection() {
        switch state.section {
        case .pullRequests(let repo), .issues(let repo):
            state.refresh([repo], label: repo.name, store: repoStore)
        case .inbox:
            state.refresh([], label: "the inbox", store: repoStore, notifications: notificationStore)
        default:
            // Make sure the cross-repo list exists everywhere before re-reading it.
            loadSection(state.section)
            state.refresh(repos.map(\.id), label: title, store: repoStore)
        }
    }

    // MARK: Search

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// "12", "#12" or "!12" — in a repo's list, a number search can reach
    /// beyond the loaded pages.
    private var searchNumber: Int? {
        var text = trimmedSearch
        if text.hasPrefix("#") || text.hasPrefix("!") { text.removeFirst() }
        return text.isEmpty ? nil : Int(text)
    }

    private func matches(title: String, number: Int, author: String, repo: RepoRef) -> Bool {
        let query = trimmedSearch.lowercased()
        guard !query.isEmpty else { return true }
        if let searchNumber { return number == searchNumber }
        if query.hasPrefix("@") { return author.lowercased().hasPrefix(query.dropFirst()) }
        return title.lowercased().contains(query) || author.lowercased().contains(query)
            || (state.section.repo == nil && repo.path.lowercased().contains(query))
    }

    private func searchRemotelyIfNeeded() async {
        guard let repo = state.section.repo else { return }
        guard let number = searchNumber else {
            repoStore.clearPullRequestSearch(repoID: repo)
            repoStore.clearIssueSearch(repoID: repo)
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        if state.section.isIssues {
            if repoStore.issue(repoID: repo, number: number) == nil {
                await repoStore.searchIssue(repoID: repo, number: number)
            }
        } else if repoStore.detailPullRequests[repo]?.contains(where: { $0.id == number }) != true {
            await repoStore.searchPullRequest(repoID: repo, number: number)
        }
    }

    // MARK: Pull request lists

    private var reviewRequested: [Scoped<RepoPullRequest>] {
        repos.flatMap { repo in
            (repoStore.detailPullRequests[repo.id] ?? []).filter(\.isReviewRequestedFromMe)
                .map { Scoped(repo: repo.id, item: $0) }
        }
        .sorted { $0.item.source.createdAt > $1.item.source.createdAt }
    }

    /// `nil` while nothing has loaded yet (spinner rather than "none").
    private var sectionPullRequests: [Scoped<RepoPullRequest>]? {
        switch state.section {
        case .reviewRequested:
            let loaded = repos.contains { repoStore.detailPullRequests[$0.id] != nil }
            return loaded || repos.isEmpty ? reviewRequested : nil
        case .createdByMe:
            let lists = repos.compactMap { repo in repoStore.minePullRequests[repo.id].map { (repo.id, $0) } }
            if lists.isEmpty && !repos.isEmpty { return nil }
            return lists.flatMap { repo, prs in prs.map { Scoped(repo: repo, item: $0) } }
                .sorted { $0.item.source.createdAt > $1.item.source.createdAt }
        case .pullRequests(let repo):
            return repoStore.detailPullRequests[repo].map { $0.map { Scoped(repo: repo, item: $0) } }
        default:
            return []
        }
    }

    private var visiblePullRequests: [Scoped<RepoPullRequest>] {
        let filtered = (sectionPullRequests ?? []).filter {
            matches(title: $0.item.title, number: $0.item.id, author: $0.item.author, repo: $0.repo)
        }
        if filtered.isEmpty, let repo = state.section.repo, let number = searchNumber,
           let hit = repoStore.prSearchResults[repo], hit.id == number {
            return [Scoped(repo: repo, item: hit)]
        }
        return filtered
    }

    /// A list selection that ignores deselection, like Mail: clicking empty
    /// space in the list (or a search hiding the selected row) keeps the open
    /// PR/issue instead of blanking the detail column.
    private static func sticky<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(
            get: { binding.wrappedValue },
            set: { if let value = $0 { binding.wrappedValue = value } }
        )
    }

    /// The list's search, as its first row — part of the list, scrolling
    /// with it, not in the titlebar.
    private var searchRow: some View {
        ListSearchField(text: $state.searchText, prompt: searchPrompt)
            .padding(.top, 4)
            // Matches the gap above the field (from the column's title).
            .padding(.bottom, 12)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    private var pullRequestList: some View {
        let items = visiblePullRequests
        let showsRepo = state.section.repo == nil
        return List(selection: Self.sticky($state.selectedPullRequest)) {
            searchRow
            ForEach(items) { scoped in
                WindowPullRequestRow(pr: scoped.item, provider: provider(scoped.repo),
                                     repo: showsRepo ? repoChip(scoped.repo) : nil)
                    .tag(scoped.id)
            }
            if trimmedSearch.isEmpty, case .pullRequests(let repo) = state.section,
               repoStore.hasMorePullRequests[repo] == true {
                LoadMoreButton(isLoading: repoStore.isLoadingMorePullRequests[repo] == true) {
                    Task { await repoStore.loadMorePullRequests(repoID: repo) }
                }
            }
        }
        // Mail-style: inset rows with separators between them.
        .listStyle(.inset)
        .overlay {
            if items.isEmpty { emptyListMessage(pullRequestEmptyText) }
        }
    }

    private var pullRequestEmptyText: String? {
        if let repo = state.section.repo, let number = searchNumber {
            let provider = provider(repo)
            return repoStore.isSearchingPR[repo] == true ? nil
                : (repoStore.prSearchError[repo] ?? "No \(provider.pullRequestShort) \(provider.formatNumber(number)) found.")
        }
        if !trimmedSearch.isEmpty { return "No matches." }
        guard sectionPullRequests != nil else { return nil }
        switch state.section {
        case .reviewRequested: return "Nobody is waiting on your review."
        case .createdByMe: return "You have no open pull or merge requests in your pinned repos."
        case .pullRequests(let repo): return "No open \(provider(repo).pullRequestNoun)s."
        default: return nil
        }
    }

    /// The PR screen reads from the repo's main list, so a PR picked from
    /// another list (yours, a number search, the inbox) joins it first.
    private func adoptSelectedPullRequest(_ ref: PRRef?) {
        guard let ref, repoStore.detailPullRequests[ref.repo]?.contains(where: { $0.id == ref.number }) != true
        else { return }
        if let pr = repoStore.minePullRequests[ref.repo]?.first(where: { $0.id == ref.number })
            ?? repoStore.prSearchResults[ref.repo].flatMap({ $0.id == ref.number ? $0 : nil }) {
            repoStore.adoptPullRequest(pr, repoID: ref.repo)
        } else {
            Task { _ = await repoStore.loadPullRequest(repoID: ref.repo, number: ref.number) }
        }
    }

    // MARK: Issue lists

    private var sectionIssues: [Scoped<RepoIssue>]? {
        switch state.section {
        case .assignedToMe:
            let lists = repos.compactMap { repo in repoStore.assignedIssues[repo.id].map { (repo.id, $0) } }
            if lists.isEmpty && !repos.isEmpty { return nil }
            return lists.flatMap { repo, issues in issues.map { Scoped(repo: repo, item: $0) } }
                .sorted { $0.item.createdAt > $1.item.createdAt }
        case .issues(let repo):
            return repoStore.detailIssues[repo].map { $0.map { Scoped(repo: repo, item: $0) } }
        default:
            return []
        }
    }

    private var visibleIssues: [Scoped<RepoIssue>] {
        let filtered = (sectionIssues ?? []).filter {
            matches(title: $0.item.title, number: $0.item.id, author: $0.item.author, repo: $0.repo)
        }
        if filtered.isEmpty, let repo = state.section.repo, let number = searchNumber,
           let hit = repoStore.issue(repoID: repo, number: number) {
            return [Scoped(repo: repo, item: hit)]
        }
        return filtered
    }

    private var issueList: some View {
        let items = visibleIssues
        let showsRepo = state.section.repo == nil
        return List(selection: Self.sticky($state.selectedIssue)) {
            searchRow
            ForEach(items) { scoped in
                WindowIssueRow(issue: scoped.item, repo: showsRepo ? repoChip(scoped.repo) : nil)
                    .tag(scoped.id)
            }
            if trimmedSearch.isEmpty, case .issues(let repo) = state.section, repoStore.hasMoreIssues[repo] == true {
                LoadMoreButton(isLoading: repoStore.isLoadingMoreIssues[repo] == true) {
                    Task { await repoStore.loadMoreIssues(repoID: repo) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty { emptyListMessage(issueEmptyText) }
        }
    }

    private var issueEmptyText: String? {
        if let repo = state.section.repo, let number = searchNumber {
            return repoStore.isSearchingIssue[repo] == true ? nil
                : (repoStore.issueSearchError[repo] ?? "No issue #\(number) found.")
        }
        if !trimmedSearch.isEmpty { return "No matches." }
        guard sectionIssues != nil else { return nil }
        return state.section == .assignedToMe ? "No open issues assigned to you." : "No open issues."
    }

    // MARK: Inbox

    /// Unread threads, plus the one being read (opening it marks it read,
    /// which drops it from the store) so the row doesn't vanish under the pointer.
    private var inboxEntries: [NotificationStore.Entry] {
        var entries = notificationStore.entries
        if let selected = state.selectedInbox, !entries.contains(where: { $0.id == selected.id }) {
            let index = entries.firstIndex { $0.item.updatedAt < selected.item.updatedAt } ?? entries.endIndex
            entries.insert(selected, at: index)
        }
        let query = trimmedSearch.lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.item.title.lowercased().contains(query) || $0.item.repoPath.lowercased().contains(query)
        }
    }

    private var inboxList: some View {
        let entries = inboxEntries
        let unread = Set(notificationStore.entries.map(\.id))
        return List(selection: Self.sticky(Binding(
            get: { state.selectedInbox?.id },
            set: { id in state.selectedInbox = entries.first { $0.id == id } }
        ))) {
            searchRow
            ForEach(entries) { entry in
                WindowInboxRow(entry: entry, isUnread: unread.contains(entry.id))
                    .tag(entry.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if entries.isEmpty {
                emptyListMessage(notificationStore.isLoading ? nil
                                 : (trimmedSearch.isEmpty ? "You're all caught up." : "No matches."))
            }
        }
    }

    private var isPinned: (RepoRef) -> Bool {
        let pinned = Set(repos.map(\.id))
        return { pinned.contains($0) }
    }

    /// Marks it read, and loads the PR/issue when it's in a pinned repo so
    /// the detail column can show it.
    private func openInboxEntry(_ entry: NotificationStore.Entry?) {
        guard let entry else { return }
        if notificationStore.entries.contains(where: { $0.id == entry.id }) {
            Task { await notificationStore.markRead(entry) }
        }
        guard isPinned(entry.repo), let number = entry.item.number else { return }
        switch entry.item.kind {
        case .pullRequest:
            Task { _ = await repoStore.loadPullRequest(repoID: entry.repo, number: number) }
        case .issue where repoStore.issue(repoID: entry.repo, number: number) == nil:
            Task { await repoStore.searchIssue(repoID: entry.repo, number: number) }
        default:
            break
        }
    }

    // MARK: Shared pieces

    private func repoChip(_ repo: RepoRef) -> RepoChip {
        RepoChip(name: repo.name, path: repo.path,
                 color: repoStore.accountBadges[repo.accountID]?.color.color ?? Palette.accent)
    }

    /// `nil` text = still loading.
    @ViewBuilder
    private func emptyListMessage(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if state.section == .inbox {
            inboxDetail
        } else if state.section.isIssues {
            issueDetail(state.selectedIssue)
        } else {
            pullRequestDetail(state.selectedPullRequest)
        }
    }

    @ViewBuilder
    private func pullRequestDetail(_ ref: PRRef?) -> some View {
        if let ref, let pr = repoStore.detailPullRequests[ref.repo]?.first(where: { $0.id == ref.number }) {
            PRDetailScreen(repoStore: repoStore, repoID: ref.repo, pr: pr, isWindowed: true,
                           isVisible: { [state] in state.isVisible })
                .id(ref)
        } else if ref != nil {
            loading
        } else {
            placeholder(state.section.repo.map { "Select a \(provider($0).pullRequestNoun)" }
                        ?? "Select a pull or merge request")
        }
    }

    @ViewBuilder
    private func issueDetail(_ ref: PRRef?) -> some View {
        if let ref, let issue = repoStore.issue(repoID: ref.repo, number: ref.number) {
            IssueDetailScreen(repoStore: repoStore, repoID: ref.repo, issue: issue)
                .id(ref)
        } else if ref != nil {
            loading
        } else {
            placeholder("Select an issue")
        }
    }

    @ViewBuilder
    private var inboxDetail: some View {
        if let entry = state.selectedInbox {
            let item = entry.item
            if isPinned(entry.repo), let number = item.number, item.kind == .pullRequest {
                pullRequestDetail(PRRef(repo: entry.repo, number: number))
            } else if isPinned(entry.repo), let number = item.number, item.kind == .issue,
                      repoStore.isSearchingIssue[entry.repo] == true
                        || repoStore.issue(repoID: entry.repo, number: number) != nil {
                issueDetail(PRRef(repo: entry.repo, number: number))
            } else {
                // Not something the app shows itself (a release, a repo
                // that isn't pinned): offer the web page.
                VStack(spacing: 12) {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(isPinned(entry.repo) ? item.repoPath : "\(item.repoPath) isn't pinned, so it opens on the web.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let url = item.webURL {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { sectionToolbar }
            }
        } else {
            placeholder("Select a notification")
        }
    }

    private var loading: some View {
        ProgressView().controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { sectionToolbar }
    }

    /// Nothing selected. Still carries toolbar items: with none, SwiftUI
    /// drops the toolbar and the traffic lights fall back to a plain titlebar.
    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { sectionToolbar }
    }

    @ToolbarContentBuilder
    private var sectionToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let repo = state.section.repo, let url = repoStore.repoSummaries[repo]?.webURL {
                Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                    .help("Open the repository in the browser")
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: refreshSection)
                .help("Refresh")
        }
    }
}

// MARK: - Sidebar

private struct MainSidebar: View {
    let repoStore: LiveRepoStore
    let notificationStore: NotificationStore
    @Bindable var state: MainWindowState
    let groups: [AccountGroup]
    let reviewRequestedCount: Int

    var body: some View {
        List(selection: $state.section) {
            Section("For You") {
                SidebarRow(title: "Review Requested", systemImage: "eye",
                           count: reviewRequestedCount > 0 ? "\(reviewRequestedCount)" : nil,
                           countTint: RepoActivityState.needsAttention.color)
                    .tag(MainSection.reviewRequested)
                SidebarRow(title: "Created by Me", systemImage: "person",
                           count: total(repoStore.minePullRequests))
                    .tag(MainSection.createdByMe)
                SidebarRow(title: "Assigned to Me", systemImage: "checkmark.square",
                           count: total(repoStore.assignedIssues))
                    .tag(MainSection.assignedToMe)
                if NotificationSettings.isEnabled {
                    SidebarRow(title: "Inbox", systemImage: "bell",
                               count: notificationStore.unreadCount > 0 ? "\(notificationStore.unreadCount)" : nil,
                               countTint: Palette.accent)
                        .tag(MainSection.inbox)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.repos) { repo in
                        DisclosureGroup(isExpanded: expanded(repo.id)) {
                            SidebarRow(title: repo.provider.pullRequestsTitle, systemImage: "arrow.triangle.pull",
                                       count: count(repoStore.detailPullRequests[repo.id],
                                                    more: repoStore.hasMorePullRequests[repo.id]))
                                .tag(MainSection.pullRequests(repo.id))
                            SidebarRow(title: "Issues", systemImage: "circle.dotted",
                                       count: count(repoStore.detailIssues[repo.id],
                                                    more: repoStore.hasMoreIssues[repo.id]))
                                .tag(MainSection.issues(repo.id))
                        } label: {
                            RepoSidebarLabel(repo: repo, color: group.color)
                                .contextMenu { repoMenu(repo) }
                        }
                    }
                } header: {
                    AccountHeader(group: group)
                        .contextMenu { accountMenu(group) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { addMenu }
    }

    /// Only counts once at least one repo's list has loaded.
    private func total<Item>(_ lists: [RepoRef: [Item]]) -> String? {
        let loaded = groups.flatMap(\.repos).compactMap { lists[$0.id] }
        guard !loaded.isEmpty else { return nil }
        let sum = loaded.reduce(0) { $0 + $1.count }
        return sum > 0 ? "\(sum)" : nil
    }

    private func count<Item>(_ items: [Item]?, more: Bool?) -> String? {
        items.map { "\($0.count)\(more == true ? "+" : "")" }
    }

    private func expanded(_ repo: RepoRef) -> Binding<Bool> {
        Binding(
            get: { state.expandedRepos.contains(repo) },
            set: { if $0 { state.expandedRepos.insert(repo) } else { state.expandedRepos.remove(repo) } }
        )
    }

    @ViewBuilder
    private func accountMenu(_ group: AccountGroup) -> some View {
        Button("Refresh") {
            state.refresh(group.repos.map(\.id), label: group.title, store: repoStore)
        }
        Button("Pin or Unpin Repos…") { SettingsWindowController.shared.showAccount(group.id) }
        Divider()
        Button("Account Settings…") { SettingsWindowController.shared.showAccount(group.id) }
        if let url = group.webURL {
            Button("Open \(group.provider.displayName)") { NSWorkspace.shared.open(url) }
        }
    }

    @ViewBuilder
    private func repoMenu(_ repo: RepoSnapshot) -> some View {
        Button("Refresh") { state.refresh([repo.id], label: repo.name, store: repoStore) }
        if let url = repoStore.repoSummaries[repo.id]?.webURL {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
        }
    }

    private var addMenu: some View {
        HStack {
            Menu {
                Button("Add Account…") { SettingsWindowController.shared.showAddAccount() }
                if let first = groups.first {
                    Button("Pin a Repository…") { SettingsWindowController.shared.showAccount(first.id) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an account or pin a repository")
            Spacer()
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
                    // Same weight as the + menu beside it.
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            // `.borderless` shrinks and dims the symbol next to the + menu.
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct AccountHeader: View {
    let group: AccountGroup

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(group.color).frame(width: 7, height: 7)
            Text(group.title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("Right-click for account options")
    }
}

private struct RepoSidebarLabel: View {
    let repo: RepoSnapshot
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.45)))
                .frame(width: 20, height: 20)
                .overlay(
                    Image(repo.provider.logoAssetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                        .foregroundStyle(color)
                )
            Text(repo.name)
                .lineLimit(1)
        }
        .help(repo.path)
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    var count: String?
    var countTint: Color?

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 4)
            if let count {
                Text(count)
                    .font(.system(size: 11, weight: countTint == nil ? .regular : .semibold))
                    .foregroundStyle(countTint ?? .secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct LoadMoreButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Load More", action: action)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }
}

/// The native search field (rounded, magnifier, clear button) for the top
/// of the list column — SwiftUI only offers one as a toolbar/sidebar item.
private struct ListSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = ClickToFocusSearchField()
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        // Large: the toolbar-height capsule of the mockup (regular read
        // as too narrow in the 52pt strip).
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// AppKit gives a new window's focus to its first text field, so the list
/// search opened with a focus ring; this one only takes focus once clicked.
private final class ClickToFocusSearchField: NSSearchField {
    private var userFocused = false
    override var acceptsFirstResponder: Bool { userFocused }
    // The toolbar hands its first text field focus when the window becomes
    // key, whatever `acceptsFirstResponder` says.
    override func becomeFirstResponder() -> Bool {
        userFocused ? super.becomeFirstResponder() : false
    }


    override func mouseDown(with event: NSEvent) {
        userFocused = true
        super.mouseDown(with: event)
    }
}

// MARK: - List rows

/// Which repo a row in a cross-repo list belongs to, in its account's color.
private struct RepoChip: View {
    let name: String
    let path: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(path)
    }
}

private struct WindowPullRequestRow: View {
    let pr: RepoPullRequest
    let provider: ProviderKind
    var repo: RepoChip?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let repo { repo }
            Text(pr.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text("\(provider.formatNumber(pr.id)) · @\(pr.author)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !pr.labels.isEmpty {
                LabelRow(labels: pr.labels)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                ChecksStatusLabel(pr: pr)
                Spacer(minLength: 4)
                Text(pr.openedAgo)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                StatusPill(chip: pr.status)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct WindowIssueRow: View {
    let issue: RepoIssue
    var repo: RepoChip?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(issue.statusColor)
                .padding(.top, repo == nil ? 1 : 19)
            VStack(alignment: .leading, spacing: 5) {
                if let repo { repo }
                Text(issue.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text("#\(issue.id) · @\(issue.author) · \(issue.openedAgo)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !issue.labels.isEmpty || issue.commentCount > 0 || !issue.assignees.isEmpty {
                    HStack(spacing: 6) {
                        LabelRow(labels: issue.labels)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if issue.commentCount > 0 {
                            Label("\(issue.commentCount)", systemImage: "bubble.left")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                        AssigneeStack(assignees: issue.assignees)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct WindowInboxRow: View {
    let entry: NotificationStore.Entry
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.item.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.item.repoPath)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.item.title)
                    .font(.system(size: 13, weight: isUnread ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.item.reason.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.item.reasonColor)
                    Spacer(minLength: 4)
                    Text(DisplayMapper.relativeTime(from: entry.item.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Circle()
                .fill(isUnread ? Palette.accent : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
        }
        .padding(.vertical, 8)
    }
}
