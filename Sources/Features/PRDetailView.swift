// One PR's full detail: state, branches, description, reviewers, checks and
// comments. The thread is read-only; the composer submits a formal review.
import AppKit
import SwiftUI

enum PRDetailMetrics {
    static let width: CGFloat = 380
    /// Fixed for the same reason as `RepoDetailMetrics.height`; the body
    /// scrolls between the pinned header and composer.
    static let height: CGFloat = 620
}

struct PRDetailView: View {
    let pr: RepoPullRequest
    /// Per section, so whichever answers first renders first.
    var isLoadingChecks: Bool = false
    var isLoadingComments: Bool = false
    var isLoadingReviewers: Bool = false
    var isLoadingFiles: Bool = false
    var isSubmittingReview: Bool = false
    var reviewSubmitError: String?
    /// For wording — "PR"/"MR" and `#12`/`!12`.
    var provider: ProviderKind = .github
    /// Hidden for providers without a separate "request changes" verdict.
    var canRequestChanges = true
    var onSubmitReview: (_ decision: ReviewDecision, _ body: String) -> Void = { _, _ in }
    /// A plain reply into the thread, no verdict.
    var onAddComment: (_ body: String) -> Void = { _ in }
    var isRefreshingDetail: Bool = false
    var onRefresh: () -> Void = {}
    var onBack: () -> Void = {}
    /// In its own window: flexible size, no back button.
    var isWindowed = false
    /// Pops the PR out into its own window; hidden when `nil`.
    var onOpenInWindow: (() -> Void)?
    /// The repo's path, for the window's subtitle.
    var repoPath: String = ""
    /// Re-fetches the check runs — called every `checksPollInterval` while
    /// CI is running and this screen is up.
    var onPollChecks: () async -> Void = {}

    private static let checksPollInterval: Duration = .seconds(20)

    @State private var reviewDraft = ""
    @State private var showReviewSubmittedToast = false
    /// What the in-flight submission was, for the toast's wording.
    @State private var submittedComment = false
    /// Window only: files whose diff is open, by filename.
    @State private var expandedFiles: Set<String> = []

    private var draftIsEmpty: Bool {
        reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The window's content column: wide windows center it rather than
    /// stretching lines of text edge to edge.
    private static let readableWidth: CGFloat = 820

    private var horizontalPadding: CGFloat { isWindowed ? 24 : 14 }

    var body: some View {
        layout
        .modifier(PRDetailFrame(isWindowed: isWindowed))
        // Live CI: while anything is running, keep re-reading the check runs
        // so spinners turn into results without a manual refresh.
        .task(id: pr.areChecksRunning) {
            guard pr.areChecksRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checksPollInterval)
                guard !Task.isCancelled else { return }
                await onPollChecks()
            }
        }
        .overlay(alignment: .top) {
            if showReviewSubmittedToast {
                ReviewSubmittedToast(title: submittedComment ? "Comment posted" : "Review submitted")
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Clear the draft only when a submission finishes without an error —
        // a failure must never lose what was typed.
        .onChange(of: isSubmittingReview) { wasSubmitting, isSubmitting in
            guard wasSubmitting, !isSubmitting, reviewSubmitError == nil else { return }
            reviewDraft = ""
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showReviewSubmittedToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                withAnimation(.easeOut(duration: 0.25)) { showReviewSubmittedToast = false }
            }
        }
    }

    @ViewBuilder
    private var layout: some View {
        if isWindowed {
            windowLayout
        } else {
            popoverLayout
        }
    }

