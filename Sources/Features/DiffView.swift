// The PR window's "Files changed": each file collapsible, its diff parsed
// only when expanded, drawn as lazy monospaced rows, capped per file.
//
// Inline review, the way GitHub and GitLab do it: posted threads sit under
// their line (reply, resolve); hovering a line offers a "+" whose box can
// post a single comment now or add it to your pending review ("Start a
// review"). The pending review lives on the provider, so it's shared with
// the web; it's finished from the composer's review button.
import AppKit
import SwiftUI

/// One changed file: a clickable header row, and when expanded its diff —
/// or a note when there's nothing worth drawing (no patch, generated, huge).
struct DiffFileView: View {
    let file: PRFileChange
    /// The PR's diff on the web, for files that can't be shown here.
    let webDiffURL: URL?
    @Binding var isExpanded: Bool
    /// This file's inline threads (your pending notes included).
    var threads: [PRReviewThread] = []
    /// `nil` = read-only (a closed or merged PR): no "+" and no replies.
    var review: InlineReviewActions?

    @State private var lines: [UnifiedDiff.Line]?
    @State private var lineIndex: UnifiedDiff.LineIndex?
    /// The line whose new-comment box is open.
    @State private var composingLineID: Int?
    @State private var visibleCount = UnifiedDiff.lineBatch
    /// The user chose to draw a generated / very large file anyway.
    @State private var showsHeavyDiff = false
    @State private var isHovered = false
    @Environment(\.showToast) private var showToast

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
            let (parsed, index) = await Task.detached(priority: .userInitiated) {
                let parsed = UnifiedDiff.parse(patch)
                return (parsed, UnifiedDiff.LineIndex(parsed))
            }.value
            guard !Task.isCancelled else { return }
            lines = parsed
            lineIndex = index
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
            FileChangeRow(file: file, threads: FileThreadSummary(threads))
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

    /// Threads placed on their drawn line, and those whose line isn't in the
    /// diff (outdated, or no diff drawn).
    private var placement: (byLine: [Int: [PRReviewThread]], unplaced: [PRReviewThread]) {
        var byLine: [Int: [PRReviewThread]] = [:]
        var unplaced: [PRReviewThread] = []
        let index = shouldRenderDiff ? lineIndex : nil
        for thread in threads {
            if let anchor = thread.anchor, let id = index?.lineID(oldLine: anchor.oldLine, newLine: anchor.newLine) {
                byLine[id, default: []].append(thread)
            } else {
                unplaced.append(thread)
            }
        }
        return (byLine, unplaced)
    }

