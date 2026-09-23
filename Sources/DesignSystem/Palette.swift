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
