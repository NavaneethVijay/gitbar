import AppKit
import SwiftUI

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
        let textView = LinkCursorTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
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
        guard let width = proposal.width, width.isFinite, width > 0, let container = nsView.textContainer,
              let layoutManager = nsView.layoutManager else { return nil }
        let cache = context.coordinator
        if cache.measuredWidth == width, let text = cache.measuredText,
           text === attributedString || text.isEqual(to: attributedString) {
            return CGSize(width: width, height: cache.measuredHeight)
        }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        // `usedRect` reports zero height across `NSTextTable` blocks; the glyph
        // bounding rect doesn't. Take the max so plain text sizing is unchanged.
        let usedHeight = layoutManager.usedRect(for: container).height
        let glyphRange = layoutManager.glyphRange(for: container)
        let boundingHeight = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).height
        let height = ceil(max(usedHeight, boundingHeight))
        cache.measuredWidth = width
        cache.measuredText = attributedString
        cache.measuredHeight = height
        return CGSize(width: width, height: height)
    }
}

/// Rendered bodies, keyed by source text + styling. `NSCache` evicts on its
/// own under memory pressure; the count limit just bounds a long session.
enum RenderCache {
    static let shared: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 300
        return cache
    }()

    static func key(_ kind: String, _ source: String, _ fontSize: CGFloat, _ textColor: Color, _ linkColor: Color) -> NSString {
        "\(kind)|\(fontSize)|\(textColor)|\(linkColor)|\(source)" as NSString
    }
}

/// A selectable `NSTextView` shows the I-beam everywhere; this adds
/// pointing-hand cursor rects over each link on top of it.
final class LinkCursorTextView: NSTextView {
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

/// A PR description or comment, rendered from the provider's own
/// server-rendered HTML (e.g. GitHub's `body_html`) via AppKit's HTML
/// importer and restyled to the app's theme — so tables, task lists and
/// embedded HTML look like they do on the web. Without HTML, falls back to
/// `MarkdownText`.
struct RenderedBodyText: View {
    let html: String?
    let fallbackMarkdown: String
    var fontSize: CGFloat = 12
    var textColor: Color = Palette.textBody
    var linkColor: Color = Palette.accent

    /// The HTML version, once rendered. Rendering (AppKit's HTML importer,
    /// i.e. WebKit) is slow and main-thread only, so a cold body first shows
    /// the plain Markdown version and swaps in the HTML one just after the
    /// screen's slide-in, instead of stalling that animation.
    @State private var rendered: RenderedBody?

    private var cacheKey: String? {
        html.map { RenderCache.key("body", $0, fontSize, textColor, linkColor) as String }
    }

