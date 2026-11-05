// The PR window's "Files changed": each file collapsible, its diff parsed
// only when expanded, drawn as lazy monospaced rows, capped per file.
import AppKit
import SwiftUI

/// One changed file: a clickable header row, and when expanded its diff —
/// or a note when there's nothing worth drawing (no patch, generated, huge).
struct DiffFileView: View {
    let file: PRFileChange
    /// The PR's diff on the web, for files that can't be shown here.
    let webDiffURL: URL?
    @Binding var isExpanded: Bool

    @State private var lines: [UnifiedDiff.Line]?
    @State private var visibleCount = UnifiedDiff.lineBatch
    /// The user chose to draw a generated / very large file anyway.
    @State private var showsHeavyDiff = false
    @State private var isHovered = false

    private var changedLines: Int { file.additions + file.deletions }
    private var isGenerated: Bool { UnifiedDiff.isLikelyGenerated(file.filename) }
    private var isHeavy: Bool { isGenerated || changedLines > UnifiedDiff.largeChangeThreshold }
    private var shouldRenderDiff: Bool { file.patch != nil && (!isHeavy || showsHeavyDiff) }

    /// Re-parse when the patch changes on refresh, or when the diff first
    /// needs drawing; never while collapsed.
    private struct ParseKey: Equatable {
        let active: Bool
        let length: Int
        let additions: Int
        let deletions: Int
    }

    private var parseKey: ParseKey {
        ParseKey(active: isExpanded && shouldRenderDiff, length: file.patch?.utf8.count ?? 0,
                 additions: file.additions, deletions: file.deletions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded {
                content
            }
        }
        .task(id: parseKey) {
            guard parseKey.active, let patch = file.patch else { return }
            // Off the main thread: a forced-open lock file can be thousands of lines.
            let parsed = await Task.detached(priority: .userInitiated) { UnifiedDiff.parse(patch) }.value
            guard !Task.isCancelled else { return }
            lines = parsed
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
                .frame(width: 10)
            FileChangeRow(file: file)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.wash.opacity(isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        // No animation on the content itself: animating the insertion of
        // hundreds of rows costs more than it shows.
        .onTapGesture { isExpanded.toggle() }
        .hoverHighlight($isHovered)
        .help(isExpanded ? "Hide diff" : "Show diff")
    }

    @ViewBuilder
    private var content: some View {
        if file.patch == nil {
            DiffNote(icon: "doc.badge.ellipsis",
                     text: "No diff to show here — binary file, or too large to display.",
                     actionTitle: webDiffURL == nil ? nil : "View on web ↗",
                     action: { if let webDiffURL { NSWorkspace.shared.open(webDiffURL) } })
        } else if isHeavy && !showsHeavyDiff {
            DiffNote(icon: isGenerated ? "gearshape.2" : "text.alignleft",
                     text: isGenerated ? "Generated or vendored file — hidden by default."
                                       : "Large change (\(changedLines) lines) — hidden by default.",
                     actionTitle: "Show diff",
                     action: { showsHeavyDiff = true })
        } else if let lines {
            diffBody(lines)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Loading diff…").font(.system(size: DetailTypeScale.window.small)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.leading, 20)
        }
    }

    private func diffBody(_ lines: [UnifiedDiff.Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.prefix(visibleCount)) { line in
                    DiffLineRow(line: line)
                }
            }
            .textSelection(.enabled)

            if lines.count > visibleCount {
                let remaining = lines.count - visibleCount
                ShowMoreRow(title: "Show \(min(remaining, UnifiedDiff.lineBatch)) more lines · \(remaining) hidden") {
                    visibleCount += UnifiedDiff.lineBatch
                }
            }
        }
        .background(Palette.wash.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.wash.opacity(0.08)))
    }
}

/// One diff line: old/new line-number gutter, marker, wrapped code.
private struct DiffLineRow: View {
    let line: UnifiedDiff.Line

    /// Five digits at the window's 12pt monospaced size.
    private static let numberWidth: CGFloat = 40

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            switch line.kind {
            case .hunk, .meta:
                Text(line.text)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.leading, Self.numberWidth * 2 + 8)
                    .padding(.vertical, 3)
            case .added, .removed, .context:
                number(line.oldNumber)
                number(line.newNumber)
                Text(marker)
                    .foregroundStyle(markerColor)
                    .frame(width: 16)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 8)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: DetailTypeScale.window.mono, design: .monospaced))
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Palette.textTertiary)
            .frame(width: Self.numberWidth, alignment: .trailing)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return " "
        }
    }

    private var markerColor: Color {
        line.kind == .added ? RepoActivityState.idle.color : Palette.danger
    }

    private var background: Color {
        switch line.kind {
        case .added: return RepoActivityState.idle.color.opacity(0.12)
        case .removed: return Palette.danger.opacity(0.12)
        case .hunk: return Palette.accent.opacity(0.08)
        case .context, .meta: return .clear
        }
    }
}

/// Why a file's diff isn't drawn, with the one action that helps.
private struct DiffNote: View {
    let icon: String
    let text: String
    let actionTitle: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: DetailTypeScale.window.small))
                .foregroundStyle(Palette.textTertiary)
            Text(text)
                .font(.system(size: DetailTypeScale.window.small))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            if let actionTitle {
                Text(actionTitle)
                    .font(.system(size: DetailTypeScale.window.small, weight: .semibold))
                    .foregroundStyle(isHovered ? Palette.accentHover : Palette.accent)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
                    .hoverHighlight($isHovered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.wash.opacity(0.04)))
    }
}

private struct ShowMoreRow: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: DetailTypeScale.window.small, weight: .semibold))
            .foregroundStyle(isHovered ? Palette.tabHover : Palette.tabIdle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(isHovered ? 0.06 : 0.03))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .hoverHighlight($isHovered)
    }
}
