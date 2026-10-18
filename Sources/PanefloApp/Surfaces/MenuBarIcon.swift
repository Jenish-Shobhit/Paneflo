import AppKit
import PanefloCore

/// Paneflo's 18 × 18 pt menu bar glyph (design spec §9.1): three rounded panes, the lower right one at 45 %. Drawn with
/// a drawing handler, so it is crisp at every scale and resolves the menu bar's appearance at each draw. Never animated.
enum MenuBarIcon {
    enum State: Equatable { case normal, setupNeeded, paused }

    static let size = NSSize(width: 18, height: 18)

    static func state(for status: PanefloStatus) -> State {
        switch status {
        case .ready, .starting: .normal
        case .setupNeeded: .setupNeeded
        case .paused: .paused
        }
    }

    static func toolTip(_ state: State) -> String {
        switch state {
        case .normal: "Paneflo"
        case .setupNeeded: "Paneflo — finish setup"
        case .paused: "Paneflo — shortcuts paused"
        }
    }

    static func accessibilityLabel(_ state: State) -> String {
        switch state {
        case .normal: "Paneflo"
        case .setupNeeded: "Paneflo, setup needed"
        case .paused: "Paneflo, shortcuts paused"
        }
    }

    /// Normal and paused are template images (paused keeps 45 % alpha, which template images honor). Setup needed is a
    /// non-template image: the glyph in the menu bar's label color with an orange dot in a cut-out at its top right.
    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            switch state {
            case .normal: drawPanes(color: .black, alpha: 1)
            case .paused: drawPanes(color: .black, alpha: 0.45)
            case .setupNeeded:
                NSGraphicsContext.saveGraphicsState()
                let clip = NSBezierPath(rect: NSRect(origin: .zero, size: size))
                clip.appendOval(in: circle(center: badgeCenter, radius: 3.6))
                clip.windingRule = .evenOdd
                clip.addClip()
                drawPanes(color: .labelColor, alpha: 1)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: circle(center: badgeCenter, radius: 2.5)).fill()
            }
            return true
        }
        image.isTemplate = state != .setupNeeded
        image.accessibilityDescription = accessibilityLabel(state)
        return image
    }

    static let badgeCenter = NSPoint(x: 15, y: 3.4)

    private static func drawPanes(color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setFill()
        pane(NSRect(x: 2, y: 3, width: 6, height: 12)).fill()
        pane(NSRect(x: 9.5, y: 3, width: 6.5, height: 5.25)).fill()
        color.withAlphaComponent(alpha * 0.45).setFill()
        pane(NSRect(x: 9.5, y: 9.75, width: 6.5, height: 5.25)).fill()
    }

    private static func pane(_ rect: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6) }

    private static func circle(center: NSPoint, radius: CGFloat) -> NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// A small colored dot for the menu's status header.
    static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
