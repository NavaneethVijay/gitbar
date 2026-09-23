// The popover's first screen: one row per favorited repo. Tapping a row
// drills into `RepoDetailView`.
import SwiftUI

enum RepoPanelMetrics {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 58
    static let rowSpacing: CGFloat = 4
    static let verticalPadding: CGFloat = 8
}

struct RepoListPanel: View {
    let repos: [RepoSnapshot]
    /// Unread notification threads per repo — the badge on its icon.
    var unreadCounts: [RepoRef: Int] = [:]
    var onSelect: (RepoSnapshot) -> Void = { _ in }

    var body: some View {
        VStack(spacing: RepoPanelMetrics.rowSpacing) {
            ForEach(repos) { repo in
                RepoRow(snapshot: repo, unread: unreadCounts[repo.id] ?? 0)
                    .onTapGesture { onSelect(repo) }
            }
        }
        .padding(.vertical, RepoPanelMetrics.verticalPadding)
        .padding(.horizontal, 8)
        .frame(width: RepoPanelMetrics.width)
    }
}

private struct RepoRow: View {
    let snapshot: RepoSnapshot
    let unread: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(snapshot.state.color.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(snapshot.state.color.opacity(0.4)))
                    .frame(width: 32, height: 32)
                Image(systemName: "book.closed")
                    .font(.system(size: 13))
                    .foregroundStyle(snapshot.state.color)
                    .frame(width: 32, height: 32)
                if unread > 0 {
                    Text(unread > 9 ? "9+" : "\(unread)")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Palette.accent))
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("\(unread) unread notifications")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(snapshot.path)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    statusIcon
                    Text(snapshot.statusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(snapshot.state.color)
                Text(snapshot.metaLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Status keeps its full width; the name column truncates instead.
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        // The row owns its height so the hover highlight and click target
        // fill the whole slot (a frame applied by the caller wouldn't).
        .frame(maxWidth: .infinity, minHeight: RepoPanelMetrics.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.wash.opacity(isHovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .hoverHighlight($isHovered)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch snapshot.state {
        case .idle:
            Image(systemName: "checkmark.circle").font(.system(size: 10, weight: .bold))
        case .busy:
            SpinningArc(color: snapshot.state.color, arcFraction: 0.6)
                .frame(width: 10, height: 10)
        case .needsAttention:
            Circle().frame(width: 6, height: 6)
        }
    }
}