    /// Fixed-size popover screen: header and composer pinned, sections scroll.
    private var popoverLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sections
                }
            }
            .frame(maxHeight: .infinity)

            divider
            composer
        }
    }

    /// Standalone window, current macOS style: actions live in the unified
    /// titlebar as glass toolbar buttons, the title and repo in the titlebar,
    /// and everything else scrolls under it in one readable column.
    private var windowLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    divider
                    sections
                }
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            divider
            composer
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(pr.title)
        .navigationSubtitle(repoPath.isEmpty ? provider.formatNumber(pr.id)
                                             : "\(repoPath) \(provider.formatNumber(pr.id))")
        .toolbar { windowToolbar }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let url = pr.webURL {
                Button("Copy Link", systemImage: "link") { copyToPasteboard(url.absoluteString) }
                    .help("Copy link")
                Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                    .help("Open in browser")
            }
        }
        ToolbarItem {
            if isRefreshingDetail {
                ProgressView().controlSize(.small)
                    .help("Refreshing…")
            } else {
                Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    .help("Refresh")
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        metaRow
        divider
        branchRow
        divider
        description
        divider
        reviewersSection
        divider
        checksSection
        divider
        if isWindowed {
            windowFilesSection
        } else {
            filesSection
        }
        divider
        commentsSection
    }

    /// Each file is its own row of the enclosing `LazyVStack`, so a PR with
    /// 100 files only builds the ones scrolled into view.
    @ViewBuilder
    private var windowFilesSection: some View {
        HStack(spacing: 10) {
            SectionLabel("Files changed · \(pr.files.count)")
            Spacer(minLength: 0)
            if !pr.files.isEmpty {
                let allOpen = expandedFiles.count >= pr.files.count
                Button(allOpen ? "Collapse All" : "Expand All") {
                    expandedFiles = allOpen ? [] : Set(pr.files.map(\.id))
                }
                .buttonStyle(.link)
                .font(.system(size: 10.5, weight: .semibold))
            }
            if let diffURL = pr.diffURL {
                ViewDiffLink(url: diffURL)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, pr.files.isEmpty ? 4 : 8)

        if pr.files.isEmpty {
            Group {
                if isLoadingFiles {
                    loadingRow
                } else {
                    Text("No file changes.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 12)
        } else {
            ForEach(pr.files) { file in
                DiffFileView(
                    file: file,
                    webDiffURL: pr.diffURL,
                    isExpanded: Binding(
                        get: { expandedFiles.contains(file.id) },
                        set: { open in
                            if open { expandedFiles.insert(file.id) } else { expandedFiles.remove(file.id) }
                        })
                )
                .padding(.horizontal, horizontalPadding - 4)
                .padding(.bottom, 4)
            }
            Color.clear.frame(height: 8)
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text("Loading…")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if !isWindowed {
                BackButton(action: onBack)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    StatusPill(chip: pr.status)
                    if let url = pr.webURL {
                        PRNumberLink(text: provider.formatNumber(pr.id), url: url)
                    } else {
                        Text(provider.formatNumber(pr.id))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tabIdle)
                    }
                }
                Text(pr.title)
                    .font(.system(size: isWindowed ? 16 : 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = pr.webURL {
                    PRLinkRow(url: url)
                }
            }

            Spacer(minLength: 4)

            if !isWindowed {
                if let onOpenInWindow {
                    HeaderIconButton(systemImage: "macwindow", help: "Open in a separate window", action: onOpenInWindow)
                        .padding(.top, 1)
                }
                RefreshButton(isRefreshing: isRefreshingDetail, action: onRefresh)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, isWindowed ? 16 : 12)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LinearGradient(colors: [Palette.attention, Palette.danger],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 18, height: 18)
                .overlay(Text(pr.initials).font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white))
            Text("\(pr.author) opened this \(pr.openedAgo)")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
    }

    private var branchRow: some View {
        HStack(spacing: 8) {
            BranchChip(name: pr.headBranch)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            BranchChip(name: pr.baseBranch)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
    }

    private var description: some View {
        RenderedBodyText(markdown: pr.description, fontSize: 12, textColor: Palette.textBody)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
    }

    private var reviewersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Reviewers")
            if pr.reviewers.isEmpty && isLoadingReviewers {
                loadingRow
            } else if pr.reviewers.isEmpty {
                Text("No reviewers requested.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(pr.reviewers) { reviewer in
                        ReviewerRow(reviewer: reviewer)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel("Checks")
                Spacer(minLength: 0)
                ChecksStatusLabel(pr: pr, fontSize: 10.5)
            }
            if pr.checks.isEmpty && isLoadingChecks {
                loadingRow
            } else if pr.checks.isEmpty {
                Text("No checks reported.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
            }
            VStack(spacing: 6) {
                ForEach(pr.checks) { check in
                    CheckRow(check: check)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel("Files changed · \(pr.files.count)")
                Spacer(minLength: 0)
                if let diffURL = pr.diffURL {
                    ViewDiffLink(url: diffURL)
                }
            }
            if pr.files.isEmpty && isLoadingFiles {
                loadingRow
            } else if pr.files.isEmpty {
                Text("No file changes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(pr.files) { file in
                        FileChangeRow(file: file)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Comments · \(pr.comments.count)")
            if pr.comments.isEmpty && isLoadingComments {
                loadingRow
            } else if pr.comments.isEmpty {
                Text("No comments yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(pr.comments) { comment in
                        CommentBubble(comment: comment)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
    }

    /// "Comment" replies into the thread; Approve / Request changes submit
    /// a formal review.
    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let reviewSubmitError {
                Text(reviewSubmitError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.wash.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.wash.opacity(0.08)))
                if reviewDraft.isEmpty {
                    Text("Leave a comment — optional for Approve")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textPlaceholder)
                        .padding(10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reviewDraft)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(isSubmittingReview)
            }
            .frame(height: isWindowed ? 72 : 52)

            HStack(spacing: 8) {
                if isSubmittingReview {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 0)
                if isWindowed {
                    nativeReviewActions
                } else {
                    ReviewActionButton(title: "Comment", color: Palette.neutral, isDisabled: isSubmittingReview || draftIsEmpty) {
                        submittedComment = true
                        onAddComment(reviewDraft)
                    }
                    if canRequestChanges {
                        ReviewActionButton(title: "Request changes", color: Palette.danger, isDisabled: isSubmittingReview) {
                            submittedComment = false
                            onSubmitReview(.requestChanges, reviewDraft)
                        }
                    }
                    ReviewActionButton(title: "Approve", color: RepoActivityState.idle.color, isDisabled: isSubmittingReview) {
                        submittedComment = false
                        onSubmitReview(.approve, reviewDraft)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
    }
}

private extension PRDetailView {
    /// Stock buttons in the window — the system draws them in the current
    /// macOS style (Liquid Glass on 26) instead of the popover's pills.
    @ViewBuilder
    var nativeReviewActions: some View {
        Button("Comment") {
            submittedComment = true
            onAddComment(reviewDraft)
        }
        .disabled(isSubmittingReview || draftIsEmpty)
        if canRequestChanges {
            Button("Request Changes") {
                submittedComment = false
                onSubmitReview(.requestChanges, reviewDraft)
            }
            .tint(Palette.danger)
            .disabled(isSubmittingReview)
        }
        Button("Approve") {
            submittedComment = false
            onSubmitReview(.approve, reviewDraft)
        }
        .buttonStyle(.borderedProminent)
        .tint(RepoActivityState.idle.color)
        .disabled(isSubmittingReview)
    }
}

private struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 26, height: 26)
            .background(Circle().fill(Palette.wash.opacity(isHovered ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .hoverHighlight($isHovered, enabled: !isRefreshing)
    }
}

private struct ReviewSubmittedToast: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(RepoActivityState.idle.color)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingCapsule()
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Palette.textTertiary)
    }
}

private struct BranchChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Palette.textComment)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.wash.opacity(0.06)))
    }
}

/// "Details" links to the CI provider's own run page, when the check has one.
private struct CheckRow: View {
    let check: PRCheck

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 14, height: 14)
            Text(check.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textStrong)
            Spacer(minLength: 0)
            if check.status == .running {
                Text("Running…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textTertiary)
            } else if check.status == .skipped {
                Text("Skipped")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textTertiary)
            }
            if let url = check.detailsURL {
                Text("Details")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isHovered ? Palette.accentHover : Palette.accent)
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .hoverHighlight($isHovered)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch check.status {
        case .running:
            SpinningArc(color: RepoActivityState.busy.color, arcFraction: 0.6)
                .frame(width: 11, height: 11)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(RepoActivityState.idle.color)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.danger)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.neutral)
        case .neutral:
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.neutral)
        }
    }
}

