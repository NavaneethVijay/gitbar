// One repo's open PRs and issues, tabbed and paginated. PR rows drill into
// `PRDetailView`; issue rows are display-only. PR wording ("Pull Requests"/
// "Merge Requests", `#12`/`!12`) comes from `repo.provider`.
import SwiftUI

enum RepoDetailMetrics {
    static let width: CGFloat = 320
    /// Fixed, not content-sized: the popover window follows its content, and
    /// resizing it on every list load / CI label / tab switch made the whole
    /// screen flicker. The list scrolls inside instead.
    static let height: CGFloat = 556
    static let headerHeight: CGFloat = 52
    /// Description line + chips. Reserved even while loading, so nothing
    /// below jumps when it arrives.
    static let summaryHeight: CGFloat = 56
    static let tabsHeight: CGFloat = 38
    static let rowHeight: CGFloat = 76
    static let rowSpacing: CGFloat = 8
    static let verticalPadding: CGFloat = 12
}

private enum DetailTab {
    case pullRequests, issues
}

struct RepoDetailView: View {
    let repo: RepoSnapshot
    /// The paginated lists; `nil` until page one arrives, in which case the
    /// snapshot's small tier-1 lists show meanwhile.
    var pullRequests: [RepoPullRequest]?
    var issues: [RepoIssue]?
    var hasMorePullRequests = false
    var hasMoreIssues = false
    var isLoadingMorePullRequests = false
    var isLoadingMoreIssues = false
    var onLoadMorePullRequests: () -> Void = {}
    var onLoadMoreIssues: () -> Void = {}
    /// A PR fetched by number because it wasn't in the loaded pages.
    var prSearchResult: RepoPullRequest?
    /// The account's own login — what "Only mine" filters on.
    var currentLogin: String?
    var isSearchingPR = false
    var prSearchError: String?
    var onSearchPR: (Int) -> Void = { _ in }
    var onClearPRSearch: () -> Void = {}
    var onBack: () -> Void = {}
    /// "Only mine", fetched server-side (`nil` until the first page arrives).
    var minePullRequests: [RepoPullRequest]?
    var hasMoreMinePullRequests = false
    var isLoadingMoreMinePullRequests = false
    var onShowMine: () -> Void = {}
    var onLoadMoreMine: () -> Void = {}
    var onSelectPR: (RepoPullRequest) -> Void = { _ in }
    var onCreatePR: () -> Void = {}
    /// The strip under the header — `nil` until `overview` arrives.
    var summary: RepoSummary?
    /// "Assigned to me", fetched server-side (`nil` until the first page arrives).
    var assignedIssues: [RepoIssue]?
    var hasMoreAssignedIssues = false
    var isLoadingMoreAssignedIssues = false
    var onShowAssigned: () -> Void = {}
    var onLoadMoreAssigned: () -> Void = {}
    /// An issue fetched by number because it wasn't in the loaded pages.
    var issueSearchResult: RepoIssue?
    var isSearchingIssue = false
    var issueSearchError: String?
    var onSearchIssue: (Int) -> Void = { _ in }
    var onClearIssueSearch: () -> Void = {}
    /// Opens this repo's window.
    var onOpenInWindow: () -> Void = {}
    /// Opens the issue in the repo window (issues have no popover screen).
    var onSelectIssue: (RepoIssue) -> Void = { _ in }

    @State private var selectedTab: DetailTab = .pullRequests
    @State private var searchText = ""
    @State private var issueSearchText = ""
    /// Remembered across repos and launches.
    @AppStorage("gitbar.prList.onlyMine") private var onlyMine = false
    @AppStorage("gitbar.issueList.assignedToMe") private var assignedToMe = false

    private var isFilteringMine: Bool { onlyMine && currentLogin != nil }
    private var isFilteringAssigned: Bool { assignedToMe && currentLogin != nil }

    /// Your review is being asked for — the summary strip's "needs you" chip.
    private var reviewRequestedCount: Int { displayedPRs.filter(\.isReviewRequestedFromMe).count }

