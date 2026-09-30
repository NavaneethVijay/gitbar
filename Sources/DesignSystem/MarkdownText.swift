import AppKit
import SwiftUI
import Markdown

/// Styled text in a selectable `NSTextView` rather than SwiftUI `Text`, so
/// links open on click and get a pointing-hand cursor (see `LinkCursorTextView`).
struct RichText: NSViewRepresentable {
    let attributedString: NSAttributedString

    /// Last measurement: SwiftUI asks for the size on every layout pass, and
    /// each answer otherwise costs a full text layout.
    final class Coordinator {
        var measuredWidth: CGFloat = -1
        var measuredText: NSAttributedString?
        var measuredHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let textView = LinkCursorTextView.make()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        // SwiftUI owns the frame; a self-resizing text view fights it.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        // Links carry their own color from restyling; stop NSTextView adding
        // its default blue + underline. Click-to-open comes from `.link` itself.
        textView.linkTextAttributes = [:]
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // SwiftUI calls this on every redraw of the parent; resetting identical
        // text forces a full re-layout + repaint, which shows as flicker.
        guard let storage = textView.textStorage, !storage.isEqual(to: attributedString) else { return }
        storage.setAttributedString(attributedString)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let cache = context.coordinator
        if cache.measuredWidth == width, let text = cache.measuredText,
           text === attributedString || text.isEqual(to: attributedString) {
            return CGSize(width: width, height: cache.measuredHeight)
        }
        let height = Self.measureHeight(attributedString, width: width)
        cache.measuredWidth = width
        cache.measuredText = attributedString
        cache.measuredHeight = height
        return CGSize(width: width, height: height)
    }

    /// Measured on a throwaway TextKit 1 stack, never the live view's.
    /// Resizing the live container to each width SwiftUI probed left it
    /// wrapping at a probe width after layout settled on another one — the
    /// text drew taller than measured and overlapped the next block.
    private static func measureHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }
}

/// A selectable `NSTextView` shows the I-beam everywhere; this adds
/// pointing-hand cursor rects over each link on top of it.
final class LinkCursorTextView: NSTextView {
    /// A text view built on an explicit text stack doesn't own it.
    private var ownedStorage: NSTextStorage?

    /// Explicitly TextKit 1, the same system `RichText.measureHeight` lays
    /// out with — a default `NSTextView` starts on TextKit 2 and only falls
    /// back when `layoutManager` is touched, so measured and drawn line
    /// heights could differ.
    static func make() -> LinkCursorTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let textView = LinkCursorTextView(frame: .zero, textContainer: container)
        textView.ownedStorage = storage
        return textView
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let textStorage, let layoutManager, let textContainer else { return }
        textStorage.enumerateAttribute(.link, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }
}

/// A PR description, comment or review body, parsed directly from the
/// provider's raw Markdown (GitHub's `body`) with `swift-markdown` and
/// rendered as native SwiftUI views — one per block type (heading,
/// paragraph, code block, blockquote, list, table, image). No HTML import,
/// no WebKit: every element is under our own control.
struct RenderedBodyText: View {
    let markdown: String
    var fontSize: CGFloat = 12
    var textColor: Color = Palette.textBody
    var linkColor: Color = Palette.accent

    var body: some View {
        // Only bodies that can contain images re-render as images arrive.
        let imageVersion = markdown.contains("![") ? MarkdownImageCache.shared.version : 0
        let blocks = Self.cachedBlocks(markdown, imageVersion: imageVersion, fontSize: fontSize,
                                       textColor: textColor, linkColor: linkColor)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, fontSize: fontSize)
            }
        }
    }

    /// Parsing is synchronous and fast (no WebKit spin-up), but still worth
    /// memoizing: `body` runs on every redraw of the popover.
    private final class RenderedMarkdown {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, RenderedMarkdown> = {
        let cache = NSCache<NSString, RenderedMarkdown>()
        cache.countLimit = 200
        return cache
    }()

    @MainActor
    private static func cachedBlocks(_ markdown: String, imageVersion: Int, fontSize: CGFloat,
                                     textColor: Color, linkColor: Color) -> [MarkdownBlock] {
        let key = "\(imageVersion)|\(fontSize)|\(textColor)|\(linkColor)|\(markdown)" as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let document = Document(parsing: markdown)
        let blocks = MarkdownRenderer.blocks(from: document, fonts: BodyFonts(size: fontSize),
                                             textColor: NSColor(textColor), linkColor: NSColor(linkColor))
        cache.setObject(RenderedMarkdown(blocks), forKey: key)
        return blocks
    }
}

