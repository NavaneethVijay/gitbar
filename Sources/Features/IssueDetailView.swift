// One issue in the repo window's detail column: header, description,
// labels/assignees, the conversation, and a composer to reply.
import AppKit
import SwiftUI

/// Store-wired, like `PRDetailScreen`.
struct IssueDetailScreen: View {
    let repoStore: LiveRepoStore
    let repoID: RepoRef
    let issue: RepoIssue

    private var key: PRRef { PRRef(repo: repoID, number: issue.id) }

    var body: some View {
        IssueDetailView(
            issue: issue,
            repoPath: repoID.path,
            comments: repoStore.issueComments[key],
            isLoadingComments: repoStore.loadingIssueCommentsFor.contains(key),
            isPosting: repoStore.isPostingIssueComment[key] == true,
            postError: repoStore.issueCommentError[key],
            onComment: { body in
                Task { await repoStore.addIssueComment(repoID: repoID, number: issue.id, body: body) }
            },
            onRefresh: { await repoStore.refreshIssueDetail(repoID: repoID, number: issue.id) }
        )
        .task(id: issue.id) {
            repoStore.beginIssueDetail(repoID: repoID, number: issue.id)
        }
    }
}

struct IssueDetailView: View {
    let issue: RepoIssue
    let repoPath: String
    /// `nil` until the first load answers.
    let comments: [PRComment]?
    let isLoadingComments: Bool
    let isPosting: Bool
    let postError: String?
    let onComment: (String) -> Void
    /// Awaited, so the screen can confirm with a toast when it's done.
    let onRefresh: () async -> Void

    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool
    @State private var toastTitle: String?
    @State private var toastToken = 0

    /// Same readable column as the PR screen in a window.
    private static let readableWidth: CGFloat = 820

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if !issue.labels.isEmpty || !issue.assignees.isEmpty {
                        metaRow
                        Divider()
                    }
                    description
                    Divider()
                    commentsSection
                }
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            Divider()
            composer
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        .navigationTitle(issue.title)
        .navigationSubtitle("\(repoPath) #\(issue.id)")
        .toolbar { toolbar }
        .overlay(alignment: .bottom) {
            if let toastTitle {
                Text(toastTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingCapsule()
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Clear the draft only after a post that didn't fail.
        .onChange(of: isPosting) { wasPosting, posting in
            guard wasPosting, !posting, postError == nil else { return }
            draft = ""
            showToast("Comment posted")
        }
    }

    private func showToast(_ title: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toastTitle = title }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard token == toastToken else { return }
            withAnimation(.easeOut(duration: 0.25)) { toastTitle = nil }
        }
    }

    private func refreshTapped() {
        Task {
            await onRefresh()
            showToast("Issue #\(issue.id) is up to date")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let url = issue.webURL {
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
            if isLoadingComments {
                ProgressView().controlSize(.small)
                    .help("Refreshing…")
            } else {
                Button("Refresh", systemImage: "arrow.clockwise", action: refreshTapped)
                    .help("Refresh")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusPill(chip: PRStatusChip(label: "Open", color: RepoActivityState.idle.color), fontSize: 10.5)
                Text("@\(issue.author) opened this \(issue.openedAgo)")
                    .font(.system(size: DetailTypeScale.window.row))
                    .foregroundStyle(.secondary)
            }
            Text(issue.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var metaRow: some View {
        HStack(alignment: .top, spacing: 28) {
            if !issue.assignees.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Assignees")
                    HStack(spacing: 10) {
                        ForEach(issue.assignees) { assignee in
                            HStack(spacing: 5) {
                                AssigneeStack(assignees: [assignee])
                                Text(assignee.isMe ? "You" : "@\(assignee.login)")
                                    .font(.system(size: DetailTypeScale.window.row))
                                    .foregroundStyle(Palette.textPrimary)
                            }
                        }
                    }
                }
            }
            if !issue.labels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Labels")
                    LabelRow(labels: issue.labels)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Description")
            if issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description provided.")
                    .font(.system(size: DetailTypeScale.window.row))
                    .foregroundStyle(Palette.textTertiary)
            } else {
                RenderedBodyText(markdown: issue.body, fontSize: DetailTypeScale.window.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Comments · \(comments?.count ?? issue.commentCount)")
            if let comments {
                if comments.isEmpty {
                    Text("No comments yet.")
                        .font(.system(size: DetailTypeScale.window.row))
                        .foregroundStyle(Palette.textTertiary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(comments) { CommentBubble(comment: $0) }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let postError {
                Text(postError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Same box as the PR screen's composer (see `PRDetailView`).
            ZStack(alignment: .topLeading) {
                ComposerWell(isFocused: isComposerFocused)
                if draft.isEmpty {
                    // At the editor's padding + NSTextView's 5pt line-fragment
                    // padding, where typed text starts.
                    Text("Leave a comment")
                        .font(.system(size: DetailTypeScale.window.body))
                        .foregroundStyle(Palette.textPlaceholder)
                        .padding(.leading, 8 + 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.system(size: DetailTypeScale.window.body))
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(OverlayScrollers())
                    .padding(8)
                    .focused($isComposerFocused)
                    .disabled(isPosting)
                    // Nothing focused until clicked.
                    .task(id: issue.id) {
                        try? await Task.sleep(for: .milliseconds(250))
                        if draft.isEmpty { isComposerFocused = false }
                    }
            }
            .frame(height: 96)

            HStack(spacing: 10) {
                if isPosting { ProgressView().controlSize(.small) }
                Button("Comment") { onComment(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