    private var issueSearchNumber: Int? {
        let trimmed = issueSearchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    /// Same rules as `filteredPRs`: a number finds that issue anywhere.
    private var filteredIssues: [RepoIssue] {
        guard let number = issueSearchNumber else {
            return isFilteringAssigned ? (assignedIssues ?? []) : displayedIssues
        }
        if let local = displayedIssues.first(where: { $0.id == number }) { return [local] }
        if let local = assignedIssues?.first(where: { $0.id == number }) { return [local] }
        if let remote = issueSearchResult, remote.id == number { return [remote] }
        return []
    }

    private var displayedPRs: [RepoPullRequest] { pullRequests ?? repo.pullRequests }
    private var displayedIssues: [RepoIssue] { issues ?? repo.issues }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var searchNumber: Int? { trimmedSearch.isEmpty ? nil : Int(trimmedSearch) }

    /// Everything loaded, or — while a number is typed — just that PR (a
    /// local hit first, else the direct-fetch result).
    /// A number search finds that PR in the full list regardless of "Only
    /// mine"; otherwise the list is the full one or the server-side "mine" one.
    private var filteredPRs: [RepoPullRequest] {
        guard let number = searchNumber else {
            return isFilteringMine ? (minePullRequests ?? []) : displayedPRs
        }
        if let local = displayedPRs.first(where: { $0.id == number }) { return [local] }
        if let remote = prSearchResult, remote.id == number { return [remote] }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RepoSummaryStrip(summary: summary, reviewRequestedCount: reviewRequestedCount)
            tabs
            if selectedTab == .pullRequests {
                searchField
            } else {
                issueSearchField
            }

            ScrollView {
                // Lazy: after a few "Load more" pages there can be hundreds of rows.
                LazyVStack(spacing: RepoDetailMetrics.rowSpacing) {
                    switch selectedTab {
                    case .pullRequests:
                        if let number = searchNumber, filteredPRs.isEmpty {
                            if isSearchingPR {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small).scaleEffect(0.7)
                                    Text("Searching \(repo.provider.pullRequestShort) \(repo.provider.formatNumber(number))…")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.vertical, 20)
                            } else {
                                Text(prSearchError ?? "No \(repo.provider.pullRequestShort) \(repo.provider.formatNumber(number)) found.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Palette.textTertiary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 20)
                            }
                        } else {
                            if searchNumber == nil, isFilteringMine, minePullRequests == nil {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small).scaleEffect(0.7)
                                    Text("Loading your \(repo.provider.pullRequestShort)s…")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.vertical, 20)
                            } else if searchNumber == nil, isFilteringMine, filteredPRs.isEmpty {
                                Text("You have no open \(repo.provider.pullRequestNoun)s here.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Palette.textTertiary)
                                    .padding(.vertical, 20)
                            }
                            ForEach(filteredPRs) { pr in
                                PullRequestRow(pr: pr, provider: repo.provider, onSelect: { onSelectPR(pr) })
                            }
                            if searchNumber == nil {
                                if isFilteringMine, hasMoreMinePullRequests {
                                    LoadMoreRow(isLoading: isLoadingMoreMinePullRequests, action: onLoadMoreMine)
                                } else if !isFilteringMine, hasMorePullRequests {
                                    LoadMoreRow(isLoading: isLoadingMorePullRequests, action: onLoadMorePullRequests)
                                }
                            }
                        }
                    case .issues:
                        issueList
                    }
                }
                .padding(.vertical, RepoDetailMetrics.verticalPadding)
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: RepoDetailMetrics.width, height: RepoDetailMetrics.height, alignment: .top)
        // Ticking "Only mine" (or opening a repo with it already on) asks the
        // provider for just your PRs.
        .task(id: isFilteringMine) {
            if isFilteringMine { onShowMine() }
        }
        .task(id: isFilteringAssigned) {
            if isFilteringAssigned { onShowAssigned() }
        }
        .task(id: issueSearchText) {
            guard let number = issueSearchNumber else {
                onClearIssueSearch()
                return
            }
            guard !displayedIssues.contains(where: { $0.id == number }),
                  assignedIssues?.contains(where: { $0.id == number }) != true else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            onSearchIssue(number)
        }
        // `.task(id:)` cancels the previous run on each keystroke — a debounce.
        .task(id: searchText) {
            guard let number = searchNumber else {
                onClearPRSearch()
                return
            }
            guard !displayedPRs.contains(where: { $0.id == number }) else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            onSearchPR(number)
        }
    }

    @ViewBuilder
    private var issueList: some View {
        if let number = issueSearchNumber, filteredIssues.isEmpty {
            if isSearchingIssue {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Searching issue #\(number)…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(.vertical, 20)
            } else {
                Text(issueSearchError ?? "No issue #\(number) found.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
            }
        } else if issueSearchNumber == nil, isFilteringAssigned, assignedIssues == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Loading your issues…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.vertical, 20)
        } else if filteredIssues.isEmpty, !(isFilteringAssigned ? isLoadingMoreAssignedIssues : isLoadingMoreIssues) {
            Text(isFilteringAssigned ? "No open issues assigned to you." : "No open issues.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textTertiary)
                .padding(.vertical, 20)
        } else {
            ForEach(filteredIssues) { issue in
                IssueRow(issue: issue, onSelect: { onSelectIssue(issue) })
            }
            if issueSearchNumber == nil {
                if isFilteringAssigned, hasMoreAssignedIssues {
                    LoadMoreRow(isLoading: isLoadingMoreAssignedIssues, action: onLoadMoreAssigned)
                } else if !isFilteringAssigned, hasMoreIssues {
                    LoadMoreRow(isLoading: isLoadingMoreIssues, action: onLoadMoreIssues)
                }
            }
        }
    }

    private var issueSearchField: some View {
        HStack(spacing: 10) {
            NumberSearchBox(placeholder: "Search issue by number", text: $issueSearchText)
            Toggle("Assigned to me", isOn: $assignedToMe)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .disabled(currentLogin == nil)
                .help(currentLogin.map { "Only issues assigned to @\($0)" } ?? "")
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            NumberSearchBox(placeholder: "Search \(repo.provider.pullRequestShort) by number", text: $searchText)
            Toggle("Only mine", isOn: $onlyMine)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .disabled(currentLogin == nil)
                .help(currentLogin.map { "Only \(repo.provider.pullRequestShort)s opened by @\($0)" } ?? "")
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(action: onBack)

            RoundedRectangle(cornerRadius: 7)
                .fill(repo.state.color.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(repo.state.color.opacity(0.4)))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "book.closed")
                        .font(.system(size: 12))
                        .foregroundStyle(repo.state.color)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(repo.path)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 4)

            WindowButton(action: onOpenInWindow)
            NewPRButton(provider: repo.provider, action: onCreatePR)
        }
        .padding(.horizontal, 12)
        .frame(height: RepoDetailMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
        }
    }

    private var tabs: some View {
        HStack(spacing: 16) {
            // Counts reflect the pages loaded so far ("+" while there's more).
            TabLabel(isFilteringMine
                     ? "\(repo.provider.pullRequestsTitle) \(minePullRequests?.count ?? 0)\(hasMoreMinePullRequests ? "+" : "")"
                     : "\(repo.provider.pullRequestsTitle) \(displayedPRs.count)\(hasMorePullRequests ? "+" : "")",
                    isSelected: selectedTab == .pullRequests) {
                selectedTab = .pullRequests
            }
            TabLabel("Issues \(displayedIssues.count)\(hasMoreIssues ? "+" : "")",
                    isSelected: selectedTab == .issues) {
                selectedTab = .issues
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: RepoDetailMetrics.tabsHeight, alignment: .bottom)
    }
}