/// Images referenced from Markdown bodies, fetched once per session and
/// shared by inline attachments and picture blocks. `version` bumps on
/// every finished load so bodies re-render with the new image.
@MainActor @Observable
final class MarkdownImageCache {
    static let shared = MarkdownImageCache()

    private(set) var version = 0
    private var images: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    @ObservationIgnored private var inFlight: Set<URL> = []

    func image(for url: URL) -> NSImage? { images[url] }
    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    func load(_ url: URL) {
        guard images[url] == nil, !failed.contains(url), !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task {
            defer { inFlight.remove(url) }
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                images[url] = image
            } else {
                failed.insert(url)
            }
            version += 1
        }
    }
}

/// One block-level element the renderer supports. `blockQuote`/`list` are
/// recursive so nested content (a list inside a quote, a sub-list) renders
/// correctly.
enum MarkdownBlock {
    case heading(level: Int, text: NSAttributedString)
    case paragraph(NSAttributedString)
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case table(ParsedTable)
    case thematicBreak
    /// `linkURL` is set when the image is itself wrapped in a link (a common
    /// "badge" pattern, `[![alt](img)](href)`) — tapping opens that instead
    /// of the raw image.
    case image(url: URL?, alt: String, linkURL: URL?)
    /// Stray raw HTML (rare now that checkboxes/images have real Markdown
    /// syntax) — tag-stripped plain text rather than vanishing.
    case rawHTML(String)
}

struct MarkdownListItem {
    let checkbox: Markdown.Checkbox?
    let blocks: [MarkdownBlock]
}

/// A GFM table: `rows[0]` is always the header row.
struct ParsedTable {
    let rows: [[NSAttributedString]]
}

/// Walks a `swift-markdown` AST into `[MarkdownBlock]` / `NSAttributedString`
/// runs — the whole native renderer. Bold/italic/code/link state is tracked
/// explicitly while recursing through inline containers (`Strong`,
/// `Emphasis`, `Link`, …), so nested combinations (a bold link, italic inside
/// a list item) compose correctly.
@MainActor
private enum MarkdownRenderer {
    static func blocks(from markup: Markup, fonts: BodyFonts, textColor: NSColor, linkColor: NSColor) -> [MarkdownBlock] {
        markup.children.flatMap { blockNodes(for: $0, fonts: fonts, textColor: textColor, linkColor: linkColor) }
    }

    private static func blockNodes(for markup: Markup, fonts: BodyFonts, textColor: NSColor, linkColor: NSColor) -> [MarkdownBlock] {
        switch markup {
        case let heading as Heading:
            let scale: CGFloat = heading.level == 1 ? 1.4 : heading.level == 2 ? 1.25 : heading.level == 3 ? 1.12 : 1.0
            let headingFonts = BodyFonts(size: (fonts.regular.pointSize * scale).rounded())
            return [.heading(level: heading.level,
                             text: inline(heading, fonts: headingFonts, textColor: textColor, linkColor: linkColor, bold: true))]
        case let paragraph as Paragraph:
            return paragraphBlocks(paragraph, fonts: fonts, textColor: textColor, linkColor: linkColor)
        case let codeBlock as CodeBlock:
            return [.codeBlock(language: codeBlock.language, code: codeBlock.code)]
        case let quote as BlockQuote:
            // Dimmed like GitHub's own quote styling, regardless of the
            // ambient text color.
            return [.blockQuote(blocks(from: quote, fonts: fonts, textColor: NSColor(Palette.textTertiary), linkColor: linkColor))]
        case let list as UnorderedList:
            return [.list(ordered: false, start: 1, items: renderListItems(list, fonts: fonts, textColor: textColor, linkColor: linkColor))]
        case let list as OrderedList:
            return [.list(ordered: true, start: Int(list.startIndex),
                         items: renderListItems(list, fonts: fonts, textColor: textColor, linkColor: linkColor))]
        case let table as Markdown.Table:
            return [.table(parseTable(table, fonts: fonts, textColor: textColor, linkColor: linkColor))]
        case is ThematicBreak:
            return [.thematicBreak]
        case let image as Markdown.Image:
            return [.image(url: image.source.flatMap(URL.init(string:)), alt: plainText(image), linkURL: nil)]
        case let html as HTMLBlock:
            let text = stripTags(html.rawHTML)
            return text.isEmpty ? [] : [.rawHTML(text)]
        default:
            let text = inline(markup, fonts: fonts, textColor: textColor, linkColor: linkColor)
            return text.length > 0 ? [.paragraph(text)] : []
        }
    }

