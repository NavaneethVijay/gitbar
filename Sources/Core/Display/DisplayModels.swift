import Foundation
import SwiftUI

// What the popover's views render — provider-neutral. Built from `Domain`
// types by `DisplayMapper`; nothing here knows which provider a value came
// from beyond `RepoSnapshot.provider` (for wording like "PR"/"MR").

/// A repo row's status, computed by `DisplayMapper.snapshot`.
enum RepoActivityState: Equatable {
    case idle
    case busy
    case needsAttention
}

extension RepoActivityState {
    var color: Color {
        switch self {
        case .idle: return Palette.success
        case .busy: return Palette.accent
        case .needsAttention: return Palette.attention
        }
    }
}

struct PRCheck: Identifiable, Equatable {
    /// Content-derived, not random: a re-fetch of the same checks must
    /// compare equal, or every refresh would redraw the PR screen.
    let id: String
    let name: String
    let passed: Bool
    /// The CI run page; no "Details" link when `nil`.
    let detailsURL: URL?
}

struct PRReviewer: Identifiable, Equatable {
    let id: String  // login — unique per reviewer on a given PR
    let login: String
    let initials: String
    let state: ReviewState
}

extension ReviewState {
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .commented: return "Commented"
        }
    }

    var color: Color {
        switch self {
        case .pending: return Palette.neutral
        case .approved: return RepoActivityState.idle.color
        case .changesRequested: return Palette.danger
        case .commented: return Palette.neutral
        }
    }
}

struct PRComment: Identifiable, Equatable {
    /// Content-derived for the same reason as `PRCheck.id`.
    let id: String
    let author: String
    let initials: String
    let timeAgo: String
    let text: String
    /// Server-rendered HTML for `text`, when the provider offers it.
    let htmlText: String?
}

/// One open PR: row fields plus detail sections (`checks`, `comments`,
/// `reviewers`), which start empty and load lazily.
struct RepoPullRequest: Identifiable, Equatable {
    /// The per-repo number (`#12` / `!12`).
    let id: Int
    let title: String
    let author: String
    let initials: String
    /// Combined CI status — empty until `checkSummaries` arrives.
    var checksLabel: String
    var checksColor: Color
    let chipLabel: String
    let chipColor: Color

    let openedAgo: String
    let headBranch: String
    let baseBranch: String
    let description: String
    let descriptionHTML: String?
    var checks: [PRCheck]
    var comments: [PRComment]
    var reviewers: [PRReviewer]
    /// The domain value behind this row, handed back to the provider for
    /// follow-up calls (checks need its head commit, reviewers its requests).
    let source: PullRequest
}

struct RepoIssue: Identifiable, Equatable {
    let id: Int
    let title: String
    let author: String
    let statusColor: Color
    let metaLabel: String
}

struct RepoSnapshot: Identifiable, Equatable {
    let id: RepoRef
    let provider: ProviderKind
    let name: String
    let state: RepoActivityState
    /// e.g. "All clear" / "CI running" / "Review requested".
    let statusLabel: String
    /// e.g. "2 open PRs" / "PR #142 · 4m ago".
    let metaLabel: String
    /// The cheap tier's first few items, shown until the detail page loads.
    let pullRequests: [RepoPullRequest]
    let issues: [RepoIssue]

    var path: String { id.path }
}