private struct TabLabel: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isSelected ? Palette.textPrimary : (isHovered ? Palette.tabHover : Palette.tabIdle))
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Palette.accent : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .hoverHighlight($isHovered)
    }
}

/// Opens the repo window — a quiet circle beside "New PR".
private struct WindowButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "macwindow")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.wash.opacity(isHovered ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .help("Open in a window")
        .hoverHighlight($isHovered)
    }
}

/// The digits-only search field above each list.
private struct NumberSearchBox: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textPrimary)
                .onChange(of: text) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue { text = digitsOnly }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.wash.opacity(0.06)))
    }
}

/// Description, then one line of chips: default-branch CI, latest release,
/// stars, and how many PRs are waiting on your review. Fixed height, so the
/// lists below don't move when it loads.
private struct RepoSummaryStrip: View {
    let summary: RepoSummary?
    let reviewRequestedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(summary?.description ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(summary?.description ?? "")
            FirstFitRow(spacing: 6) {
                if let summary {
                    branchChip(summary)
                    if let release = summary.releaseText {
                        SummaryChip(systemImage: "tag", text: release)
                            .help("Latest release")
                    }
                    if let stars = summary.starsText {
                        SummaryChip(systemImage: "star", text: stars)
                            .help("Stars")
                    }
                }
                if reviewRequestedCount > 0 {
                    SummaryChip(systemImage: nil, text: "\(reviewRequestedCount) needs you",
                                tint: RepoActivityState.needsAttention.color)
                        .help("Your review is requested on \(reviewRequestedCount == 1 ? "one" : "\(reviewRequestedCount)") of these")
                }
            }
            .frame(minHeight: 18)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .frame(maxWidth: .infinity, minHeight: RepoDetailMetrics.summaryHeight,
               maxHeight: RepoDetailMetrics.summaryHeight, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: summary)
    }

