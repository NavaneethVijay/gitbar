import SwiftUI

extension View {
    /// Mirrors hover into `isHovered` and shows the pointing-hand cursor —
    /// only for controls that actually do something on click. The cursor is
    /// SwiftUI's `pointerStyle`, not `NSCursor.push/pop`: a manual push leaks
    /// when a hovered row disappears (e.g. navigating away) before its pop.
    func hoverHighlight(_ isHovered: Binding<Bool>, enabled: Bool = true, animated: Bool = true) -> some View {
        onHover { hovering in
            guard enabled || !hovering else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.12)) { isHovered.wrappedValue = hovering }
            } else {
                isHovered.wrappedValue = hovering
            }
        }
        .pointerStyle(enabled ? .link : nil)
    }
}
