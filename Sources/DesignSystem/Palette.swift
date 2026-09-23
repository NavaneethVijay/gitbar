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

extension View {
    /// A floating capsule (toasts): real Liquid Glass on macOS 26, the
    /// closest system material on earlier releases.
    @ViewBuilder
    func floatingCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
    }
}
