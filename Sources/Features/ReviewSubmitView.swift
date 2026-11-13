// "Review changes" / "Finish your review": a summary, the verdict as a radio
// choice (Comment / Approve / Request changes), Submit — and Discard for a
// review in progress. GitHub's own review dialog, and GitLab's "Finish
// review". A popover in the window; it takes the composer's place in the
// menu bar popover.
import SwiftUI

struct ReviewSubmitView: View {
    let provider: ProviderKind
    var isWindowed = true
    /// Your inline comments waiting in the pending review.
    let pendingCount: Int
    let hasPendingReview: Bool
    let canRequestChanges: Bool
    /// Approve / Request changes are refused on your own PR (GitHub).
    let verdictBlockedReason: String?
    let isSubmitting: Bool
    let submitError: String?
    let onSubmit: (_ decision: ReviewDecision, _ body: String) -> Void
    let onDiscard: () async throws -> Void
    let onCancel: () -> Void

    @State private var summary = ""
    @State private var decision: ReviewDecision = .comment
    @State private var isDiscarding = false
    @State private var discardError: String?
    @FocusState private var isFocused: Bool

    private var type: DetailTypeScale { isWindowed ? .window : .popover }
    private var summaryIsEmpty: Bool { summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A comment-only review needs something to say; so does Request
    /// changes on GitHub when there are no inline comments.
    private var canSubmit: Bool {
        guard !isSubmitting, !isDiscarding else { return false }
        switch decision {
        case .approve: return true
        case .comment, .requestChanges: return !summaryIsEmpty || pendingCount > 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isWindowed ? 12 : 8) {
            HStack {
                Text(provider.reviewButtonTitle(inProgress: true))
                    .font(.system(size: isWindowed ? 14 : 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if pendingCount > 0 {
                    Text("\(pendingCount) pending comment\(pendingCount == 1 ? "" : "s")")
                        .font(.system(size: type.meta, weight: .semibold))
                        .foregroundStyle(Palette.attention)
                }
            }

            ZStack(alignment: .topLeading) {
                ComposerWell(isFocused: isFocused)
                if summary.isEmpty {
                    Text("Leave a comment")
                        .font(.system(size: type.body))
                        .foregroundStyle(Palette.textPlaceholder)
                        .padding(.leading, 8 + 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $summary)
                    .font(.system(size: type.body))
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(OverlayScrollers())
                    .padding(8)
                    .focused($isFocused)
                    .disabled(isSubmitting)
            }
            .frame(height: isWindowed ? 100 : 60)

            VStack(alignment: .leading, spacing: isWindowed ? 8 : 5) {
                option(.comment, title: "Comment",
                       detail: "Submit general feedback without explicit approval.")
                option(.approve, title: "Approve",
                       detail: verdictBlockedReason ?? "Give your approval to merge these changes.",
                       isDisabled: verdictBlockedReason != nil)
                if canRequestChanges {
                    option(.requestChanges, title: "Request changes",
                           detail: verdictBlockedReason ?? "Submit feedback that must be addressed before merging.",
                           isDisabled: verdictBlockedReason != nil)
                }
            }

            if let message = submitError ?? discardError {
                Text(message)
                    .font(.system(size: type.meta))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if hasPendingReview {
                    Button("Discard review", role: .destructive, action: discard)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Palette.danger)
                        .disabled(isSubmitting || isDiscarding)
                        .help("Delete the pending review and its comments")
                }
                if isSubmitting || isDiscarding {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Submit review") { onSubmit(decision, summary) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSubmit)
            }
            .controlSize(isWindowed ? .regular : .small)
        }
        .padding(isWindowed ? 16 : 0)
        .onAppear {
            if verdictBlockedReason != nil { decision = .comment }
        }
    }

    private func option(_ value: ReviewDecision, title: String, detail: String, isDisabled: Bool = false) -> some View {
        Button {
            decision = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: decision == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(decision == value ? Color.accentColor : Palette.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: type.row, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if isWindowed {
                        Text(detail)
                            .font(.system(size: type.meta))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isSubmitting)
        .opacity(isDisabled ? 0.5 : 1)
        .help(detail)
    }

    private func discard() {
        isDiscarding = true
        discardError = nil
        Task {
            do {
                try await onDiscard()
            } catch {
                discardError = (error as? LocalizedError)?.errorDescription ?? "Couldn't discard the review."
            }
            isDiscarding = false
        }
    }
}
