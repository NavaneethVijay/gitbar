import AppKit
import SwiftUI

/// One line of chips that never wraps or squeezes: chips are laid out in
/// order and the first one that doesn't fit — and everything after it — is
/// left out. For label rows and the repo summary strip, where a fixed row
/// height matters more than showing every chip.
struct FirstFitRow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let end = width + (index == 0 ? 0 : spacing) + size.width
            if end > maxWidth { break }
            width = end
            height = max(height, size.height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var fits = true
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let start = x + (index == 0 ? 0 : spacing)
            if fits, start + size.width <= bounds.maxX + 0.5 {
                subview.place(at: CGPoint(x: start, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x = start + size.width
            } else {
                // Every subview must be placed; the overflow goes far off-screen.
                fits = false
                subview.place(at: CGPoint(x: -10_000, y: -10_000), proposal: ProposedViewSize(size))
            }
        }
    }
}

/// A PR/issue label in the provider's own color — tinted fill and border,
/// with primary-color text so any label color stays readable in both
/// appearances.
struct LabelChip: View {
    let label: PRLabel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.detailType) private var type

    /// The label's color nudged toward legibility: providers allow any
    /// color, so a near-black label vanishes on a dark background and a
    /// pale one on a light background. Dark colors are lightened in dark
    /// mode, light ones darkened in light mode — like GitHub's own chips.
    private var tint: Color {
        let base = NSColor(label.color).usingColorSpace(.sRGB) ?? .gray
        let luminance = 0.2126 * base.redComponent + 0.7152 * base.greenComponent + 0.0722 * base.blueComponent
        if colorScheme == .dark, luminance < 0.45 {
            return Color(nsColor: base.blended(withFraction: 0.45 - luminance + 0.2, of: .white) ?? base)
        }
        if colorScheme == .light, luminance > 0.6 {
            return Color(nsColor: base.blended(withFraction: luminance - 0.6 + 0.25, of: .black) ?? base)
        }
        return label.color
    }

    var body: some View {
        let tint = tint
        Text(label.name)
            .font(.system(size: type.chip, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(colorScheme == .dark ? 0.28 : 0.2)))
            .overlay(Capsule().strokeBorder(tint.opacity(colorScheme == .dark ? 0.75 : 0.65)))
    }
}

/// A row's labels, as many as fit on one line; the full list is the tooltip.
struct LabelRow: View {
    let labels: [PRLabel]

    var body: some View {
        FirstFitRow(spacing: 4) {
            ForEach(labels) { LabelChip(label: $0) }
        }
        .help(labels.map(\.name).joined(separator: ", "))
    }
}