    /// A paragraph made only of images (a screenshot, a row of badges)
    /// becomes picture blocks; an image mixed with text (an icon before a
    /// label) stays inline as an attachment — see `appendImage`.
    private static func paragraphBlocks(_ paragraph: Paragraph, fonts: BodyFonts, textColor: NSColor, linkColor: NSColor) -> [MarkdownBlock] {
        let content = paragraph.children.filter { !isBlank($0) }
        let pictures = content.compactMap(standaloneImage)
        if !content.isEmpty, pictures.count == content.count {
            return pictures.map { image, link in
                .image(url: image.source.flatMap(URL.init(string:)), alt: plainText(image), linkURL: link)
            }
        }
        let text = inline(paragraph, fonts: fonts, textColor: textColor, linkColor: linkColor)
        return text.length > 0 ? [.paragraph(text)] : []
    }

    /// An image, or a link wrapping only an image (the `[![alt](img)](href)`
    /// badge pattern — tapping opens the link, not the raw image).
    private static func standaloneImage(_ markup: Markup) -> (Markdown.Image, URL?)? {
        if let image = markup as? Markdown.Image { return (image, nil) }
        if let link = markup as? Markdown.Link, let image = onlyImage(in: link) {
            return (image, link.destination.flatMap(URL.init(string:)))
        }
        return nil
    }

    private static func isBlank(_ markup: Markup) -> Bool {
        if markup is SoftBreak || markup is LineBreak { return true }
        if let text = markup as? Markdown.Text { return text.string.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }

    private static func renderListItems(_ container: some ListItemContainer, fonts: BodyFonts, textColor: NSColor, linkColor: NSColor) -> [MarkdownListItem] {
        container.listItems.map { item in
            MarkdownListItem(checkbox: item.checkbox, blocks: blocks(from: item, fonts: fonts, textColor: textColor, linkColor: linkColor))
        }
    }

    private static func parseTable(_ table: Markdown.Table, fonts: BodyFonts, textColor: NSColor, linkColor: NSColor) -> ParsedTable {
        func cellText(_ cell: Markdown.Table.Cell) -> NSAttributedString {
            inline(cell, fonts: fonts, textColor: textColor, linkColor: linkColor)
        }
        var rows: [[NSAttributedString]] = [table.head.cells.map(cellText)]
        rows += table.body.rows.map { $0.cells.map(cellText) }
        return ParsedTable(rows: rows)
    }

    private static func inline(_ markup: Markup, fonts: BodyFonts, textColor: NSColor, linkColor: NSColor, bold: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            appendInline(child, to: result, fonts: fonts, bold: bold, italic: false, code: false,
                        textColor: textColor, linkColor: linkColor, linkURL: nil)
        }
        return result
    }

