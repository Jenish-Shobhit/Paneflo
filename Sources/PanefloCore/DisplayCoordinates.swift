import Foundation

/// Accessibility uses a top-left origin at the primary display; AppKit uses bottom-left.
/// A single primary-display height supports secondary displays above, below, or left.
public enum DisplayCoordinates {
    public static func accessibilityFrame(fromAppKit rect: WindowRect, primaryHeight: Double) -> WindowRect {
        WindowRect(x: rect.x, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func appKitFrame(fromAccessibility rect: WindowRect, primaryHeight: Double) -> WindowRect {
        accessibilityFrame(fromAppKit: rect, primaryHeight: primaryHeight)
    }
}
