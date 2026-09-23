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

    @State private var reviewDraft = ""
    @State private var showReviewSubmittedToast = false
    /// What the in-flight submission was, for the toast's wording.
    @State private var submittedComment = false

    private var draftIsEmpty: Bool {
        reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                    commentsSection
                }
            }
            .frame(maxHeight: .infinity)

            divider
            composer
        }
        .frame(width: PRDetailMetrics.width, height: PRDetailMetrics.height, alignment: .top)
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
            BackButton(action: onBack)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(pr.source.isDraft ? "Draft" : "Open")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(stateColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(stateColor.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(stateColor.opacity(0.35)))
                    Text(provider.formatNumber(pr.id))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tabIdle)
                }
                Text(pr.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            RefreshButton(isRefreshing: isRefreshingDetail, action: onRefresh)
                .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var stateColor: Color {
        pr.source.isDraft ? Palette.neutral : RepoActivityState.idle.color
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
        .padding(.horizontal, 14)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var description: some View {
        RenderedBodyText(html: pr.descriptionHTML, fallbackMarkdown: pr.description,
                       fontSize: 12, textColor: Palette.textBody)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Checks")
            if pr.checks.isEmpty && isLoadingChecks {
                loadingRow
            }
            VStack(spacing: 6) {
                ForEach(pr.checks) { check in
                    CheckRow(check: check)
                }
            }
        }
        .padding(.horizontal, 14)
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
        .padding(.horizontal, 14)
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
            .frame(height: 52)

            HStack(spacing: 8) {
                if isSubmittingReview {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 0)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(check.passed ? RepoActivityState.idle.color : Palette.danger)
            Text(check.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textStrong)
            Spacer(minLength: 0)
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
}

private struct ReviewerRow: View {
    let reviewer: PRReviewer

    var body: some View {
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
                RenderedBodyText(html: comment.htmlText, fallbackMarkdown: comment.text,
                              fontSize: 11.5, textColor: Palette.textComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.wash.opacity(0.04)))
            }
        }
    }
}