    @ViewBuilder
    private var content: some View {
        let placement = placement
        if !placement.unplaced.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(shouldRenderDiff ? "Outdated — on lines no longer in this diff" : "Comments on this file")
                    .font(.system(size: DetailTypeScale.window.small, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                ForEach(placement.unplaced) { thread in
                    ReviewThreadView(thread: thread, review: review)
                }
            }
            .padding(.leading, 20)
        }
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
            diffBody(lines, threadsByLine: placement.byLine)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Loading diff…").font(.system(size: DetailTypeScale.window.small)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.leading, 20)
        }
    }

    private func diffBody(_ lines: [UnifiedDiff.Line], threadsByLine: [Int: [PRReviewThread]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.prefix(visibleCount)) { line in
                    DiffLineRow(line: line, onComment: commentAction(for: line))
                    if let attached = threadsByLine[line.id] {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(attached) { thread in
                                ReviewThreadView(thread: thread, review: review)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.wash.opacity(0.03))
                    }
                    if composingLineID == line.id, let review, let anchor = anchor(for: line) {
                        InlineComposer(
                            placeholder: "Comment on line \(line.newNumber ?? line.oldNumber ?? 0)",
                            actions: newCommentActions(review: review, anchor: anchor),
                            onCancel: { composingLineID = nil },
                            onDone: { composingLineID = nil }
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Palette.wash.opacity(0.03))
                    }
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

    /// GitHub/GitLab's choice: during a review, only "add to review";
    /// otherwise post it on its own now, or start a review with it.
    private func newCommentActions(review: InlineReviewActions, anchor: DiffAnchor) -> [ComposerAction] {
        let provider = review.provider
        if review.hasPendingReview {
            return [ComposerAction(title: provider.addToReviewAction, isPrimary: true) { text in
                try await review.addComment(anchor, text, true)
                showToast?("Added to your review")
            }]
        }
        return [
            ComposerAction(title: provider.singleCommentAction) { text in
                try await review.addComment(anchor, text, false)
                showToast?("Comment posted")
            },
            ComposerAction(title: "Start a review", isPrimary: true) { text in
                try await review.addComment(anchor, text, true)
                showToast?("Review started")
            },
        ]
    }

    /// The "+" on a hovered line, when this PR takes comments.
    private func commentAction(for line: UnifiedDiff.Line) -> (() -> Void)? {
        guard review != nil, anchor(for: line) != nil else { return nil }
        return { composingLineID = line.id }
    }

    private func anchor(for line: UnifiedDiff.Line) -> DiffAnchor? {
        switch line.kind {
        case .added, .removed, .context:
            return DiffAnchor(path: file.filename, oldLine: line.kind == .added ? nil : line.oldNumber,
                              newLine: line.kind == .removed ? nil : line.newNumber,
                              oldPath: file.previousFilename)
        case .hunk, .meta:
            return nil
        }
    }
}

/// What the diff's review UI can do — handed down by the PR screen. Every
/// action throws the provider's message for the box that ran it to show.
struct InlineReviewActions {
    let provider: ProviderKind
    /// A review is in progress — new comments join it.
    let hasPendingReview: Bool
    var addComment: (_ anchor: DiffAnchor, _ body: String, _ pending: Bool) async throws -> Void
    var updatePending: (_ noteID: String, _ body: String) async throws -> Void
    var deletePending: (_ noteID: String) async throws -> Void
    var reply: (_ threadID: String, _ body: String) async throws -> Void
    var setResolved: (_ threadID: String, _ resolved: Bool) async throws -> Void
}

extension EnvironmentValues {
    /// The PR screen's floating confirmation, for actions deep in the diff.
    @Entry var showToast: ((String) -> Void)? = nil
}

/// One inline thread: its notes (yours still pending marked so, editable),
/// then Reply… and Resolve. Resolved threads start collapsed, as on the web.
private struct ReviewThreadView: View {
    let thread: PRReviewThread
    let review: InlineReviewActions?

    @State private var isReplying = false
    @State private var editingNoteID: String?
    @State private var showsResolved = false
    @State private var isWorking = false
    @State private var actionError: String?
    @Environment(\.showToast) private var showToast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if thread.isResolved && !showsResolved {
                HStack {
                    Button {
                        showsResolved = true
                    } label: {
                        Label("Resolved · \(thread.notes.count) comment\(thread.notes.count == 1 ? "" : "s")",
                              systemImage: "checkmark.circle")
                            .font(.system(size: DetailTypeScale.window.small, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Show the thread")
                    Spacer(minLength: 0)
                }
                .padding(10)
            } else {
                ForEach(Array(thread.notes.enumerated()), id: \.element.id) { index, note in
                    if index > 0 { Divider().padding(.leading, 40) }
                    noteRow(note)
                }
                if let actionError {
                    Text(actionError)
                        .font(.system(size: DetailTypeScale.window.small))
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                footer
            }
        }
        .inlineCard(tint: thread.isPending ? Palette.attention : nil)
    }

    @ViewBuilder
    private func noteRow(_ note: PRReviewNote) -> some View {
        if editingNoteID == note.id, let review {
            InlineComposer(
                placeholder: "Comment",
                initialText: note.text,
                actions: [ComposerAction(title: "Update comment", isPrimary: true) { text in
                    try await review.updatePending(note.id, text)
                    showToast?("Comment updated")
                }],
                onCancel: { editingNoteID = nil },
                onDone: { editingNoteID = nil }
            )
            .padding(10)
        } else {
            HStack(alignment: .top, spacing: 0) {
                InlineCommentRow(author: note.isPending ? "You" : note.author,
                                 initials: note.isPending ? "" : note.initials,
                                 meta: note.isPending ? nil : note.timeAgo,
                                 text: note.text, badge: note.isPending ? "Pending" : nil)
                if note.isPending, review != nil {
                    HStack(spacing: 2) {
                        Button("Edit", systemImage: "pencil") { editingNoteID = note.id }
                            .help("Edit comment")
                        Button("Delete", systemImage: "trash") { delete(note) }
                            .help("Delete comment")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isWorking)
                    .padding(8)
                }
            }
        }
    }

    /// Reply and resolve — not on a thread that only exists in your pending
    /// review yet.
    @ViewBuilder
    private var footer: some View {
        if let review, !thread.isPending {
            Divider()
            if isReplying {
                InlineComposer(
                    placeholder: "Reply…",
                    actions: [ComposerAction(title: "Reply", isPrimary: true) { text in
                        try await review.reply(thread.id, text)
                        showToast?("Reply posted")
                    }],
                    onCancel: { isReplying = false },
                    onDone: { isReplying = false }
                )
                .padding(10)
            } else {
                HStack(spacing: 12) {
                    Button("Reply…") { isReplying = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .pointerStyle(.link)
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    if thread.canResolve {
                        Button(thread.isResolved ? review.provider.unresolveThreadAction
                                                 : review.provider.resolveThreadAction) {
                            setResolved(!thread.isResolved)
                        }
                        .controlSize(.small)
                        .disabled(isWorking)
                    }
                }
                .font(.system(size: DetailTypeScale.window.small))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
    }

    private func delete(_ note: PRReviewNote) {
        guard let review else { return }
        run { try await review.deletePending(note.id); showToast?("Comment deleted") }
    }

    private func setResolved(_ resolved: Bool) {
        guard let review else { return }
        run {
            try await review.setResolved(thread.id, resolved)
            showToast?(resolved ? "Resolved" : "Unresolved")
            if resolved { showsResolved = false }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        actionError = nil
        Task {
            do { try await work() } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? "That didn't work."
            }
            isWorking = false
        }
    }
}

/// Avatar, author, time and the Markdown body — one comment in a thread.
private struct InlineCommentRow: View {
    let author: String
    let initials: String
    let meta: String?
    let text: String
    var badge: String?

    private let type = DetailTypeScale.window

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(LinearGradient(colors: [Palette.accent, Palette.accentPurple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay {
                    if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(.white)
                    } else {
                        Text(initials).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(author).font(.system(size: type.comment, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                    if let meta, !meta.isEmpty {
                        Text(meta).font(.system(size: type.small)).foregroundStyle(Palette.textTertiary)
                    }
                    if let badge {
                        Text(badge)
                            .font(.system(size: type.chip, weight: .bold))
                            .foregroundStyle(Palette.attention)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Palette.attention.opacity(0.14)))
                    }
                }
                RenderedBodyText(markdown: text, fontSize: type.comment, textColor: Palette.textComment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

/// One button under an `InlineComposer`. The primary one is prominent and
/// takes ⌘↩.
struct ComposerAction: Identifiable {
    let title: String
    var isPrimary = false
    let run: (String) async throws -> Void
    var id: String { title }
}

/// A small comment box inside the diff: a text-field-like well, Cancel and
/// its actions. Runs the chosen action itself — spinner while it's out,
/// the provider's message (text kept) if it fails, `onDone` when it worked.
struct InlineComposer: View {
    let placeholder: String
    var initialText = ""
    let actions: [ComposerAction]
    let onCancel: () -> Void
    let onDone: () -> Void

    @State private var text = ""
    @State private var isBusy = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private let fontSize = DetailTypeScale.window.body
    private let inset: CGFloat = 8

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ComposerWell(isFocused: isFocused)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Palette.textPlaceholder)
                        .padding(.leading, inset + 5)
                        .padding(.top, inset)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(OverlayScrollers())
                    .padding(inset)
                    .focused($isFocused)
                    .disabled(isBusy)
            }
            .frame(height: 84)

            if let error {
                Text(error)
                    .font(.system(size: DetailTypeScale.window.small))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Text("Markdown supported")
                    .font(.system(size: DetailTypeScale.window.small))
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                ForEach(actions) { action in
                    if action.isPrimary {
                        Button(action.title) { run(action) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(isEmpty || isBusy)
                    } else {
                        Button(action.title) { run(action) }
                            .disabled(isEmpty || isBusy)
                    }
                }
            }
            .controlSize(.regular)
        }
        // Opened by a click on "+", "Reply…" or Edit — so it takes focus.
        .onAppear {
            text = initialText
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private func run(_ action: ComposerAction) {
        guard !isEmpty, !isBusy else { return }
        isBusy = true
        error = nil
        let body = text
        Task {
            do {
                try await action.run(body)
                isBusy = false
                onDone()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't post the comment."
                isBusy = false
            }
        }
    }
}

private extension View {
    /// The rounded card a thread sits in; a pending one gets the attention
    /// tint down its leading edge.
    func inlineCard(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
            .overlay(shape.strokeBorder(tint?.opacity(0.45) ?? Color(nsColor: .separatorColor)))
            .overlay(alignment: .leading) {
                if let tint {
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, style: .continuous)
                        .fill(tint)
                        .frame(width: 3)
                }
            }
    }
}

/// One diff line: old/new line-number gutter, marker, wrapped code — and on
/// hover, a "+" to comment on it.
private struct DiffLineRow: View {
    let line: UnifiedDiff.Line
    var onComment: (() -> Void)?

    @State private var isHovered = false

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
        .overlay(alignment: .leading) {
            if isHovered, let onComment {
                Button(action: onComment) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Comment on this line")
                .padding(.leading, 2)
            }
        }
        .onHover { hovering in
            if onComment != nil { isHovered = hovering }
        }
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