    private static func appendInline(_ markup: Markup, to result: NSMutableAttributedString, fonts: BodyFonts,
                                     bold: Bool, italic: Bool, code: Bool,
                                     textColor: NSColor, linkColor: NSColor, linkURL: URL?) {
        switch markup {
        case let text as Markdown.Text:
            append(text.string, to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                  textColor: textColor, linkColor: linkColor, linkURL: linkURL)
        case is SoftBreak:
            append(" ", to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                  textColor: textColor, linkColor: linkColor, linkURL: linkURL)
        case is LineBreak:
            append("\n", to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                  textColor: textColor, linkColor: linkColor, linkURL: linkURL)
        case let inlineCode as InlineCode:
            append(inlineCode.code, to: result, fonts: fonts, bold: bold, italic: italic, code: true,
                  textColor: textColor, linkColor: linkColor, linkURL: linkURL, isCodeSpan: true)
        case let strong as Strong:
            for child in strong.children {
                appendInline(child, to: result, fonts: fonts, bold: true, italic: italic, code: code,
                            textColor: textColor, linkColor: linkColor, linkURL: linkURL)
            }
        case let emphasis as Emphasis:
            for child in emphasis.children {
                appendInline(child, to: result, fonts: fonts, bold: bold, italic: true, code: code,
                            textColor: textColor, linkColor: linkColor, linkURL: linkURL)
            }
        case let strike as Strikethrough:
            let start = result.length
            for child in strike.children {
                appendInline(child, to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                            textColor: textColor, linkColor: linkColor, linkURL: linkURL)
            }
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                range: NSRange(location: start, length: result.length - start))
        case let link as Markdown.Link:
            let url = link.destination.flatMap(URL.init(string:))
            for child in link.children {
                appendInline(child, to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                            textColor: textColor, linkColor: linkColor, linkURL: url ?? linkURL)
            }
        case let image as Markdown.Image:
            appendImage(image, to: result, fonts: fonts, textColor: textColor, linkURL: linkURL)
        case let html as InlineHTML:
            append(stripTags(html.rawHTML), to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                  textColor: textColor, linkColor: linkColor, linkURL: linkURL)
        default:
            for child in markup.children {
                appendInline(child, to: result, fonts: fonts, bold: bold, italic: italic, code: code,
                            textColor: textColor, linkColor: linkColor, linkURL: linkURL)
            }
        }
    }

    private static func append(_ string: String, to result: NSMutableAttributedString, fonts: BodyFonts,
                               bold: Bool, italic: Bool, code: Bool,
                               textColor: NSColor, linkColor: NSColor, linkURL: URL?, isCodeSpan: Bool = false) {
        let font = fonts.font(bold: bold, italic: italic, code: code)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: linkURL != nil ? linkColor : textColor]
        if let linkURL { attributes[.link] = linkURL }
        if isCodeSpan { attributes[.backgroundColor] = codeSpanBackground }
        result.append(NSAttributedString(string: string, attributes: attributes))
    }

    private static let codeSpanBackground = NSColor(Palette.wash.opacity(0.08))

    /// An image flowed inline with text. Until it loads it takes no space
    /// (the body re-renders when `MarkdownImageCache` finishes); if it can't
    /// load, its alt text stands in.
    private static func appendImage(_ image: Markdown.Image, to result: NSMutableAttributedString, fonts: BodyFonts,
                                    textColor: NSColor, linkURL: URL?) {
        guard let url = image.source.flatMap(URL.init(string:)) else { return }
        let cache = MarkdownImageCache.shared
        if let loaded = cache.image(for: url) {
            let attachment = NSTextAttachment()
            attachment.image = loaded
            let size = inlineSize(for: loaded.size, font: fonts.regular)
            attachment.bounds = CGRect(x: 0, y: (fonts.regular.capHeight - size.height) / 2,
                                       width: size.width, height: size.height)
            let piece = NSMutableAttributedString(attachment: attachment)
            if let linkURL { piece.addAttribute(.link, value: linkURL, range: NSRange(location: 0, length: piece.length)) }
            result.append(piece)
        } else if cache.hasFailed(url) {
            let alt = plainText(image)
            guard !alt.isEmpty else { return }
            append(alt, to: result, fonts: fonts, bold: false, italic: false, code: false,
                  textColor: NSColor(Palette.textTertiary), linkColor: NSColor(Palette.textTertiary), linkURL: linkURL)
        } else {
            cache.load(url)
        }
    }

    /// Icon-sized images sit at text height; anything bigger keeps its own
    /// size, only shrunk to fit the popover.
    private static func inlineSize(for native: CGSize, font: NSFont) -> CGSize {
        guard native.width > 0, native.height > 0 else { return .zero }
        let iconHeight = (font.pointSize * 1.25).rounded()
        if native.height <= font.pointSize * 2.5 {
            return CGSize(width: (native.width * iconHeight / native.height).rounded(), height: iconHeight)
        }
        let scale = min(1, 300 / native.width, 220 / native.height)
        return CGSize(width: (native.width * scale).rounded(), height: (native.height * scale).rounded())
    }

    private static func plainText(_ markup: Markup) -> String {
        var text = ""
        for child in markup.children {
            if let leaf = child as? Markdown.Text { text += leaf.string } else { text += plainText(child) }
        }
        return text
    }

    /// The link's one child, if it wraps exactly a single image (the "badge" pattern).
    private static func onlyImage(in link: Markdown.Link) -> Markdown.Image? {
        var iterator = link.children.makeIterator()
        guard let first = iterator.next(), iterator.next() == nil else { return nil }
        return first as? Markdown.Image
    }

    private static let tagPattern = try? NSRegularExpression(pattern: "<[^>]+>")

    private static func stripTags(_ html: String) -> String {
        guard let tagPattern else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return tagPattern.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Views, one per `MarkdownBlock` case

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat

    var body: some View {
        switch block {
        case .heading(_, let text):
            RichText(attributedString: text)
        case .paragraph(let text):
            RichText(attributedString: text)
        case .codeBlock(_, let code):
            CodeBlockView(code: code, fontSize: fontSize)
        case .blockQuote(let blocks):
            BlockQuoteView(blocks: blocks, fontSize: fontSize)
        case .list(let ordered, let start, let items):
            MarkdownListView(ordered: ordered, start: start, items: items, fontSize: fontSize)
        case .table(let table):
            TableGridView(table: table)
        case .thematicBreak:
            Rectangle().fill(Palette.wash.opacity(0.12)).frame(height: 1)
        case .image(let url, let alt, let linkURL):
            ImageBlockView(url: url, alt: alt, linkURL: linkURL)
        case .rawHTML(let text):
            Text(text).font(.system(size: fontSize)).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// Recursive: a list item's blocks can include a nested sub-list, which
/// renders as another `MarkdownListView` indented inside this one's row.
private struct MarkdownListView: View {
    let ordered: Bool
    let start: Int
    let items: [MarkdownListItem]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    marker(for: item, index: index)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block, fontSize: fontSize)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, index: Int) -> some View {
        if let checkbox = item.checkbox {
            let checked: Bool = { if case .checked = checkbox { return true }; return false }()
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(checked ? RepoActivityState.idle.color : Palette.textTertiary)
        } else if ordered {
            Text("\(start + index).")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(Palette.textTertiary)
        } else {
            Text("•")
                .font(.system(size: fontSize))
                .foregroundStyle(Palette.textTertiary)
        }
    }
}

/// A fenced code block: monospaced, boxed, and horizontally scrollable so
/// long lines don't wrap badly — real code-block treatment rather than just
/// tinting fixed-pitch text.
private struct CodeBlockView: View {
    let code: String
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: fontSize - 0.5, design: .monospaced))
                .foregroundStyle(Palette.textBody)
                .fixedSize(horizontal: true, vertical: false)
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.wash.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.wash.opacity(0.1)))
    }
}

