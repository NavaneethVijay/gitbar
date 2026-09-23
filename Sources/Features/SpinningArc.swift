// Adapted from codenotch (MIT) — https://github.com/vinzdg/codenotch
import AppKit
import SwiftUI

/// A spinning arc driven by Core Animation: a SwiftUI `repeatForever`
/// rotation would re-run layout every frame; a `CABasicAnimation` runs in the
/// render server instead.
struct SpinningArc: NSViewRepresentable {
    let color: Color
    let arcFraction: CGFloat

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView() }

    func updateNSView(_ view: SpinningArcView, context: Context) {
        view.configure(color: NSColor(color), arcFraction: arcFraction)
    }
}

final class SpinningArcView: NSView {
    static let turnDuration: CFTimeInterval = 1.1
    static let animationKey = "turn"

    let arc = CAShapeLayer()
    private var color: NSColor = .white

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = 2
        arc.strokeStart = 0
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decoration only: clicks go to the row beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, arcFraction: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.color = color
        arc.strokeEnd = arcFraction
        applyColor()
        rebuildPath()
        CATransaction.commit()
        updateAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildPath()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = color.cgColor
        }
    }

    private func rebuildPath() {
        arc.frame = bounds
        let radius = max(0, min(bounds.width, bounds.height) / 2)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                    startAngle: 0, endAngle: -2 * .pi, clockwise: true)
        arc.path = path
    }

    /// Re-added whenever it has gone missing: AppKit drops layer animations
    /// when a window leaves the screen, which the popover's does on close.
    private func updateAnimation() {
        guard window != nil else {
            arc.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard arc.animation(forKey: Self.animationKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = Self.turnDuration
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: Self.animationKey)
    }
}