    @ViewBuilder
    private func branchChip(_ summary: RepoSummary) -> some View {
        let branch = summary.defaultBranch
        switch summary.branchChecks {
        case .passed:
            SummaryChip(systemImage: "checkmark.circle", text: branch, tint: Palette.success)
                .help("CI on \(branch) passed")
        case .failing:
            SummaryChip(systemImage: "xmark.circle", text: branch, tint: Palette.danger)
                .help("CI on \(branch) is failing")
        case .running:
            SummaryChip(systemImage: nil, text: branch, tint: RepoActivityState.busy.color, isRunning: true)
                .help("CI on \(branch) is running")
        case .some(.none), .some(.other), nil:
            SummaryChip(systemImage: "arrow.triangle.branch", text: branch)
                .help("Default branch")
        }
    }
}

/// One capsule in the summary strip — neutral unless tinted.
private struct SummaryChip: View {
    let systemImage: String?
    let text: String
    var tint: Color? = nil
    var isRunning = false

    var body: some View {
        HStack(spacing: 4) {
            if isRunning {
                SpinningArc(color: tint ?? Palette.textSecondary, arcFraction: 0.6)
                    .frame(width: 9, height: 9)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: tint == nil ? .regular : .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(tint ?? Palette.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((tint ?? Palette.wash).opacity(tint == nil ? 0.07 : 0.13)))
    }
}

/// Opens `CreatePullRequestView` — an accent pill, the screen's primary action.
private struct NewPRButton: View {
    let provider: ProviderKind
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("New \(provider.pullRequestShort)", systemImage: "plus")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Palette.accent.opacity(isHovered ? 0.22 : 0.14)))
                .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help("Create a \(provider.pullRequestNoun)")
        .hoverHighlight($isHovered)
    }
}

/// The back chevron, with a hover highlight — shared with the other screens.
struct BackButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Palette.wash.opacity(isHovered ? 0.1 : 0))
                )
        }
        .buttonStyle(.plain)
        .hoverHighlight($isHovered)
    }
}

private struct PullRequestRow: View {
    let pr: RepoPullRequest
    let provider: ProviderKind
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pr.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(provider.formatNumber(pr.id)) opened by @\(pr.author)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            if !pr.labels.isEmpty {
                LabelRow(labels: pr.labels)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                ChecksStatusLabel(pr: pr)
                Spacer(minLength: 4)
                // Beside the pill rather than after the author, where a long
                // username would truncate it away.
                Text(pr.openedAgo)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                StatusPill(chip: pr.status)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Owns its height so the hover highlight fills the whole row.
        .frame(maxWidth: .infinity, minHeight: RepoDetailMetrics.rowHeight, alignment: .leading)
        .background(Palette.wash.opacity(isHovered ? 0.07 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .hoverHighlight($isHovered)
    }
}

private struct LoadMoreRow: View {
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Text("Load more")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isHovered ? Palette.tabHover : Palette.tabIdle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if !isLoading { action() } }
        .hoverHighlight($isHovered, enabled: !isLoading)
    }
}

/// Clicking opens the issue in the repo window (the popover has no issue
/// screen). Issues are always `#N`, even where PRs are `!N`.
private struct IssueRow: View {
    let issue: RepoIssue
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 13))
                .foregroundStyle(issue.statusColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("#\(issue.id) opened by @\(issue.author) · \(issue.openedAgo)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                if !issue.labels.isEmpty || issue.commentCount > 0 || !issue.assignees.isEmpty {
                    HStack(spacing: 6) {
                        LabelRow(labels: issue.labels)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if issue.commentCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 9.5))
                                Text("\(issue.commentCount)")
                                    .font(.system(size: 10.5))
                            }
                            .foregroundStyle(Palette.textSecondary)
                            .help("\(issue.commentCount) comment\(issue.commentCount == 1 ? "" : "s")")
                        }
                        AssigneeStack(assignees: issue.assignees)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Owns its height so the hover highlight fills the whole row.
        .frame(maxWidth: .infinity, minHeight: RepoDetailMetrics.rowHeight, alignment: .leading)
        .background(Palette.wash.opacity(isHovered ? 0.07 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .hoverHighlight($isHovered)
        .help("Open in the repo window")
    }
}

/// Up to two overlapping initials circles; yours in the accent color.
struct AssigneeStack: View {
    let assignees: [RepoIssue.Assignee]

    var body: some View {
        if !assignees.isEmpty {
            HStack(spacing: -5) {
                ForEach(assignees.prefix(2)) { assignee in
                    Text(assignee.initials)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(assignee.isMe ? Color.white : Palette.textPrimary)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(assignee.isMe ? Palette.accent : Palette.wash.opacity(0.16)))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor).opacity(0.8), lineWidth: 1))
                }
            }
            .help("Assigned to " + assignees.map { $0.isMe ? "you" : "@\($0.login)" }.joined(separator: ", "))
        }
    }
}