/// A left accent bar beside the nested blocks — the drawn rule
/// `NSAttributedString`-only rendering couldn't do.
private struct BlockQuoteView: View {
    let blocks: [MarkdownBlock]
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Palette.accent.opacity(0.4)).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, fontSize: fontSize)
                }
            }
        }
    }
}

/// A picture block, from `MarkdownImageCache` (not `AsyncImage`) so its
/// native size is known: small badges render at their own size, capped only
/// if larger than the popover — `AsyncImage` + `.scaledToFit()` always
/// scales *up* to fill its frame, which blurs a small source image out.
private struct ImageBlockView: View {
    let url: URL?
    let alt: String
    /// Set when the image is itself wrapped in a link — tap opens that
    /// instead of the raw image.
    let linkURL: URL?

    private static let maxSize = CGSize(width: 320, height: 220)

    var body: some View {
        if let url {
            let cache = MarkdownImageCache.shared
            Group {
                if let image = cache.image(for: url) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: displaySize(for: image.size).width, height: displaySize(for: image.size).height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if cache.hasFailed(url) {
                    Label(alt.isEmpty ? "Image failed to load" : alt, systemImage: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                } else {
                    ProgressView().controlSize(.small).frame(height: 40)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(linkURL ?? url) }
            .task(id: url) { cache.load(url) }
        } else if !alt.isEmpty {
            Text(alt).font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
        }
    }

    /// Never upscales — only shrinks an image larger than `maxSize`.
    private func displaySize(for native: CGSize) -> CGSize {
        guard native.width > 0, native.height > 0 else { return .zero }
        let scale = min(1, min(Self.maxSize.width / native.width, Self.maxSize.height / native.height))
        return CGSize(width: (native.width * scale).rounded(), height: (native.height * scale).rounded())
    }
}

/// Draws a table parsed from the Markdown AST. `NSTextTable` can't display
/// borders reliably in `NSTextView`, so cells are plain attributed strings
/// drawn in a SwiftUI `Grid` instead.
private struct TableGridView: View {
    let table: ParsedTable

    private let borderColor = Palette.wash.opacity(0.14)
    private let headerBackground = Palette.wash.opacity(0.06)

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(AttributedString(cell))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            // Top-align short cells; Grid centers them by default,
                            // which reads as phantom blank rows.
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(rowIndex == 0 ? headerBackground : Color.clear)
                            .overlay(Rectangle().strokeBorder(borderColor, lineWidth: 0.5))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 0.5))
    }
}

/// The body text faces shared across the renderer.
private struct BodyFonts {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let mono: NSFont

    init(size: CGFloat) {
        regular = NSFont.systemFont(ofSize: size)
        bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        mono = NSFont.monospacedSystemFont(ofSize: size - 0.5, weight: .regular)
    }

    func font(bold isBold: Bool, italic isItalic: Bool, code: Bool) -> NSFont {
        if code { return mono }
        switch (isBold, isItalic) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        case (false, false): return regular
        }
    }
}