/// Opens the PR's diff view (`{webURL}/files`) on the web.
private struct ViewDiffLink: View {
    let url: URL

    @State private var isHovered = false

    var body: some View {
        Text("View diff ↗")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(isHovered ? Palette.accentHover : Palette.accent)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
            .hoverHighlight($isHovered)
    }
}

/// One file's line in the list — also the header of `DiffFileView`.
struct FileChangeRow: View {
    let file: PRFileChange

    private var glyph: String {
        switch file.status {
        case .added: return "plus"
        case .removed: return "minus"
        default: return "circle.fill"
        }
    }

    private var color: Color {
        switch file.status {
        case .added: return RepoActivityState.idle.color
        case .removed: return Palette.danger
        default: return Palette.neutral
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: file.status == .added || file.status == .removed ? 11 : 6, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 13)
            Text(file.filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .foregroundStyle(RepoActivityState.idle.color)
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .foregroundStyle(Palette.danger)
                }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        }
    }
}

private struct ReviewerRow: View {
    let reviewer: PRReviewer

    private var hasBody: Bool {
        !(reviewer.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasBody ? 6 : 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LinearGradient(colors: [Palette.accent, Palette.accentPurple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 20, height: 20)
                    .overlay(Text(reviewer.initials).font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                Text(reviewer.login)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textStrong)
                Spacer(minLength: 0)
                Text(reviewer.state.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(reviewer.state.color)
            }
            if hasBody {
                RenderedBodyText(markdown: reviewer.text ?? "", fontSize: 11.5, textColor: Palette.textComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
        }
    }
}

/// A pill action button, also used by `CreatePullRequestView`.
struct ReviewActionButton: View {
    let title: String
    let color: Color
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color.opacity(isDisabled ? 0.5 : 1))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(isHovered && !isDisabled ? 0.22 : 0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4)))
            .contentShape(Rectangle())
            .onTapGesture { if !isDisabled { action() } }
            .hoverHighlight($isHovered, enabled: !isDisabled)
    }
}

