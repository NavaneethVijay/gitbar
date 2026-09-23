import AppKit
import SwiftUI

extension View {
    /// Mirrors hover into `isHovered` and shows the pointing-hand cursor —
    /// only for controls that actually do something on click.
    func hoverHighlight(_ isHovered: Binding<Bool>, enabled: Bool = true, animated: Bool = true) -> some View {
        onHover { hovering in
            guard enabled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.12)) { isHovered.wrappedValue = hovering }
            } else {
                isHovered.wrappedValue = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
