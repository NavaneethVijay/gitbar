import Foundation
import SwiftUI

/// Domain → display: every label, color and "time ago" the popover shows,
/// defined once for all providers. A new provider module never formats
/// anything — it returns `Domain` values and gets this app's look for free.
enum DisplayMapper {
    /// A PR row. `login` is the account's own user, for "Review requested".
    /// The CI label starts blank — `checksLabel(for:)` fills it in once
    /// `checkSummaries` arrives.
    static func pullRequest(_ pr: PullRequest, login: String) -> RepoPullRequest {
        let chipLabel: String
        let chipColor: Color
        if pr.isDraft {
            chipLabel = "Draft"; chipColor = Palette.neutral
        } else if pr.requestedReviewers.contains(login) {
            chipLabel = "Review requested"; chipColor = RepoActivityState.needsAttention.color
        } else {
            chipLabel = "Open"; chipColor = RepoActivityState.idle.color
        }
        return RepoPullRequest(
            id: pr.number, title: pr.title, author: pr.author, initials: initials(for: pr.author),
            checksLabel: "", checksColor: Palette.neutral,
            chipLabel: chipLabel, chipColor: chipColor,
            openedAgo: relativeTime(from: pr.createdAt),
            headBranch: pr.sourceBranch, baseBranch: pr.targetBranch,
            description: pr.body, descriptionHTML: pr.bodyHTML,
            checks: [], comments: [], reviewers: [],
            source: pr
        )
    }

    static func issue(_ issue: Issue) -> RepoIssue {
        RepoIssue(id: issue.number, title: issue.title, author: issue.author,
                  statusColor: RepoActivityState.idle.color,
                  metaLabel: "Opened \(relativeTime(from: issue.createdAt))")
    }

    static func checksLabel(for summary: CheckSummary) -> (label: String, color: Color) {
        switch summary {
        case .passed: return ("Checks passed", RepoActivityState.idle.color)
        case .failing: return ("Checks failing", Palette.danger)
        case .running: return ("Checks running", RepoActivityState.busy.color)
        case .none: return ("No checks", Palette.neutral)
        case .other(let state): return ("Checks \(state)", Palette.neutral)
        }
    }

    static func check(_ run: CheckRun) -> PRCheck {
        PRCheck(name: run.name, passed: run.passed, detailsURL: run.detailsURL)
    }

    static func comment(_ comment: Comment) -> PRComment {
        PRComment(author: comment.author, initials: initials(for: comment.author),
                  timeAgo: relativeTime(from: comment.createdAt), text: comment.body, htmlText: comment.bodyHTML)
    }

    static func reviewer(_ reviewer: Reviewer) -> PRReviewer {
        PRReviewer(id: reviewer.login, login: reviewer.login, initials: initials(for: reviewer.login), state: reviewer.state)
    }

    /// The repo-list row. `recentPulls`/`recentIssues` are the cheap tier's
    /// small page; `needsAttention`/`busy` were derived from the account's
    /// own PRs by the store. When the page is full, counts say "N+" rather
    /// than claiming an exact total that was never asked for.
    static func snapshot(
        repo: RepoRef, provider: ProviderKind, login: String,
        recentPulls: [PullRequest], recentIssues: [Issue], pageLimit: Int,
        needsAttention: Bool, busy: Bool
    ) -> RepoSnapshot {
        let state: RepoActivityState = needsAttention ? .needsAttention : (busy ? .busy : .idle)
        let relevant = recentPulls.filter { $0.author == login || $0.requestedReviewers.contains(login) }
        let mostRecent = relevant.max { $0.createdAt < $1.createdAt } ?? recentPulls.first
        let count = recentPulls.count
        let countText = count >= pageLimit ? "\(count)+" : "\(count)"
        let short = provider.pullRequestShort
        let latestText = mostRecent.map {
            "\(short) \(provider.formatNumber($0.number)) · \(relativeTime(from: $0.createdAt))"
        }

        let statusLabel: String
        let metaLabel: String
        switch state {
        case .needsAttention:
            statusLabel = "Review requested"
            metaLabel = latestText ?? "\(countText) open \(short)s"
        case .busy:
            statusLabel = "CI running"
            metaLabel = latestText ?? "\(countText) open \(short)s"
        case .idle:
            statusLabel = "All clear"
            metaLabel = "\(countText) open \(short)\(count == 1 ? "" : "s")"
        }

        return RepoSnapshot(
            id: repo, provider: provider, name: repo.name, state: state,
            statusLabel: statusLabel, metaLabel: metaLabel,
            pullRequests: recentPulls.map { pullRequest($0, login: login) },
            issues: recentIssues.map(issue)
        )
    }

    static func initials(for name: String) -> String {
        String(name.prefix(2)).uppercased()
    }

    static func relativeTime(from date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d ago" }
        if hours > 0 { return "\(hours)h ago" }
        if minutes > 0 { return "\(minutes)m ago" }
        return "just now"
    }
}
