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
        case .busy: return Palette.running
        case .needsAttention: return Palette.attention
        }
    }
}

struct PRCheck: Identifiable, Equatable {
    /// Content-derived, not random: a re-fetch of the same checks must
    /// compare equal, or every refresh would redraw the PR screen.
    let id: String
    let name: String
    let status: CheckRunStatus
    /// The CI run page; no "Details" link when `nil`.
    let detailsURL: URL?
    /// The provider's explanation (shown as the row's tooltip).
    var summary: String? = nil
}

struct PRReviewer: Identifiable, Equatable {
    let id: String  // login — unique per reviewer on a given PR
    let login: String
    let initials: String
    let state: ReviewState
    let text: String?
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

struct PRFileChange: Identifiable, Equatable {
    /// The filename, content-derived like `PRCheck.id`.
    var id: String { filename }
    let filename: String
    let status: FileChangeStatus
    let additions: Int
    let deletions: Int
    /// Raw unified diff — parsed only when the file is expanded (`UnifiedDiff`).
    var patch: String? = nil
    /// The old path of a renamed file — inline comments need it on GitLab.
    var previousFilename: String? = nil
}

/// One comment in an inline thread.
struct PRReviewNote: Identifiable, Equatable {
    let id: String
    let author: String
    let initials: String
    let timeAgo: String
    let text: String
    /// In your unsubmitted review — editable, deletable, "Pending".
    let isPending: Bool
}

/// An inline code-review thread, drawn under its diff line.
struct PRReviewThread: Identifiable, Equatable {
    let id: String
    let path: String
    /// `nil` = outdated: the line isn't in the current diff any more.
    let anchor: DiffAnchor?
    let notes: [PRReviewNote]
    let isResolved: Bool
    let canResolve: Bool

    /// Started in your pending review — no replies or resolving yet.
    var isPending: Bool { !notes.isEmpty && notes.allSatisfy(\.isPending) }
    var pendingCount: Int { notes.filter(\.isPending).count }
}

/// One file's inline review at a glance — the file list's chips.
struct FileThreadSummary: Equatable {
    /// Posted threads still unresolved.
    var open = 0
    var resolved = 0
    /// Your comments waiting in the pending review (new threads and replies).
    var pending = 0

    var isEmpty: Bool { open == 0 && resolved == 0 && pending == 0 }

    init(_ threads: [PRReviewThread]) {
        for thread in threads {
            pending += thread.pendingCount
            guard !thread.isPending else { continue }
            if thread.isResolved { resolved += 1 } else { open += 1 }
        }
    }

    static func total(_ threads: [PRReviewThread]) -> FileThreadSummary { FileThreadSummary(threads) }
}

struct PRComment: Identifiable, Equatable {
    /// Content-derived for the same reason as `PRCheck.id`.
    let id: String
    let author: String
    let initials: String
    let timeAgo: String
    let text: String
}

/// A PR/issue label chip, in the provider's own color.
struct PRLabel: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let color: Color
}

/// The repo screen's summary strip under the header.
struct RepoSummary: Equatable {
    let description: String?
    let defaultBranch: String
    /// `nil` when the branch's CI couldn't be read — the chip goes neutral.
    let branchChecks: CheckSummary?
    /// e.g. "v2.4.1 · 3d".
    let releaseText: String?
    /// e.g. "1.2k".
    let starsText: String?
    let webURL: URL?
}

/// The colored status pill on a PR row and the PR screen's header.
struct PRStatusChip: Equatable {
    let label: String
    let color: Color
}

/// One PR: row fields plus detail sections (`checks`, `comments`,
/// `reviewers`, `files`), which start empty and load lazily.
struct RepoPullRequest: Identifiable, Equatable {
    /// The per-repo number (`#12` / `!12`).
    let id: Int
    let title: String
    let author: String
    let initials: String
    /// Combined CI + review verdict — `nil` until `statusSummaries` arrives.
    var statusSummary: PullRequestStatusSummary?
    /// The account's own user is among the requested reviewers.
    let isReviewRequestedFromMe: Bool

    let openedAgo: String
    let labels: [PRLabel]
    let headBranch: String
    let baseBranch: String
    let description: String
    var checks: [PRCheck]
    var comments: [PRComment]
    var reviewers: [PRReviewer]
    var files: [PRFileChange] = []
    /// Inline code-review threads, loaded with the files.
    var reviewThreads: [PRReviewThread] = []
    /// You have an unsubmitted review on the provider ("Finish your review").
    var hasPendingReview = false
    var pendingCommentCount: Int { reviewThreads.reduce(0) { $0 + $1.pendingCount } }
    /// The full diff on the web — `PullRequest.diffURL` — for "View diff".
    let diffURL: URL?
    /// The domain value behind this row, handed back to the provider for
    /// follow-up calls (checks need its head commit, reviewers its requests).
    let source: PullRequest

    /// The PR on the web.
    var webURL: URL? { source.webURL }

    /// Combined CI label — empty until `statusSummaries` arrives.
    var checksLabel: String { statusSummary.map { DisplayMapper.checksLabel(for: $0.checks).label } ?? "" }
    var checksColor: Color { statusSummary.map { DisplayMapper.checksLabel(for: $0.checks).color } ?? Palette.neutral }
    /// CI still going — drawn with a spinner rather than static text.
    var areChecksRunning: Bool {
        statusSummary?.checks == .running || checks.contains { $0.status == .running }
    }

    var status: PRStatusChip { DisplayMapper.statusChip(for: self) }

    /// A re-fetched copy of this PR keeps what was already loaded for it, so
    /// nothing flashes empty while the sections re-fetch.
    mutating func keepLoadedDetail(from previous: RepoPullRequest) {
        statusSummary = previous.statusSummary
        checks = previous.checks
        comments = previous.comments
        reviewers = previous.reviewers
        files = previous.files
        reviewThreads = previous.reviewThreads
        hasPendingReview = previous.hasPendingReview
    }
}

struct RepoIssue: Identifiable, Equatable {
    struct Assignee: Identifiable, Equatable {
        var id: String { login }
        let login: String
        let initials: String
        let isMe: Bool
    }

    let id: Int
    let title: String
    let author: String
    let statusColor: Color
    /// e.g. "2h ago".
    let openedAgo: String
    let labels: [PRLabel]
    let assignees: [Assignee]
    let commentCount: Int
    let webURL: URL?
    let body: String
    /// For ordering issues from several repos in one list.
    var createdAt: Date = .distantPast
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