    var body: some View {
        if let html, let key = cacheKey {
            if let ready = (rendered?.key == key ? rendered : nil) ?? Self.bodyCache.object(forKey: key as NSString) {
                // Tables are split out and drawn separately — see `BodySegment`.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ready.parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let text): RichText(attributedString: text)
                        case .table(let table): TableGridView(table: table)
                        }
                    }
                }
            } else {
                MarkdownText(markdown: fallbackMarkdown, fontSize: fontSize, textColor: textColor, linkColor: linkColor)
                    .task(id: key) {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        rendered = Self.renderBody(html, key: key, fontSize: fontSize, textColor: textColor, linkColor: linkColor)
                    }
            }
        } else {
            MarkdownText(markdown: fallbackMarkdown, fontSize: fontSize, textColor: textColor, linkColor: linkColor)
        }
    }

    /// A fully rendered body: every text chunk imported, every table parsed.
    final class RenderedBody {
        enum Part {
            case text(NSAttributedString)
            case table(ParsedTable)
        }
        let key: String
        let parts: [Part]
        init(key: String, parts: [Part]) { self.key = key; self.parts = parts }
    }

    private static let bodyCache: NSCache<NSString, RenderedBody> = {
        let cache = NSCache<NSString, RenderedBody>()
        cache.countLimit = 200
        return cache
    }()

    private static func renderBody(_ html: String, key: String, fontSize: CGFloat, textColor: Color, linkColor: Color) -> RenderedBody {
        let parts: [RenderedBody.Part] = splitSegments(html).compactMap { segment in
            switch segment {
            case .text(let chunk):
                return render(chunk, fontSize: fontSize, textColor: textColor, linkColor: linkColor).map { .text($0) }
            case .table(let tableHTML):
                return parseTable(tableHTML, fontSize: fontSize, textColor: textColor, linkColor: linkColor).map { .table($0) }
            }
        }
        let body = RenderedBody(key: key, parts: parts)
        bodyCache.setObject(body, forKey: key as NSString)
        return body
    }

    /// Flowed HTML, or a `<table>` block. The importer parses tables into
    /// correct `NSTextTableBlock`s, but `NSTextView` can't display them
    /// reliably (no visible borders without CSS; blank data rows with it), so
    /// cell text is extracted and drawn by a SwiftUI `Grid` instead.
    private enum BodySegment {
        case text(String)
        case table(String)
    }

    private static let tableTagPattern = try? NSRegularExpression(
        pattern: "<table\\b[^>]*>.*?</table>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func splitSegments(_ html: String) -> [BodySegment] {
        guard let regex = tableTagPattern else { return [.text(html)] }
        let fullRange = NSRange(html.startIndex..., in: html)
        var segments: [BodySegment] = []
        var cursor = html.startIndex
        for match in regex.matches(in: html, options: [], range: fullRange) {
            guard let range = Range(match.range, in: html) else { continue }
            if cursor < range.lowerBound {
                segments.append(.text(String(html[cursor..<range.lowerBound])))
            }
            segments.append(.table(String(html[range])))
            cursor = range.upperBound
        }
        if cursor < html.endIndex {
            segments.append(.text(String(html[cursor...])))
        }
        return segments.isEmpty ? [.text(html)] : segments
    }

    /// `rows[0]` is always the header row — every GFM table has one.
    struct ParsedTable {
        let rows: [[NSAttributedString]]
    }

    private static func parseTable(_ html: String, fontSize: CGFloat, textColor: Color, linkColor: Color) -> ParsedTable? {
        guard let restyled = render(html, fontSize: fontSize, textColor: textColor, linkColor: linkColor) else { return nil }

        var cellsByRow: [Int: [Int: NSAttributedString]] = [:]
        var maxColumn = 0
        restyled.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: restyled.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, let block = style.textBlocks.first as? NSTextTableBlock else { return }
            let cellText = trimmingTrailingNewline(restyled.attributedSubstring(from: range))
            cellsByRow[block.startingRow, default: [:]][block.startingColumn] = cellText
            maxColumn = max(maxColumn, block.startingColumn)
        }
        guard !cellsByRow.isEmpty else { return nil }

        let rows = cellsByRow.keys.sorted().map { rowIndex in
            (0...maxColumn).map { column in cellsByRow[rowIndex]?[column] ?? NSAttributedString(string: "") }
        }
        return ParsedTable(rows: rows)
    }

    /// The importer ends every cell's paragraph with `\n`.
    private static func trimmingTrailingNewline(_ attr: NSAttributedString) -> NSAttributedString {
        guard attr.length > 0, attr.string.hasSuffix("\n") else { return attr }
        return attr.attributedSubstring(from: NSRange(location: 0, length: attr.length - 1))
    }

    /// AppKit's HTML importer must run on the main thread (views are `@MainActor`)
    /// and is slow (it spins up WebKit), so results are cached: `body` runs on
    /// every redraw of the popover, and re-importing each time made it flicker.
    /// Colors are dynamic system colors, so a cached string still follows the theme.
    private static func render(_ html: String, fontSize: CGFloat, textColor: Color, linkColor: Color) -> NSAttributedString? {
        let key = RenderCache.key("html", html, fontSize, textColor, linkColor)
        if let cached = RenderCache.shared.object(forKey: key) { return cached }
        guard let rendered = importHTML(html, fontSize: fontSize, textColor: textColor, linkColor: linkColor) else { return nil }
        RenderCache.shared.setObject(rendered, forKey: key)
        return rendered
    }

    private static func importHTML(_ html: String, fontSize: CGFloat, textColor: Color, linkColor: Color) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let imported = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        return restyle(imported, fontSize: fontSize, textColor: textColor, linkColor: linkColor)
    }

    /// Swaps the importer's baked-in fonts/colors for the app's, keeping
    /// bold, italic and fixed-pitch distinguishable and links in the accent.
    private static func restyle(_ ns: NSAttributedString, fontSize: CGFloat, textColor: Color, linkColor: Color) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: ns)
        let fullRange = NSRange(location: 0, length: result.length)
        let fonts = BodyFonts(size: fontSize)

        result.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let font: NSFont
            if let original = value as? NSFont {
                let traits = original.fontDescriptor.symbolicTraits
                font = fonts.font(bold: traits.contains(.bold), italic: traits.contains(.italic),
                                  code: original.isFixedPitch)
            } else {
                font = fonts.regular
            }
            result.addAttribute(.font, value: font, range: range)
        }

        let textNSColor = NSColor(textColor)
        let linkNSColor = NSColor(linkColor)
        result.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            result.addAttribute(.foregroundColor, value: value != nil ? linkNSColor : textNSColor, range: range)
        }

        return result
    }
}

/// Draws a table extracted by `RenderedBodyText.parseTable`.
private struct TableGridView: View {
    let table: RenderedBodyText.ParsedTable

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

/// Fallback when there's no server-rendered HTML: Foundation's Markdown
/// parser with the same styling. No GFM extensions (tables, task lists) —
/// those degrade to plain text.
struct MarkdownText: View {
    let markdown: String
    var fontSize: CGFloat = 12
    var textColor: Color = Palette.textBody
    var linkColor: Color = Palette.accent

    var body: some View {
        RichText(attributedString: Self.cachedParse(markdown, fontSize: fontSize, textColor: textColor, linkColor: linkColor))
    }

    private static func cachedParse(_ raw: String, fontSize: CGFloat, textColor: Color, linkColor: Color) -> NSAttributedString {
        let key = RenderCache.key("md", raw, fontSize, textColor, linkColor)
        if let cached = RenderCache.shared.object(forKey: key) { return cached }
        let parsed = parse(raw, fontSize: fontSize, textColor: textColor, linkColor: linkColor)
        RenderCache.shared.setObject(parsed, forKey: key)
        return parsed
    }

    private static func parse(_ raw: String, fontSize: CGFloat, textColor: Color, linkColor: Color) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)

        let fonts = BodyFonts(size: fontSize)
        let textNSColor = NSColor(textColor)
        let linkNSColor = NSColor(linkColor)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let substring = String(parsed.characters[run.range])
            let intent = run.inlinePresentationIntent ?? []
            let font = fonts.font(bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
                                  code: intent.contains(.code))
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: run.link != nil ? linkNSColor : textNSColor
            ]
            if let url = run.link { attributes[.link] = url }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return result
    }
}

/// The body text faces shared by both rendering paths.
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
