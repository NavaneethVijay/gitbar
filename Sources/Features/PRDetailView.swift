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
    /// Awaited, so the screen can confirm with a toast when it's done.
    var onRefresh: () async -> Void = {}
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
    /// Shows Edit (title, description, target branch) — your own open PRs.
    var canEdit = false
    var loadBranches: () async throws -> [String] = { [] }
    var onEdit: (_ title: String, _ body: String, _ targetBranch: String) async throws -> Void = { _, _, _ in }
    /// The diff's review actions; `nil` for a closed/merged PR.
    var inlineReview: InlineReviewActions?
    /// Why Approve / Request changes are off (your own PR on GitHub).
    var verdictBlockedReason: String?
    /// Deletes your pending review and its comments.
    var onDiscardReview: () async throws -> Void = {}

    private static let checksPollInterval: Duration = .seconds(20)

    @State private var reviewDraft = ""
    @FocusState private var isComposerFocused: Bool
    /// The floating confirmation — review/comment sent, refresh done.
    @State private var toastTitle: String?
    @State private var toastToken = 0
    /// What the in-flight submission was, for the toast's wording.
    @State private var submittedComment = false
    /// Window only: files whose diff is open, by filename.
    @State private var expandedFiles: Set<String> = []
    /// "With comments": the window's file list narrowed to files with threads.
    @State private var onlyCommentedFiles = false
    /// Window only: the content column's width — Checks and Reviewers sit
    /// side by side once there's room for both.
    @State private var contentWidth: CGFloat = 0
    /// The edit form: a sheet in the window, its own screen in the popover.
    @State private var isEditing = false
    /// The "Finish your review" form: a popover in the window, in place of
    /// the composer in the menu bar popover.
    @State private var isReviewing = false

    private var draftIsEmpty: Bool {
        reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The bottom box is the conversation, as on the web; reviews (with
    /// their inline comments) go through the review form.
    private func commentTapped() {
        submittedComment = true
        onAddComment(reviewDraft)
    }

    private var commentDisabled: Bool { isSubmittingReview || draftIsEmpty }

    private var reviewForm: some View {
        ReviewSubmitView(
            provider: provider,
            isWindowed: isWindowed,
            pendingCount: pr.pendingCommentCount,
            hasPendingReview: pr.hasPendingReview,
            canRequestChanges: canRequestChanges,
            verdictBlockedReason: verdictBlockedReason,
            isSubmitting: isSubmittingReview,
            submitError: submittedComment ? nil : reviewSubmitError,
            onSubmit: { decision, body in
                submittedComment = false
                onSubmitReview(decision, body)
            },
            onDiscard: {
                try await onDiscardReview()
                closeReviewForm()
                showToast("Review discarded")
            },
            onCancel: closeReviewForm
        )
    }

    private func closeReviewForm() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { isReviewing = false }
    }

    /// "Review changes" / "Finish your review", with the pending count.
    private var reviewButtonLabel: some View {
        HStack(spacing: 6) {
            Text(provider.reviewButtonTitle(inProgress: pr.hasPendingReview))
            if pr.pendingCommentCount > 0 {
                Text("\(pr.pendingCommentCount)")
                    .font(.system(size: type.chip, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.wash.opacity(0.15)))
            }
        }
    }

    private var editForm: some View {
        EditPullRequestView(
            pr: pr,
            provider: provider,
            isWindowed: isWindowed,
            loadBranches: loadBranches,
            onSave: { title, body, base in
                try await onEdit(title, body, base)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { isEditing = false }
                showToast("\(provider.pullRequestShort) \(provider.formatNumber(pr.id)) updated")
            },
            onCancel: { withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { isEditing = false } }
        )
    }

    /// The window's content column: wide windows center it rather than
    /// stretching lines of text edge to edge.
    private static let readableWidth: CGFloat = 980
    /// Below this, Checks and Reviewers stack instead of sharing a row.
    private static let twoColumnWidth: CGFloat = 620

    private var horizontalPadding: CGFloat { isWindowed ? 24 : 14 }
    /// The window's larger, Apple-scale sizes; the popover's compact ones.
    private var type: DetailTypeScale { isWindowed ? .window : .popover }

    var body: some View {
        layout
        .modifier(PRDetailFrame(isWindowed: isWindowed))
        .environment(\.detailType, type)
        .environment(\.onLinkCopied) { showToast("Link copied") }
        .environment(\.showToast) { showToast($0) }
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
        .overlay(alignment: isWindowed ? .bottom : .top) {
            if let toastTitle {
                ReviewSubmittedToast(title: toastTitle)
                    // In the window it floats above the composer, like Settings' toasts.
                    .padding(isWindowed ? .bottom : .top, isWindowed ? 150 : 8)
                    .transition(.move(edge: isWindowed ? .bottom : .top).combined(with: .opacity))
            }
        }
        // Clear the draft only when a submission finishes without an error —
        // a failure must never lose what was typed.
        .onChange(of: isSubmittingReview) { wasSubmitting, isSubmitting in
            guard wasSubmitting, !isSubmitting, reviewSubmitError == nil else { return }
            if submittedComment {
                reviewDraft = ""
                showToast("Comment posted")
            } else {
                closeReviewForm()
                showToast("Review submitted")
            }
        }
    }

    private func showToast(_ title: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toastTitle = title }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard token == toastToken else { return }
            withAnimation(.easeOut(duration: 0.25)) { toastTitle = nil }
        }
    }

    /// Every manual refresh says when it's done.
    private func refreshTapped() {
        Task {
            await onRefresh()
            showToast("\(provider.pullRequestShort) \(provider.formatNumber(pr.id)) is up to date")
        }
    }

    @ViewBuilder
    private var layout: some View {
        if isWindowed {
            windowLayout
                .sheet(isPresented: $isEditing) { editForm }
        } else if isEditing {
            editForm
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            popoverLayout
                .transition(.move(edge: .leading).combined(with: .opacity))
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
                    windowSections
                }
                .frame(maxWidth: Self.readableWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
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
        if canEdit {
            ToolbarItem {
                Button("Edit", systemImage: "pencil") { isEditing = true }
                    .help("Edit title, description and target branch")
            }
        }
        ToolbarItemGroup {
            if let url = pr.webURL {
                Button("Copy Link", systemImage: "link") {
                    copyToPasteboard(url.absoluteString)
                    showToast("Link copied")
                }
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
                Button("Refresh", systemImage: "arrow.clockwise", action: refreshTapped)
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

    /// The window, like the mockup: the header carries author and branches,
    /// then the description, Checks beside Reviewers (stacked when narrow),
    /// and full-width files and conversation.
    @ViewBuilder
    private var windowSections: some View {
        if !pr.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            description
            divider
        }
        if contentWidth >= Self.twoColumnWidth {
            HStack(alignment: .top, spacing: 0) {
                checksSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Rectangle().fill(Palette.wash.opacity(0.07)).frame(width: 1)
                reviewersSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            checksSection
            divider
            reviewersSection
        }
        divider
        windowFilesSection
        divider
        commentsSection
    }

    /// Each file is its own row of the enclosing `LazyVStack`, so a PR with
    /// 100 files only builds the ones scrolled into view.
    @ViewBuilder
    private var windowFilesSection: some View {
        let threadsByFile = Dictionary(grouping: pr.reviewThreads, by: \.path)
        let commentedFiles = pr.files.filter { threadsByFile[$0.filename] != nil }
        let shownFiles = onlyCommentedFiles && !commentedFiles.isEmpty ? commentedFiles : pr.files
        HStack(spacing: 10) {
            SectionLabel("Files changed · \(pr.files.count)")
            ReviewThreadChips(summary: .total(pr.reviewThreads))
            Spacer(minLength: 0)
            if !commentedFiles.isEmpty {
                Toggle("With comments (\(commentedFiles.count))", isOn: $onlyCommentedFiles)
                    .toggleStyle(.checkbox)
                    .font(.system(size: type.meta, weight: .semibold))
                    .help("Only show files that have review comments")
            }
            if !pr.files.isEmpty {
                let allOpen = shownFiles.allSatisfy { expandedFiles.contains($0.id) }
                Button(allOpen ? "Collapse All" : "Expand All") {
                    let ids = Set(shownFiles.map(\.id))
                    if allOpen { expandedFiles.subtract(ids) } else { expandedFiles.formUnion(ids) }
                }
                .buttonStyle(.link)
                .font(.system(size: type.meta, weight: .semibold))
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
                        .font(.system(size: type.row))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 12)
        } else {
            ForEach(shownFiles) { file in
                DiffFileView(
                    file: file,
                    webDiffURL: pr.diffURL,
                    isExpanded: Binding(
                        get: { expandedFiles.contains(file.id) },
                        set: { open in
                            if open { expandedFiles.insert(file.id) } else { expandedFiles.remove(file.id) }
                        }),
                    threads: threadsByFile[file.filename] ?? [],
                    review: inlineReview
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
                .font(.system(size: type.small))
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
                            .font(.system(size: type.small))
                            .foregroundStyle(Palette.tabIdle)
                    }
                    if isWindowed {
                        // The popover has these as their own rows.
                        Text("@\(pr.author) opened this \(pr.openedAgo)")
                            .font(.system(size: type.row))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Text(pr.title)
                    .font(.system(size: isWindowed ? 16 : 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if isWindowed {
                    HStack(spacing: 8) {
                        BranchChip(name: pr.headBranch)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                        BranchChip(name: pr.baseBranch)
                    }
                    .padding(.top, 2)
                }
                if let url = pr.webURL {
                    PRLinkRow(url: url)
                }
            }

            Spacer(minLength: 4)

            if !isWindowed {
                if canEdit {
                    HeaderIconButton(systemImage: "pencil", help: "Edit \(provider.pullRequestShort)") {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { isEditing = true }
                    }
                    .padding(.top, 1)
                }
                if let onOpenInWindow {
                    HeaderIconButton(systemImage: "macwindow", help: "Open in the repo window", action: onOpenInWindow)
                        .padding(.top, 1)
                }
                RefreshButton(isRefreshing: isRefreshingDetail, action: refreshTapped)
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
        RenderedBodyText(markdown: pr.description, fontSize: type.body, textColor: Palette.textBody)
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
                    .font(.system(size: type.row))
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
                ChecksStatusLabel(pr: pr, fontSize: type.meta)
            }
            if pr.checks.isEmpty && isLoadingChecks {
                loadingRow
            } else if pr.checks.isEmpty {
                Text("No checks reported.")
                    .font(.system(size: type.row))
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
                ReviewThreadChips(summary: .total(pr.reviewThreads))
                Spacer(minLength: 0)
                if let diffURL = pr.diffURL {
                    ViewDiffLink(url: diffURL)
                }
            }
            if pr.files.isEmpty && isLoadingFiles {
                loadingRow
            } else if pr.files.isEmpty {
                Text("No file changes.")
                    .font(.system(size: type.row))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                let threadsByFile = Dictionary(grouping: pr.reviewThreads, by: \.path)
                VStack(spacing: 6) {
                    ForEach(pr.files) { file in
                        FileChangeRow(file: file, threads: FileThreadSummary(threadsByFile[file.filename] ?? []))
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
                    .font(.system(size: type.row))
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

    /// The conversation box, plus the review button — like the web, where
    /// a comment and a review are separate things. In the menu bar popover
    /// the review form takes this spot.
    @ViewBuilder
    private var composer: some View {
        if !isWindowed && isReviewing {
            reviewForm
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            conversationComposer
        }
    }

    private var conversationComposer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let reviewSubmitError, submittedComment {
                Text(reviewSubmitError)
                    .font(.system(size: type.meta))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack(alignment: .topLeading) {
                composerField
                if reviewDraft.isEmpty {
                    // Sits exactly where typed text starts: the editor's own
                    // padding plus NSTextView's 5pt line-fragment padding.
                    Text("Leave a comment")
                        .font(.system(size: composerFontSize))
                        .foregroundStyle(Palette.textPlaceholder)
                        .padding(.leading, composerInset + 5)
                        .padding(.top, composerInset)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reviewDraft)
                    .font(.system(size: composerFontSize))
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    // With "Show scroll bars: Always" an empty box showed a
                    // scroller track; overlay scrollers appear only on scroll.
                    .background(OverlayScrollers())
                    .padding(composerInset)
                    .focused($isComposerFocused)
                    .disabled(isSubmittingReview)
                    // SwiftUI hands a newly shown screen's first text view
                    // focus; nothing should be focused until clicked.
                    .task(id: pr.id) {
                        try? await Task.sleep(for: .milliseconds(250))
                        if reviewDraft.isEmpty { isComposerFocused = false }
                    }
            }
            .frame(height: isWindowed ? 96 : 52)

            HStack(spacing: 8) {
                if isWindowed {
                    windowReviewButton
                } else {
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { isReviewing = true }
                    } label: {
                        reviewButtonLabel
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(pr.hasPendingReview ? Palette.attention : Palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill((pr.hasPendingReview ? Palette.attention : Palette.accent).opacity(0.14)))
                            .overlay(Capsule().strokeBorder((pr.hasPendingReview ? Palette.attention : Palette.accent).opacity(0.4)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .disabled(isSubmittingReview)
                }
                if isSubmittingReview && submittedComment {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 0)
                if isWindowed {
                    Button("Comment", action: commentTapped)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(commentDisabled)
                        .help("Comment in the conversation")
                } else {
                    ReviewActionButton(title: "Comment", color: Palette.neutral, isDisabled: commentDisabled) {
                        commentTapped()
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
    }

    /// Opens the review form as a popover above the button.
    private var windowReviewButton: some View {
        Button { isReviewing = true } label: { reviewButtonLabel }
            .controlSize(.large)
            .tint(pr.hasPendingReview ? Palette.attention : nil)
            .buttonStyle(.bordered)
            .disabled(isSubmittingReview && submittedComment)
            .help(pr.hasPendingReview ? "Submit or discard your pending review"
                                      : "Approve, request changes or comment with a review")
            .popover(isPresented: $isReviewing, arrowEdge: .top) {
                reviewForm
                    .frame(width: 440)
            }
    }
}

private extension PRDetailView {
    var composerFontSize: CGFloat { isWindowed ? 13 : 11.5 }
    var composerInset: CGFloat { isWindowed ? 8 : 6 }

    /// The comment box's surface. In the window: a text-field-like well
    /// whose border turns accent while typing.
    @ViewBuilder
    var composerField: some View {
        let shape = RoundedRectangle(cornerRadius: isWindowed ? 8 : 10, style: .continuous)
        if isWindowed {
            ComposerWell(isFocused: isComposerFocused)
        } else {
            shape
                .fill(Palette.wash.opacity(0.03))
                .overlay(shape.strokeBorder(Palette.wash.opacity(0.08)))
        }
    }

}

/// The window's comment box surface (PR and issue screens): a
/// text-field-like well whose border turns accent while typing.
struct ComposerWell: View {
    let isFocused: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .overlay(shape.strokeBorder(isFocused ? Color.accentColor.opacity(0.8)
                                                  : Color(nsColor: .separatorColor),
                                        lineWidth: isFocused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Gives the `TextEditor` it sits behind overlay scrollers. SwiftUI offers
/// no hook into its `NSScrollView`, so this finds the text scroll view that
/// shares its frame.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { (nsView as? Probe)?.apply() }
    }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let root = window?.contentView else { return }
            let frame = convert(bounds, to: nil)
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.documentView is NSTextView,
                   scroll.convert(scroll.bounds, to: nil).intersects(frame) {
                    scroll.scrollerStyle = .overlay
                    scroll.autohidesScrollers = true
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(root)
        }
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

struct SectionLabel: View {
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
    @Environment(\.detailType) private var type
    var body: some View {
        Text(name)
            .font(.system(size: type.meta, design: .monospaced))
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
    @Environment(\.detailType) private var type

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 14, height: 14)
            Text(check.name)
                .font(.system(size: type.row))
                .foregroundStyle(Palette.textStrong)
                .help(check.summary ?? check.name)
            Spacer(minLength: 0)
            if check.status == .running {
                Text("Running…")
                    .font(.system(size: type.meta))
                    .foregroundStyle(Palette.textTertiary)
            } else if check.status == .pending {
                Text("Pending")
                    .font(.system(size: type.meta))
                    .foregroundStyle(Palette.textTertiary)
            } else if check.status == .skipped {
                Text("Skipped")
                    .font(.system(size: type.meta))
                    .foregroundStyle(Palette.textTertiary)
            }
            if let url = check.detailsURL {
                Text("Details")
                    .font(.system(size: type.meta, weight: .semibold))
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
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(Palette.attention)
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

/// Opens the PR's diff view (`PullRequest.diffURL`) on the web.
private struct ViewDiffLink: View {
    let url: URL

    @State private var isHovered = false
    @Environment(\.detailType) private var type

    var body: some View {
        Text("View diff ↗")
            .font(.system(size: type.meta, weight: .semibold))
            .foregroundStyle(isHovered ? Palette.accentHover : Palette.accent)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
            .hoverHighlight($isHovered)
    }
}

/// One file's line in the list — also the header of `DiffFileView`.
struct FileChangeRow: View {
    let file: PRFileChange
    /// The file's inline threads: open / resolved / pending.
    var threads = FileThreadSummary([])
    @Environment(\.detailType) private var type

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
                .font(.system(size: type.mono, design: .monospaced))
                .foregroundStyle(Palette.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            FileCommentIndicator(summary: threads)
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
            .font(.system(size: type.meta, weight: .semibold, design: .monospaced))
        }
    }
}

/// Inline-review chips: open threads (accent), resolved (quiet), your
/// pending comments (attention). Nothing when there are none.
/// A file row's comment marker: one small bubble in a fixed column by the
/// line counts, so commented files stand out down a long list. Blue = open
/// threads, orange = your pending comments, green check = all resolved.
struct FileCommentIndicator: View {
    let summary: FileThreadSummary
    @Environment(\.detailType) private var type

    private var style: (icon: String, color: Color, count: Int) {
        if summary.pending > 0 { return ("text.bubble.fill", Palette.attention, summary.open + summary.pending) }
        if summary.open > 0 { return ("text.bubble.fill", Palette.accent, summary.open) }
        return ("checkmark.bubble.fill", Palette.success, summary.resolved)
    }

    private var help: String {
        var parts: [String] = []
        if summary.open > 0 { parts.append("\(summary.open) open thread\(summary.open == 1 ? "" : "s")") }
        if summary.resolved > 0 { parts.append("\(summary.resolved) resolved") }
        if summary.pending > 0 { parts.append("\(summary.pending) pending comment\(summary.pending == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !summary.isEmpty {
            let style = style
            HStack(spacing: 2) {
                Image(systemName: style.icon)
                if style.count > 1 {
                    Text("\(style.count)").font(.system(size: type.chip, weight: .bold))
                }
            }
            .font(.system(size: type.meta + 2))
            .foregroundStyle(style.color)
            .fixedSize()
            .help(help)
        }
    }
}

struct ReviewThreadChips: View {
    let summary: FileThreadSummary
    @Environment(\.detailType) private var type

    var body: some View {
        if !summary.isEmpty {
            HStack(spacing: 4) {
                if summary.open > 0 {
                    chip("\(summary.open)", icon: "text.bubble.fill", color: Palette.accent,
                         help: "\(summary.open) unresolved thread\(summary.open == 1 ? "" : "s")")
                }
                if summary.resolved > 0 {
                    chip("\(summary.resolved)", icon: "checkmark.circle.fill", color: Palette.success,
                         help: "\(summary.resolved) resolved thread\(summary.resolved == 1 ? "" : "s")")
                }
                if summary.pending > 0 {
                    chip("\(summary.pending) pending", icon: nil, color: Palette.attention,
                         help: "\(summary.pending) comment\(summary.pending == 1 ? "" : "s") in your pending review")
                }
            }
            .fixedSize()
        }
    }

    private func chip(_ text: String, icon: String?, color: Color, help: String) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: type.chip - 1))
            }
            Text(text).font(.system(size: type.chip, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .help(help)
    }
}

private struct ReviewerRow: View {
    let reviewer: PRReviewer
    @Environment(\.detailType) private var type

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
                    .font(.system(size: type.row))
                    .foregroundStyle(Palette.textStrong)
                Spacer(minLength: 0)
                Text(reviewer.state.label)
                    .font(.system(size: type.meta, weight: .semibold))
                    .foregroundStyle(reviewer.state.color)
            }
            if hasBody {
                RenderedBodyText(markdown: reviewer.text ?? "", fontSize: type.comment, textColor: Palette.textComment)
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

struct CommentBubble: View {
    let comment: PRComment
    @Environment(\.detailType) private var type

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(LinearGradient(colors: [Palette.accent, Palette.accentPurple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay(Text(comment.initials).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(comment.author).font(.system(size: type.comment, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                    Text("· \(comment.timeAgo)").font(.system(size: type.small)).foregroundStyle(Palette.textTertiary)
                }
                RenderedBodyText(markdown: comment.text, fontSize: type.comment, textColor: Palette.textComment)
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
    @Environment(\.detailType) private var type

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Text(text)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: type.small, weight: .semibold))
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
    @Environment(\.onLinkCopied) private var onLinkCopied
    @Environment(\.detailType) private var type

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
                .font(.system(size: type.meta))
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
                onLinkCopied?()
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
    @Environment(\.onLinkCopied) private var onLinkCopied
    var body: some View {
        Button("Open in Browser") { NSWorkspace.shared.open(url) }
        Button("Copy Link") {
            copyToPasteboard(url.absoluteString)
            onLinkCopied?()
        }
    }
}

extension EnvironmentValues {
    /// Set by a detail screen so every copy spot in it (toolbar, link row,
    /// context menus) confirms with the screen's toast.
    @Entry var onLinkCopied: (() -> Void)? = nil
}

func copyToPasteboard(_ string: String) {
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

    private var isOwnPR: Bool { pr.author == repoStore.login(for: repoID) }

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
            onRefresh: { await repoStore.refreshPRDetail(repoID: repoID, prID: pr.id) },
            onBack: onBack,
            isWindowed: isWindowed,
            onOpenInWindow: onOpenInWindow,
            repoPath: repoID.path,
            onPollChecks: { @MainActor in
                guard isVisible() else { return }
                await repoStore.refreshChecks(repoID: repoID, prID: pr.id)
            },
            canEdit: pr.source.state == .open && isOwnPR,
            loadBranches: { try await repoStore.loadBranches(repoID: repoID) },
            onEdit: { title, body, base in
                try await repoStore.editPullRequest(repoID: repoID, prID: pr.id, title: title, body: body, targetBranch: base)
            },
            inlineReview: pr.source.state != .open ? nil : InlineReviewActions(
                provider: repoStore.provider(for: repoID),
                hasPendingReview: pr.hasPendingReview,
                addComment: { anchor, body, pending in
                    try await repoStore.addReviewComment(repoID: repoID, prID: pr.id, anchor: anchor, body: body, pending: pending)
                },
                updatePending: { id, body in
                    try await repoStore.updatePendingComment(repoID: repoID, prID: pr.id, noteID: id, body: body)
                },
                deletePending: { id in try await repoStore.deletePendingComment(repoID: repoID, prID: pr.id, noteID: id) },
                reply: { threadID, body in
                    try await repoStore.replyToReviewThread(repoID: repoID, prID: pr.id, threadID: threadID, body: body)
                },
                setResolved: { threadID, resolved in
                    try await repoStore.setReviewThreadResolved(repoID: repoID, prID: pr.id, threadID: threadID, resolved: resolved)
                }
            ),
            verdictBlockedReason: isOwnPR && !repoStore.capabilities(for: repoID).allowsVerdictOnOwnPullRequest
                ? "You can't approve or request changes on your own \(repoStore.provider(for: repoID).pullRequestNoun)." : nil,
            onDiscardReview: { try await repoStore.discardPendingReview(repoID: repoID, prID: pr.id) }
        )
        .task(id: pr.id) {
            repoStore.beginPRDetail(repoID: repoID, prID: pr.id)
        }
    }
}
