import Foundation

/// A cursor position in Accessibility coordinates (global, top-left origin at the primary display), the space
/// `DisplayArea` and `WindowRect` use.
public struct SnapPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }

    func distance(to other: SnapPoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Drag-to-edge snapping thresholds. Defaults follow the familiar macOS window-manager behaviour: a few points from
/// an edge arms the half (top: fill), the first 20 points along an edge from a corner arm that quarter.
public struct SnapAreaSettings: Equatable, Sendable {
    /// How close to an outer display edge the cursor must be, in points.
    public var edgeMargin: Double = 5
    /// How far along an edge from a corner the quarter zone reaches, in points.
    public var cornerSize: Double = 20
    /// Extra distance an armed zone keeps before it changes or disarms, so hovering on a boundary does not flicker.
    public var hysteresis: Double = 6
    /// The zone for the bottom edge (outside its corners). Nil by default: the bottom edge does nothing, so dragging
    /// a window down past the Dock never resizes it by accident. The bottom corners still arm the bottom quarters.
    public var bottomZone: LayoutZone? = nil
    /// Cursor travel from the press before the window's frame is first checked for movement.
    public var dragThreshold: Double = 3
    /// Minimum seconds between two frame checks while deciding whether the window moves: about one display frame.
    /// A check is one window's bounds from the window list (well under a millisecond, off the main thread), and
    /// checks stop as soon as the window is seen moving, so a short interval costs little and arms an edge sooner
    /// when the first check came back before the window followed the cursor.
    public var sampleInterval: Double = 0.016
    /// Frame checks that see the window standing still (while the cursor moves) before the drag is treated as
    /// something else (a text selection, a file drag, a click-and-hold): about half a second of checks.
    public var maxStillSamples = 30
    /// Points a frame may differ by and still count as unchanged.
    public var frameTolerance: Double = 1

    public init() {}
}

/// A zone on one display: `display` indexes the `DisplayArea` list the target was computed from.
public struct SnapTarget: Equatable, Sendable {
    public let zone: LayoutZone
    public let display: Int

    public init(zone: LayoutZone, display: Int) { self.zone = zone; self.display = display }
}

/// Which zone a dragged window's cursor is in. Pure geometry over one consistent coordinate space.
///
/// Only outer edges of the whole display arrangement count: where another display continues past an edge, the
/// cursor simply crosses to it, so that stretch of the edge arms nothing. A partly shared edge still counts where no
/// display continues. The top edge counts from the visible frame's top, so the cursor anywhere in the menu bar still
/// arms it; the other edges are the display's own edges (the cursor can reach them over the Dock).
public enum SnapAreas {
    public static func target(at point: SnapPoint, displays: [DisplayArea], settings: SnapAreaSettings = SnapAreaSettings(),
                              current: SnapTarget? = nil) -> SnapTarget? {
        guard point.x.isFinite, point.y.isFinite, let index = displayIndex(containing: point, in: displays) else { return nil }
        if let current, current.display == index,
           zone(at: point, display: index, displays: displays, margin: settings.edgeMargin + settings.hysteresis,
                corner: settings.cornerSize + settings.hysteresis, bottomZone: settings.bottomZone) == current.zone {
            return current
        }
        return zone(at: point, display: index, displays: displays, margin: settings.edgeMargin,
                    corner: settings.cornerSize, bottomZone: settings.bottomZone)
            .map { SnapTarget(zone: $0, display: index) }
    }

    /// The display under the cursor: half-open containment first (a shared boundary belongs to one display), then
    /// closed containment (the cursor can sit on a display's far edge), then nothing.
    public static func displayIndex(containing point: SnapPoint, in displays: [DisplayArea]) -> Int? {
        if let index = displays.firstIndex(where: { contains($0.frame, point, closed: false) }) { return index }
        return displays.firstIndex { contains($0.frame, point, closed: true) }
    }

    /// True when `frame` covers a whole display (menu bar included): a native full-screen window.
    public static func isFullScreen(_ frame: WindowRect, displays: [DisplayArea], tolerance: Double = 1) -> Bool {
        displays.contains { frame.isClose(to: $0.frame, tolerance: tolerance) }
    }

    enum Edge { case left, right, top, bottom }

    /// The edge has no display continuing past it at the cursor's position.
    static func isOuter(_ edge: Edge, of frame: WindowRect, at point: SnapPoint, displays: [DisplayArea]) -> Bool {
        let probe: SnapPoint
        switch edge {
        case .left: probe = SnapPoint(x: frame.x - 1, y: point.y)
        case .right: probe = SnapPoint(x: frame.maxX + 1, y: point.y)
        case .top: probe = SnapPoint(x: point.x, y: frame.y - 1)
        case .bottom: probe = SnapPoint(x: point.x, y: frame.maxY + 1)
        }
        return !displays.contains { contains($0.frame, probe, closed: false) }
    }

    private static func zone(at point: SnapPoint, display index: Int, displays: [DisplayArea], margin: Double,
                             corner: Double, bottomZone: LayoutZone?) -> LayoutZone? {
        let frame = displays[index].frame
        let visible = displays[index].visibleFrame
        // The menu bar sits above the visible frame: the cursor anywhere in it still counts as the top edge.
        let topLine = visible.isValid ? min(max(frame.y, visible.y), frame.maxY) : frame.y
        func outer(_ edge: Edge) -> Bool { isOuter(edge, of: frame, at: point, displays: displays) }
        let left = point.x - frame.x < margin && outer(.left)
        let right = frame.maxX - point.x < margin && outer(.right)
        let top = point.y - topLine < margin && outer(.top)
        let bottom = frame.maxY - point.y < margin && outer(.bottom)
        let nearLeft = point.x - frame.x < corner
        let nearRight = frame.maxX - point.x < corner
        let nearTop = point.y - topLine < corner
        let nearBottom = frame.maxY - point.y < corner
        if left {
            if nearTop { return .topLeftQuarter }
            if nearBottom { return .bottomLeftQuarter }
            return .leftHalf
        }
        if right {
            if nearTop { return .topRightQuarter }
            if nearBottom { return .bottomRightQuarter }
            return .rightHalf
        }
        if top {
            if nearLeft { return .topLeftQuarter }
            if nearRight { return .topRightQuarter }
            return .maximize
        }
        if bottom {
            if nearLeft { return .bottomLeftQuarter }
            if nearRight { return .bottomRightQuarter }
            return bottomZone
        }
        return nil
    }

    private static func contains(_ rect: WindowRect, _ point: SnapPoint, closed: Bool) -> Bool {
        closed ? point.x >= rect.x && point.x <= rect.maxX && point.y >= rect.y && point.y <= rect.maxY
            : point.x >= rect.x && point.x < rect.maxX && point.y >= rect.y && point.y < rect.maxY
    }
}

/// macOS's own drag-to-edge tiling (System Settings › Desktop & Dock › Windows). While it is on, one drag would be
/// tiled twice, so Settings › Tiling says how to turn it off. Read only; Paneflo never changes system settings.
public enum SystemEdgeTiling {
    public static let domain = "com.apple.WindowManager"
    /// "Drag windows to screen edges to tile".
    public static let edgeKey = "EnableTilingByEdgeDrag"
    /// "Drag windows to menu bar to fill screen".
    public static let topKey = "EnableTopTilingByEdgeDrag"
    /// System Settings › Desktop & Dock.
    public static let settingsURL = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"

    /// True when either system option is on. An unset key is the system default, on.
    public static func isEnabled(_ defaults: UserDefaults?) -> Bool {
        guard let defaults else { return false }
        let edge = defaults.object(forKey: edgeKey) as? Bool ?? true
        let top = defaults.object(forKey: topKey) as? Bool ?? true
        return edge || top
    }
}

/// The window under the cursor when the button went down: its window-server number and frame then.
public struct DragWindow: Equatable, Sendable {
    public let number: UInt32
    public let frame: WindowRect

    public init(number: UInt32, frame: WindowRect) { self.number = number; self.frame = frame }
}

/// Frames Paneflo tiled windows into, and each window's frame from before its first tile, so a tiled window dragged
/// away gets its own size back. Keyed by window-server number; bounded.
public struct SnapRestoreBook: Sendable {
    public static let capacity = 64

    struct Entry: Equatable, Sendable {
        var snapped: WindowRect
        var original: WindowRect
    }

    private var entries: [UInt32: Entry] = [:]
    private var order: [UInt32] = []
    public var count: Int { entries.count }

    public init() {}

    /// A tile landed. A window tiled again from a tiled frame keeps its original frame from before the first tile.
    public mutating func noteTiled(_ number: UInt32, before: WindowRect, after: WindowRect, tolerance: Double = 2) {
        guard before.isValid, after.isValid else { return }
        var original = before
        if let existing = entries[number], before.isClose(to: existing.snapped, tolerance: tolerance) { original = existing.original }
        if original.isClose(to: after, tolerance: tolerance) { forget(number); return }
        entries[number] = Entry(snapped: after, original: original)
        order.removeAll { $0 == number }
        order.append(number)
        if order.count > Self.capacity { entries.removeValue(forKey: order.removeFirst()) }
    }

    /// The frame from before the tile, when the window still has its tiled frame. The entry is consumed either way:
    /// a window moved or resized since its tile is the user's own arrangement.
    public mutating func takeOriginal(for number: UInt32, current: WindowRect, tolerance: Double = 2) -> WindowRect? {
        guard let entry = entries[number] else { return nil }
        forget(number)
        return current.isClose(to: entry.snapped, tolerance: tolerance) ? entry.original : nil
    }

    public mutating func forget(_ number: UInt32) {
        guard entries.removeValue(forKey: number) != nil else { return }
        order.removeAll { $0 == number }
    }

    /// Where a tiled window goes when it is dragged out: its original size, under the cursor at the same relative
    /// horizontal position it was grabbed at and the same distance below the window's top.
    public static func restoreFrame(original: WindowSize, grabbed: WindowRect, press: SnapPoint, cursor: SnapPoint) -> WindowRect {
        let fraction = grabbed.width > 0 ? min(max((press.x - grabbed.x) / grabbed.width, 0), 1) : 0.5
        let offset = min(max(press.y - grabbed.y, 0), original.height)
        return WindowRect(x: cursor.x - fraction * original.width, y: cursor.y - offset,
                          width: original.width, height: original.height)
    }
}

/// The drag-to-edge state machine. It sees only the left button's press, drags and release (from a listen-only
/// mouse monitor), the window resolved under the press, and occasional frame samples of that window. It asks for
/// work through `Effect`s, so the caller decides which queue does it; nothing here touches the system.
///
/// idle → pressed (waiting for the window under the cursor) → pending (window known, waiting to see it move) →
/// moving (its origin moved and its size did not) ⇄ armed(target) → released (back to idle; armed snaps). A resize
/// (size changed), a window that stays still while the cursor moves (selection, file drag), no window, a full-screen
/// window or a cancel make the rest of the drag `ignored`.
public struct SnapDragTracker: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case pressed
        case pending(DragWindow)
        case moving(DragWindow)
        case armed(DragWindow, SnapTarget)
        case ignored
    }

    public enum Effect: Equatable, Sendable {
        /// Find the window under `point` (off the input path) and report it with `windowResolved`.
        case resolveWindow(at: SnapPoint, press: UInt64)
        /// Read the window's current frame (off the input path) and report it with `frameSampled`.
        case sampleFrame(window: UInt32, press: UInt64)
        /// The window was tiled by Paneflo and is being dragged away: give it this frame (its own size back).
        case restore(window: UInt32, frame: WindowRect)
        case showPreview(SnapTarget)
        case hidePreview
        /// The button went up over a zone: tile the window there.
        case snap(window: UInt32, target: SnapTarget)
    }

    public let settings: SnapAreaSettings
    public private(set) var phase: Phase = .idle
    public private(set) var press: UInt64 = 0
    public var book = SnapRestoreBook()
    private var displays: [DisplayArea] = []
    private var pressPoint = SnapPoint(x: 0, y: 0)
    private var lastPoint = SnapPoint(x: 0, y: 0)
    private var lastSample: Double = -.infinity
    private var sampleOutstanding = false
    private var stillSamples = 0

    public init(settings: SnapAreaSettings = SnapAreaSettings()) { self.settings = settings }

    /// The armed target, if any (the preview is visible exactly while this is set).
    public var armedTarget: SnapTarget? {
        if case let .armed(_, target) = phase { return target }
        return nil
    }

    public mutating func mouseDown(at point: SnapPoint, displays: [DisplayArea]) -> [Effect] {
        let hide: [Effect] = armedTarget == nil ? [] : [.hidePreview]
        press &+= 1
        self.displays = displays
        pressPoint = point
        lastPoint = point
        lastSample = -.infinity
        sampleOutstanding = false
        stillSamples = 0
        guard !displays.isEmpty else { phase = .ignored; return hide }
        phase = .pressed
        return hide + [.resolveWindow(at: point, press: press)]
    }

    /// The window under the press, or nil (none, Paneflo's own, not a standard window).
    public mutating func windowResolved(_ window: DragWindow?, press: UInt64, now: Double) -> [Effect] {
        guard press == self.press, phase == .pressed else { return [] }
        guard let window, window.frame.isValid, !SnapAreas.isFullScreen(window.frame, displays: displays) else {
            phase = .ignored; return []
        }
        phase = .pending(window)
        return sampleIfDue(window, now: now)
    }

    public mutating func mouseDragged(to point: SnapPoint, now: Double) -> [Effect] {
        switch phase {
        case .idle, .ignored:
            return []
        case .pressed:
            lastPoint = point
            return []
        case let .pending(window):
            lastPoint = point
            return sampleIfDue(window, now: now)
        case let .moving(window):
            lastPoint = point
            return evaluate(window, current: nil)
        case let .armed(window, target):
            lastPoint = point
            return evaluate(window, current: target)
        }
    }

    /// A frame read for the pending window; nil when it could not be read (the window is gone).
    public mutating func frameSampled(_ frame: WindowRect?, press: UInt64, now: Double) -> [Effect] {
        guard press == self.press, case let .pending(window) = phase else { return [] }
        sampleOutstanding = false
        guard let frame, frame.isValid else { phase = .ignored; return [] }
        let tolerance = settings.frameTolerance
        let start = window.frame
        if abs(frame.width - start.width) > tolerance || abs(frame.height - start.height) > tolerance {
            phase = .ignored // a resize, from any edge or corner
            return []
        }
        guard abs(frame.x - start.x) > tolerance || abs(frame.y - start.y) > tolerance else {
            stillSamples += 1
            if stillSamples >= settings.maxStillSamples { phase = .ignored; return [] }
            return sampleIfDue(window, now: now)
        }
        phase = .moving(window)
        var effects: [Effect] = []
        if let original = book.takeOriginal(for: window.number, current: start) {
            effects.append(.restore(window: window.number,
                                    frame: SnapRestoreBook.restoreFrame(original: original.size, grabbed: start,
                                                                        press: pressPoint, cursor: lastPoint)))
        }
        return effects + evaluate(window, current: nil)
    }

    /// True while the window under the press is known but not yet seen moving. The caller then calls `tick` at
    /// `nextSampleAt`, so the decision does not wait for a drag event that may never come.
    public var awaitsMovement: Bool {
        if case .pending = phase { return true }
        return false
    }

    /// When the caller should next call `tick` (same clock as `now`), or nil while no check is due without a new
    /// event: the window is not pending, a check is outstanding, or the cursor has not travelled far enough. The caller
    /// schedules one timer for this moment, so a check never waits for a timer running on another phase.
    public var nextSampleAt: Double? {
        guard case .pending = phase, !sampleOutstanding, pressPoint.distance(to: lastPoint) >= settings.dragThreshold
        else { return nil }
        return lastSample + settings.sampleInterval
    }

    /// Time passing while the button is down. A flick can park the pointer at an edge before the window was seen to
    /// follow it; with no further drag events the window is sampled from here.
    public mutating func tick(now: Double) -> [Effect] {
        guard case let .pending(window) = phase else { return [] }
        return sampleIfDue(window, now: now)
    }

    public mutating func mouseUp() -> [Effect] {
        defer { phase = .idle; sampleOutstanding = false }
        if case let .armed(window, target) = phase { return [.hidePreview, .snap(window: window.number, target: target)] }
        return []
    }

    /// Stops the current drag without snapping (a surface opened, the setting or permission went off, displays
    /// changed). The rest of the drag is ignored.
    public mutating func cancel() -> [Effect] {
        let hide: [Effect] = armedTarget == nil ? [] : [.hidePreview]
        if phase != .idle { phase = .ignored }
        sampleOutstanding = false
        return hide
    }

    private mutating func sampleIfDue(_ window: DragWindow, now: Double) -> [Effect] {
        guard !sampleOutstanding, pressPoint.distance(to: lastPoint) >= settings.dragThreshold,
              now - lastSample >= settings.sampleInterval - 1e-6 else { return [] } // a timer set for `nextSampleAt` is due
        sampleOutstanding = true
        lastSample = now
        return [.sampleFrame(window: window.number, press: press)]
    }

    private mutating func evaluate(_ window: DragWindow, current: SnapTarget?) -> [Effect] {
        let next = SnapAreas.target(at: lastPoint, displays: displays, settings: settings, current: current)
        guard next != current else { return [] }
        if let next {
            phase = .armed(window, next)
            return [.showPreview(next)]
        }
        phase = .moving(window)
        return [.hidePreview]
    }
}
