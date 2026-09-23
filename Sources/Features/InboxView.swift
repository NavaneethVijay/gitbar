// The notifications inbox: unread threads grouped by repo. Opening one marks
// it read (see `MenuViewModel.open`).
import SwiftUI

struct InboxView: View {
    let entries: [NotificationStore.Entry]
    let isLoading: Bool
    /// True when no account's token can read notifications at all.
    let noAccountSupportsNotifications: Bool
    let errorMessage: String?
    let onOpen: (NotificationStore.Entry) -> Void
    let onMarkAllRead: () -> Void
    let onBack: () -> Void

    /// Repo groups in newest-first order of their latest thread.
    private var groups: [(repo: String, entries: [NotificationStore.Entry])] {
        var order: [String] = []
        var byRepo: [String: [NotificationStore.Entry]] = [:]
        for entry in entries {
            let key = entry.item.repoPath
            if byRepo[key] == nil { order.append(key) }
            byRepo[key, default: []].append(entry)
        }
        return order.map { ($0, byRepo[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups, id: \.repo) { group in
                            Text(group.repo)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                            ForEach(group.entries) { entry in
                                InboxRow(entry: entry) { onOpen(entry) }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: RepoDetailMetrics.width, height: RepoDetailMetrics.height, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text("Inbox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(entries.isEmpty ? "No unread notifications" : "\(entries.count) unread")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 4)
            if isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            if !entries.isEmpty {
                ReviewActionButton(title: "Mark all read", color: Palette.accent, action: onMarkAllRead)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: RepoDetailMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.wash.opacity(0.07)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if noAccountSupportsNotifications {
                Image(systemName: "bell.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.textTertiary)
                Text("Notifications aren't available")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Your token can't read notifications. GitHub needs a classic token with the notifications (or repo) scope — fine-grained tokens can't read them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textMeta)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { SettingsWindowController.shared.show() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 4)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(RepoActivityState.idle.color)
                Text("You're all caught up")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct InboxRow: View {
    let entry: NotificationStore.Entry
    let action: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch entry.item.kind {
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "circle.dotted"
        case .release: return "tag"
        case .discussion: return "bubble.left.and.bubble.right"
        case .commit: return "smallcircle.filled.circle"
        case .checkSuite: return "checkmark.seal"
        case .other: return "bell"
        }
    }

    private var reasonColor: Color {
        switch entry.item.reason {
        case .reviewRequested, .assign: return RepoActivityState.needsAttention.color
        case .mention, .teamMention: return Palette.accent
        case .securityAlert: return Palette.danger
        default: return Palette.neutral
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(entry.item.reason.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(reasonColor)
                    if let number = entry.item.number {
                        Text("#\(number)")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Text(DisplayMapper.relativeTime(from: entry.item.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Circle()
                .fill(Palette.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.wash.opacity(isHovered ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .hoverHighlight($isHovered)
    }
}
