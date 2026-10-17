import Foundation

/// One display as the placement code sees it, in Accessibility coordinates (global, top-left
/// origin at the primary display). `visibleFrame` already excludes the menu bar, notch safe
/// area, and a visible Dock; whatever the system reports for that display is used unmodified.
public struct DisplayArea: Equatable, Sendable {
    public var frame: WindowRect
    public var visibleFrame: WindowRect
    public var backingScale: Double

    public init(frame: WindowRect, visibleFrame: WindowRect, backingScale: Double) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.backingScale = backingScale
    }

    /// Converts AppKit (bottom-left origin) screen rectangles. `primaryHeight` is the height of
    /// the screen at index 0 of `NSScreen.screens`, which owns the global origin.
    public init(appKitFrame: WindowRect, appKitVisibleFrame: WindowRect, backingScale: Double, primaryHeight: Double) {
        self.init(frame: DisplayCoordinates.accessibilityFrame(fromAppKit: appKitFrame, primaryHeight: primaryHeight),
                  visibleFrame: DisplayCoordinates.accessibilityFrame(fromAppKit: appKitVisibleFrame, primaryHeight: primaryHeight),
                  backingScale: backingScale)
    }
}

public extension WindowRect {
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }

    func intersectionArea(_ other: WindowRect) -> Double {
        max(0, min(maxX, other.maxX) - max(x, other.x)) * max(0, min(maxY, other.maxY) - max(y, other.y))
    }

    /// Distance from a point to this rectangle (zero inside).
    func distance(toX px: Double, y py: Double) -> Double {
        let dx = max(x - px, 0, px - maxX)
        let dy = max(y - py, 0, py - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    func isClose(to other: WindowRect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

public struct TilePlan: Equatable, Sendable {
    public let displayIndex: Int
    public let rect: WindowRect
    /// True when a repeated half-screen request moved to the neighbouring display.
    public let cycled: Bool
}

public enum DisplayPlacement {
    /// The display the window belongs to: largest overlap with the display frame, otherwise the
    /// nearest display to the window center (a window dragged mostly off-screen still has a home).
    public static func displayIndex(for window: WindowRect, in displays: [DisplayArea]) -> Int? {
        guard window.isValid, !displays.isEmpty else { return displays.isEmpty ? nil : 0 }
        var best: (index: Int, area: Double)?
        for (index, display) in displays.enumerated() {
            let area = display.frame.intersectionArea(window)
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        if let best { return best.index }
        return displays.indices.min { lhs, rhs in
            displays[lhs].frame.distance(toX: window.centerX, y: window.centerY)
                < displays[rhs].frame.distance(toX: window.centerX, y: window.centerY)
        }
    }

    /// The nearest display strictly to the left (`-1`) or right (`+1`), preferring vertical overlap.
    public static func neighbourIndex(of index: Int, direction: Int, in displays: [DisplayArea]) -> Int? {
        guard displays.indices.contains(index), direction != 0 else { return nil }
        let current = displays[index].frame
        let candidates = displays.indices.filter { other in
            guard other != index else { return false }
            let frame = displays[other].frame
            return direction < 0 ? frame.centerX < current.centerX : frame.centerX > current.centerX
        }
        return candidates.min { lhs, rhs in
            func key(_ i: Int) -> (Double, Double) {
                let frame = displays[i].frame
                let gap = direction < 0 ? max(0, current.x - frame.maxX) : max(0, frame.x - current.maxX)
                let overlap = max(0, min(frame.maxY, current.maxY) - max(frame.y, current.y))
                return (gap, -overlap)
            }
            return key(lhs) < key(rhs)
        }
    }

    /// Chooses the display and rectangle for a tile request from the window's fresh frame.
    /// `explicitDisplay` (the Settings picker) overrides the window's own display and never cycles.
    public static func planTile(zone: LayoutZone, window: WindowRect, displays: [DisplayArea],
                                explicitDisplay: Int? = nil, gap: Double = 8,
                                cycleDisplays: Bool = true) -> TilePlan? {
        guard !displays.isEmpty else { return nil }
        func plan(on index: Int) -> WindowRect? {
            let display = displays[index]
            return LayoutEngine.plan(zone: zone, in: display.visibleFrame, gap: gap,
                                     backingScale: display.backingScale, currentSize: window.size).rect
        }
        if let explicitDisplay, displays.indices.contains(explicitDisplay) {
            return plan(on: explicitDisplay).map { TilePlan(displayIndex: explicitDisplay, rect: $0, cycled: false) }
        }
        guard let home = displayIndex(for: window, in: displays), let rect = plan(on: home) else { return nil }
        if cycleDisplays, zone == .leftHalf || zone == .rightHalf, window.isClose(to: rect),
           let next = neighbourIndex(of: home, direction: zone == .leftHalf ? -1 : 1, in: displays),
           let moved = plan(on: next) {
            return TilePlan(displayIndex: next, rect: moved, cycled: true)
        }
        return TilePlan(displayIndex: home, rect: rect, cycled: false)
    }

    /// Final frame once the application has reported the size it accepted. An axis the app
    /// shrank below the zone is centered in the zone; an axis it grew beyond the zone keeps the
    /// requested origin, shifted only as far as needed to stay inside `bounds`.
    public static func settledFrame(requested: WindowRect, accepted: WindowSize, within bounds: WindowRect) -> WindowRect {
        guard accepted.width > 0, accepted.height > 0 else { return requested }
        func axis(origin: Double, length: Double, accepted: Double, boundsOrigin: Double, boundsLength: Double) -> Double {
            if accepted <= length { return origin + (length - accepted) / 2 }
            let overflow = origin + accepted - (boundsOrigin + boundsLength)
            let shifted = overflow > 0 ? origin - overflow : origin
            return max(boundsOrigin, shifted)
        }
        return WindowRect(
            x: axis(origin: requested.x, length: requested.width, accepted: accepted.width,
                    boundsOrigin: bounds.x, boundsLength: bounds.width),
            y: axis(origin: requested.y, length: requested.height, accepted: accepted.height,
                    boundsOrigin: bounds.y, boundsLength: bounds.height),
            width: accepted.width, height: accepted.height)
    }

    /// Where an undo should put a window. The recorded frame is restored exactly while it is
    /// still on the current displays; otherwise it is clamped into the nearest display's usable area.
    public static func restoredFrame(_ before: WindowRect, displays: [DisplayArea]) -> WindowRect? {
        guard before.isValid, !displays.isEmpty else { return nil }
        let area = before.width * before.height
        let onScreen = displays.reduce(0.0) { $0 + $1.frame.intersectionArea(before) }
        if onScreen >= area * 0.95 { return before }
        guard let index = displayIndex(for: before, in: displays) else { return nil }
        let display = displays[index]
        return LayoutEngine.recover(before, in: display.visibleFrame, backingScale: display.backingScale).rect
    }
}
