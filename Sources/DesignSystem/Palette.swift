import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// The popover's colors, built on system semantic colors: label colors stay
/// legible over the popover's Liquid Glass, accents follow the user's system
/// accent, and everything resolves at draw time (no re-render on theme change).
enum Palette {
    // Surfaces
    /// Over the glass so busy wallpaper doesn't wash out text; raise for more solid.
    static let surface        = Color(nsColor: .windowBackgroundColor).opacity(0.72)
    /// Hover/fill/divider tint; always used with `.opacity(_)`.
    static let wash           = Color(nsColor: .labelColor)

    // Text
    static let textPrimary    = Color(nsColor: .labelColor)
    static let textStrong     = Color(nsColor: .labelColor)
    static let textComment    = Color(nsColor: .labelColor)
    static let textBody       = Color(nsColor: .labelColor)
    static let textSecondary  = Color(nsColor: .secondaryLabelColor)
    static let textMeta       = Color(nsColor: .secondaryLabelColor)
    static let textTertiary   = Color(nsColor: .tertiaryLabelColor)
    static let textPlaceholder = Color(nsColor: .placeholderTextColor)
    static let tabIdle        = Color(nsColor: .secondaryLabelColor)
    static let tabHover       = Color(nsColor: .labelColor)

    // Accents & status
    static let accent         = Color(nsColor: .controlAccentColor)
    static let accentHover    = Color(nsColor: .controlAccentColor).opacity(0.8)
    static let accentPurple   = Color(nsColor: .systemPurple)
    static let success        = Color(nsColor: .systemGreen)
    static let danger         = Color(nsColor: .systemRed)
    static let attention      = Color(nsColor: .systemOrange)
    /// Draft/pending/commented chips and labels.
    static let neutral        = Color(nsColor: .secondaryLabelColor)
    /// CI in progress — its own cyan-teal, not the system accent (which can
    /// be any color, and is what links and selection use). Deeper in light
    /// mode for contrast on white, brighter in dark mode.
    static let running        = Color(nsColor: NSColor(name: "gitbar.running") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.80, blue: 0.88, alpha: 1)   // #59CCE0
            : NSColor(srgbRed: 0.02, green: 0.52, blue: 0.62, alpha: 1)   // #05859E
    })
}

/// Text sizes for the PR / issue detail screens. The popover keeps the
/// compact sizes it was designed at; the main window uses Apple's macOS
/// scale (Body 13, Subheadline 11, 10pt floor) — the popover's sizes read
/// small in a wide window. Set with `.environment(\.detailType, …)`.
struct DetailTypeScale: Equatable, Sendable {
    /// Description / issue body.
    var body: CGFloat
    /// Comment and review text, plus their author line.
    var comment: CGFloat
    /// Check and reviewer names, assignees, empty-state lines, "opened this".
    var row: CGFloat
    /// Small actions and status: Details, Running…, Expand All, View diff,
    /// review state, the PR link, branch chips.
    var meta: CGFloat
    /// File paths and diff lines (monospaced).
    var mono: CGFloat
    /// Loading lines, comment times, the #12 link, notes in the diff.
    var small: CGFloat
    /// Label chips — never under the 10pt floor in the window.
    var chip: CGFloat

    static let popover = DetailTypeScale(body: 12, comment: 11.5, row: 11.5, meta: 10.5,
                                         mono: 11, small: 11, chip: 9.5)
    static let window = DetailTypeScale(body: 13, comment: 13, row: 13, meta: 11,
                                        mono: 12, small: 12, chip: 10)
}

extension EnvironmentValues {
    @Entry var detailType: DetailTypeScale = .popover
}

/// An account's color — its repo tiles in the popover and its dot in the
/// Settings sidebar. Picked per account in Settings; until then each account
/// gets the next one in order. No green/orange/red: those mean repo status.
enum AccountColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, purple, pink, teal, indigo, cyan, brown, mint, yellow, gray

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .teal: return Color(nsColor: .systemTeal)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .cyan: return Color(nsColor: .systemCyan)
        case .brown: return Color(nsColor: .systemBrown)
        case .mint: return Color(nsColor: .systemMint)
        case .yellow: return Color(nsColor: .systemYellow)
        case .gray: return Color(nsColor: .systemGray)
        }
    }

    /// The automatic color for the account at `position`.
    static func automatic(position: Int) -> AccountColor {
        allCases[max(position, 0) % allCases.count]
    }
}

/// Whether to skip translucency: the user's "Solid background" setting, or
/// the system's Reduce Transparency. Translucent surfaces make the window
/// server re-blur whatever is behind them on every frame — real GPU work on
/// older Macs.
struct SolidBackgroundReader: DynamicProperty {
    @AppStorage(AppearanceMode.solidBackgroundKey) private var solidSetting = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var isSolid: Bool { solidSetting || reduceTransparency }
}

private struct FloatingCapsule: ViewModifier {
    private var background = SolidBackgroundReader()

    func body(content: Content) -> some View {
        if background.isSolid {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
    }
}

extension View {
    /// A floating capsule (toasts): Liquid Glass on macOS 26, the closest
    /// material before that, and opaque when translucency is off.
    func floatingCapsule() -> some View {
        modifier(FloatingCapsule())
    }
}