private struct CommentBubble: View {
    let comment: PRComment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(LinearGradient(colors: [Palette.accent, Palette.accentPurple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay(Text(comment.initials).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(comment.author).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                    Text("· \(comment.timeAgo)").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                }
                RenderedBodyText(markdown: comment.text, fontSize: 11.5, textColor: Palette.textComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.wash.opacity(0.04)))
            }
        }
    }
}

/// Popover: the fixed size from `PRDetailMetrics`. Window: fills it.
private struct PRDetailFrame: ViewModifier {
    let isWindowed: Bool

    func body(content: Content) -> some View {
        if isWindowed {
            content.frame(minWidth: 460, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(width: PRDetailMetrics.width, height: PRDetailMetrics.height, alignment: .top)
        }
    }
}

/// The PR's state as a colored pill — also used by the repo screen's rows.
struct StatusPill: View {
    let chip: PRStatusChip
    var fontSize: CGFloat = 10

    var body: some View {
        Text(chip.label)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(chip.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(chip.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(chip.color.opacity(0.35)))
    }
}

/// Combined CI status: a spinner while anything is still running, else the
/// static label. Empty until the summary (or the check runs) arrive.
struct ChecksStatusLabel: View {
    let pr: RepoPullRequest
    var fontSize: CGFloat = 10.5

