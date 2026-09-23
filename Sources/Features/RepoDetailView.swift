// One repo's open PRs and issues, tabbed and paginated. PR rows drill into
// `PRDetailView`; issue rows are display-only. PR wording ("Pull Requests"/
// "Merge Requests", `#12`/`!12`) comes from `repo.provider`.
import SwiftUI

enum RepoDetailMetrics {
    static let width: CGFloat = 320
    static let headerHeight: CGFloat = 52
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
    var isSearchingPR = false
    var prSearchError: String?
    var onSearchPR: (Int) -> Void = { _ in }
    var onClearPRSearch: () -> Void = {}
    var onBack: () -> Void = {}
    var onSelectPR: (RepoPullRequest) -> Void = { _ in }
    var onCreatePR: () -> Void = {}

    @State private var selectedTab: DetailTab = .pullRequests
    @State private var searchText = ""

    private var displayedPRs: [RepoPullRequest] { pullRequests ?? repo.pullRequests }
    private var displayedIssues: [RepoIssue] { issues ?? repo.issues }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var searchNumber: Int? { trimmedSearch.isEmpty ? nil : Int(trimmedSearch) }

    /// Everything loaded, or — while a number is typed — just that PR (a
    /// local hit first, else the direct-fetch result).
    private var filteredPRs: [RepoPullRequest] {
        guard let number = searchNumber else { return displayedPRs }
        if let local = displayedPRs.first(where: { $0.id == number }) { return [local] }
        if let remote = prSearchResult, remote.id == number { return [remote] }
        return []
    }

    /// The popover sizes itself to its content, so the list must be capped
    /// or "Load more" would grow it past the screen.
    private static let listMaxHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            if selectedTab == .pullRequests {
                searchField
            }

            ScrollView {
                VStack(spacing: RepoDetailMetrics.rowSpacing) {
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
                            ForEach(filteredPRs) { pr in
                                PullRequestRow(pr: pr, provider: repo.provider, onSelect: { onSelectPR(pr) })
                            }
                            if searchNumber == nil, hasMorePullRequests {
                                LoadMoreRow(isLoading: isLoadingMorePullRequests, action: onLoadMorePullRequests)
                            }
                        }
                    case .issues:
                        if displayedIssues.isEmpty && !isLoadingMoreIssues {
                            Text("No open issues.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.textTertiary)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(displayedIssues) { issue in
                                IssueRow(issue: issue)
                            }
                            if hasMoreIssues {
                                LoadMoreRow(isLoading: isLoadingMoreIssues, action: onLoadMoreIssues)
                            }
                        }
                    }
                }
                .padding(.vertical, RepoDetailMetrics.verticalPadding)
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: Self.listMaxHeight)
        }
        .frame(width: RepoDetailMetrics.width)
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
            TextField("Search \(repo.provider.pullRequestShort) by number", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textPrimary)
                .onChange(of: searchText) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue { searchText = digitsOnly }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
            TabLabel("\(repo.provider.pullRequestsTitle) \(displayedPRs.count)\(hasMorePullRequests ? "+" : "")",
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
            HStack {
                Text(pr.checksLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(pr.checksColor)
                Spacer()
                Text(pr.chipLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pr.chipColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(pr.chipColor.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(pr.chipColor.opacity(0.35)))
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

/// Display-only. Issues are always `#N`, even where PRs are `!N`.
private struct IssueRow: View {
    let issue: RepoIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 13))
                .foregroundStyle(issue.statusColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("#\(issue.id) opened by @\(issue.author) · \(issue.metaLabel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: RepoDetailMetrics.rowHeight, alignment: .leading)
    }
}