    var body: some View {
        if pr.areChecksRunning {
            HStack(spacing: 5) {
                SpinningArc(color: RepoActivityState.busy.color, arcFraction: 0.6)
                    .frame(width: fontSize - 1, height: fontSize - 1)
                Text("Checks running")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(RepoActivityState.busy.color)
            }
        } else if !pr.checksLabel.isEmpty {
            Text(pr.checksLabel)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(pr.checksColor)
        }
    }
}

/// `#12` next to the status pill — opens the PR on the web.
private struct PRNumberLink: View {
    let text: String
    let url: URL

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Text(text)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isHovered ? Palette.accentHover : Palette.accent)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(url) }
        .hoverHighlight($isHovered)
        .help("Open in browser")
        .contextMenu { LinkMenuItems(url: url) }
    }
}

/// The PR's web address under its title: click to open, copy button beside it.
private struct PRLinkRow: View {
    let url: URL

    @State private var isHovered = false
    @State private var copied = false

    private var displayText: String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            Text(displayText)
                .font(.system(size: 10.5))
                .foregroundStyle(isHovered ? Palette.accentHover : Palette.accent)
                .underline(isHovered)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(url) }
                .hoverHighlight($isHovered)
                .help(url.absoluteString)
                .contextMenu { LinkMenuItems(url: url) }
            Button {
                copyToPasteboard(url.absoluteString)
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(copied ? RepoActivityState.idle.color : Palette.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Copy link")
        }
    }
}

private struct LinkMenuItems: View {
    let url: URL
    var body: some View {
        Button("Open in Browser") { NSWorkspace.shared.open(url) }
        Button("Copy Link") { copyToPasteboard(url.absoluteString) }
    }
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// A round icon button matching `RefreshButton`.
private struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.wash.opacity(isHovered ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .hoverHighlight($isHovered)
    }
}

/// `PRDetailView` wired to the store — shared by the popover's PR screen and
/// the standalone PR window, so both behave identically.
struct PRDetailScreen: View {
    let repoStore: LiveRepoStore
    let repoID: RepoRef
    let pr: RepoPullRequest
    var isWindowed = false
    var onBack: () -> Void = {}
    var onOpenInWindow: (() -> Void)?
    /// Whether the screen is actually on screen — no CI polling otherwise.
    var isVisible: @MainActor () -> Bool = { true }

    var body: some View {
        PRDetailView(
            pr: pr,
            isLoadingChecks: repoStore.isLoadingChecks(repoID: repoID, prID: pr.id),
            isLoadingComments: repoStore.isLoadingComments(repoID: repoID, prID: pr.id),
            isLoadingReviewers: repoStore.isLoadingReviewers(repoID: repoID, prID: pr.id),
            isLoadingFiles: repoStore.isLoadingFiles(repoID: repoID, prID: pr.id),
            isSubmittingReview: repoStore.isSubmittingReview(repoID: repoID, prID: pr.id),
            reviewSubmitError: repoStore.reviewSubmitError(repoID: repoID, prID: pr.id),
            provider: repoStore.provider(for: repoID),
            canRequestChanges: repoStore.capabilities(for: repoID).supportsRequestChanges,
            onSubmitReview: { decision, body in
                Task { await repoStore.submitReview(repoID: repoID, prID: pr.id, decision: decision, body: body) }
            },
            onAddComment: { body in
                Task { await repoStore.addComment(repoID: repoID, prID: pr.id, body: body) }
            },
            isRefreshingDetail: repoStore.isRefreshingPRDetail(repoID: repoID, prID: pr.id),
            onRefresh: {
                Task { await repoStore.refreshPRDetail(repoID: repoID, prID: pr.id) }
            },
            onBack: onBack,
            isWindowed: isWindowed,
            onOpenInWindow: onOpenInWindow,
            repoPath: repoID.path,
            onPollChecks: { @MainActor in
                guard isVisible() else { return }
                await repoStore.refreshChecks(repoID: repoID, prID: pr.id)
            }
        )
        .task(id: pr.id) {
            repoStore.beginPRDetail(repoID: repoID, prID: pr.id)
        }
    }
}
