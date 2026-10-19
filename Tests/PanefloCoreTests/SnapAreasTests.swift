import Foundation
import Testing
@testable import PanefloCore

/// Drag-to-edge snapping: zones, multi-display edges, hysteresis, and the drag state machine.
struct SnapAreasTests {
    /// 1440×900 primary with a 24 pt menu bar (Accessibility coordinates).
    static let primary = DisplayArea(frame: WindowRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: WindowRect(x: 0, y: 24, width: 1440, height: 876), backingScale: 2)
    /// 1920×1080 to the right of the primary, tops aligned.
    static let right = DisplayArea(frame: WindowRect(x: 1440, y: 0, width: 1920, height: 1080),
                                   visibleFrame: WindowRect(x: 1440, y: 24, width: 1920, height: 1056), backingScale: 1)
    /// 1920×1080 above the primary.
    static let above = DisplayArea(frame: WindowRect(x: 0, y: -1080, width: 1920, height: 1080),
                                   visibleFrame: WindowRect(x: 0, y: -1056, width: 1920, height: 1056), backingScale: 1)

    func zone(_ x: Double, _ y: Double, _ displays: [DisplayArea] = [primary], settings: SnapAreaSettings = SnapAreaSettings(),
              current: SnapTarget? = nil) -> SnapTarget? {
        SnapAreas.target(at: SnapPoint(x: x, y: y), displays: displays, settings: settings, current: current)
    }

    // MARK: Zones

    @Test
    func edgesArmHalvesAndTopFills() {
        #expect(zone(2, 450) == SnapTarget(zone: .leftHalf, display: 0))
        #expect(zone(0, 450) == SnapTarget(zone: .leftHalf, display: 0))
        #expect(zone(1439, 450) == SnapTarget(zone: .rightHalf, display: 0))
        #expect(zone(1440, 450) == SnapTarget(zone: .rightHalf, display: 0), "the cursor can sit on the far edge")
        #expect(zone(720, 0) == SnapTarget(zone: .maximize, display: 0))
        #expect(zone(720, 450) == nil)
        #expect(zone(6, 450) == nil, "beyond the 5 pt margin")
        #expect(zone(-50, 450) == nil, "off every display")
    }

    @Test
    func theMenuBarCountsAsTheTopEdge() {
        #expect(zone(720, 12) == SnapTarget(zone: .maximize, display: 0))
        #expect(zone(720, 23) == SnapTarget(zone: .maximize, display: 0))
        #expect(zone(720, 28) == SnapTarget(zone: .maximize, display: 0), "within the margin below the menu bar")
        #expect(zone(720, 30) == nil)
        // An auto-hidden menu bar: the visible frame starts at the top.
        let hidden = DisplayArea(frame: Self.primary.frame, visibleFrame: Self.primary.frame, backingScale: 2)
        #expect(zone(720, 3, [hidden]) == SnapTarget(zone: .maximize, display: 0))
        #expect(zone(720, 12, [hidden]) == nil)
    }

    @Test
    func bottomEdgeDoesNothingByDefaultButCanBeChosen() {
        #expect(zone(720, 899) == nil)
        var settings = SnapAreaSettings()
        settings.bottomZone = .bottomHalf
        #expect(zone(720, 899, settings: settings) == SnapTarget(zone: .bottomHalf, display: 0))
    }

    @Test
    func cornersArmQuarters() {
        #expect(zone(2, 30) == SnapTarget(zone: .topLeftQuarter, display: 0), "left edge near the top")
        #expect(zone(10, 2) == SnapTarget(zone: .topLeftQuarter, display: 0), "top edge near the left")
        #expect(zone(2, 885) == SnapTarget(zone: .bottomLeftQuarter, display: 0))
        #expect(zone(15, 898) == SnapTarget(zone: .bottomLeftQuarter, display: 0), "bottom corners work with the bottom edge off")
        #expect(zone(1438, 10) == SnapTarget(zone: .topRightQuarter, display: 0))
        #expect(zone(1425, 899) == SnapTarget(zone: .bottomRightQuarter, display: 0))
        #expect(zone(2, 50) == SnapTarget(zone: .leftHalf, display: 0), "26 pt below the visible top is past the corner")
        #expect(zone(25, 2) == SnapTarget(zone: .maximize, display: 0))
    }

    // MARK: Multi-display

    @Test
    func sharedEdgesBetweenDisplaysNeverArm() {
        let displays = [Self.primary, Self.right]
        #expect(zone(1439, 450, displays) == nil, "primary's right edge continues into the second display")
        #expect(zone(1441, 450, displays) == nil, "the second display's left edge continues into the primary")
        #expect(zone(3358, 450, displays) == SnapTarget(zone: .rightHalf, display: 1))
        #expect(zone(2, 450, displays) == SnapTarget(zone: .leftHalf, display: 0))
        #expect(zone(2000, 1) == nil, "a point on no listed display")
        #expect(zone(2000, 1, displays) == SnapTarget(zone: .maximize, display: 1))
    }

    @Test
    func aPartlySharedEdgeArmsWhereNoDisplayContinues() {
        let displays = [Self.primary, Self.right]
        // The second display is 180 pt taller: below the primary's bottom its left edge is outer.
        #expect(zone(1441, 1000, displays) == SnapTarget(zone: .leftHalf, display: 1))
        #expect(zone(1441, 1075, displays) == SnapTarget(zone: .bottomLeftQuarter, display: 1))
        #expect(zone(1441, 880, displays) == nil)
    }

    @Test
    func aDisplayAboveTakesTheTopEdgeAway() {
        let displays = [Self.primary, Self.above]
        #expect(zone(720, 1, displays) == nil, "the cursor would cross into the display above")
        #expect(zone(720, 12, displays) == nil, "even inside the menu bar")
        #expect(zone(1000, -1079, displays) == SnapTarget(zone: .maximize, display: 1))
        // The upper display is wider: its bottom edge past the primary's right side is outer (bottom corners only).
        #expect(zone(1910, -1, displays) == SnapTarget(zone: .bottomRightQuarter, display: 1))
        #expect(zone(1000, -1, displays) == nil)
        #expect(zone(2, 450, displays) == SnapTarget(zone: .leftHalf, display: 0))
    }

    @Test
    func displayLookupPrefersHalfOpenContainment() {
        let displays = [Self.primary, Self.right]
        #expect(SnapAreas.displayIndex(containing: SnapPoint(x: 1440, y: 10), in: displays) == 1)
        #expect(SnapAreas.displayIndex(containing: SnapPoint(x: 3360, y: 10), in: displays) == 1)
        #expect(SnapAreas.displayIndex(containing: SnapPoint(x: 1439.5, y: 10), in: displays) == 0)
        #expect(SnapAreas.displayIndex(containing: SnapPoint(x: 5000, y: 10), in: displays) == nil)
    }

    // MARK: Hysteresis

    @Test
    func anArmedZoneHoldsAcrossItsBoundary() {
        let left = SnapTarget(zone: .leftHalf, display: 0)
        #expect(zone(8, 450) == nil)
        #expect(zone(8, 450, current: left) == left, "stays armed within margin + hysteresis")
        #expect(zone(12, 450, current: left) == nil)
        let corner = SnapTarget(zone: .topLeftQuarter, display: 0)
        #expect(zone(2, 48) == left)
        #expect(zone(2, 48, current: corner) == corner, "a corner holds 6 pt past its size")
        #expect(zone(2, 52, current: corner) == left)
        #expect(zone(2, 40, current: left) == corner, "entering a corner switches at once")
        let top = SnapTarget(zone: .maximize, display: 0)
        #expect(zone(720, 33, current: top) == top)
        #expect(zone(720, 36, current: top) == nil)
    }

    @Test
    func hysteresisNeverCarriesAZoneToAnotherDisplay() {
        let displays = [Self.primary, Self.right]
        let stale = SnapTarget(zone: .rightHalf, display: 0)
        #expect(zone(1441, 450, displays, current: stale) == nil)
    }

    // MARK: Drag state machine

    static let window = DragWindow(number: 42, frame: WindowRect(x: 300, y: 200, width: 800, height: 500))

    /// Press on the title bar and move until the window is seen moving.
    func startMoving(_ tracker: inout SnapDragTracker, displays: [DisplayArea] = [primary]) -> [SnapDragTracker.Effect] {
        let press = SnapPoint(x: 500, y: 210)
        let down = tracker.mouseDown(at: press, displays: displays)
        let id = tracker.press
        #expect(down == [.resolveWindow(at: press, press: id)])
        #expect(tracker.phase == .pressed)
        let resolved = tracker.windowResolved(Self.window, press: id, now: 0)
        #expect(resolved == [], "nothing to check before the cursor moves")
        let first = tracker.mouseDragged(to: SnapPoint(x: 520, y: 212), now: 0.01)
        #expect(first == [.sampleFrame(window: 42, press: id)])
        let second = tracker.mouseDragged(to: SnapPoint(x: 530, y: 212), now: 0.02)
        #expect(second == [], "one sample at a time")
        return tracker.frameSampled(WindowRect(x: 330, y: 202, width: 800, height: 500), press: id, now: 0.03)
    }

    @Test
    func aMovedWindowArmsAtAnEdgeAndSnapsOnRelease() {
        var tracker = SnapDragTracker()
        #expect(startMoving(&tracker) == [])
        #expect(tracker.phase == .moving(Self.window))
        #expect(tracker.mouseDragged(to: SnapPoint(x: 200, y: 400), now: 0.1) == [])
        let left = SnapTarget(zone: .leftHalf, display: 0)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 1, y: 400), now: 0.2) == [.showPreview(left)])
        #expect(tracker.armedTarget == left)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 0, y: 420), now: 0.3) == [], "no repeat while the zone is unchanged")
        let corner = SnapTarget(zone: .topLeftQuarter, display: 0)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 0, y: 30), now: 0.4) == [.showPreview(corner)])
        #expect(tracker.mouseUp() == [.hidePreview, .snap(window: 42, target: corner)])
        #expect(tracker.phase == .idle)
    }

    @Test
    func movingAwayFromTheEdgeDisarmsAndReleasingElsewhereDoesNothing() {
        var tracker = SnapDragTracker()
        _ = startMoving(&tracker)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 720, y: 2), now: 0.1) == [.showPreview(SnapTarget(zone: .maximize, display: 0))])
        #expect(tracker.mouseDragged(to: SnapPoint(x: 720, y: 300), now: 0.2) == [.hidePreview])
        #expect(tracker.phase == .moving(Self.window))
        #expect(tracker.mouseUp() == [])
    }

    @Test
    func theFirstSampleCanAlreadySeeTheCursorAtAnEdge() {
        var tracker = SnapDragTracker()
        let press = SnapPoint(x: 10, y: 210)
        _ = tracker.mouseDown(at: press, displays: [Self.primary])
        _ = tracker.windowResolved(Self.window, press: tracker.press, now: 0)
        _ = tracker.mouseDragged(to: SnapPoint(x: 2, y: 400), now: 0.01)
        let effects = tracker.frameSampled(WindowRect(x: 292, y: 390, width: 800, height: 500), press: tracker.press, now: 0.02)
        #expect(effects == [.showPreview(SnapTarget(zone: .leftHalf, display: 0))])
    }

    @Test
    func aResizeIsNeverASnap() {
        for resized in [WindowRect(x: 300, y: 200, width: 830, height: 500),   // right edge
                        WindowRect(x: 270, y: 200, width: 830, height: 500),   // left edge: origin and size change
                        WindowRect(x: 300, y: 180, width: 800, height: 520)] { // top edge
            var tracker = SnapDragTracker()
            _ = tracker.mouseDown(at: SnapPoint(x: 300, y: 400), displays: [Self.primary])
            _ = tracker.windowResolved(Self.window, press: tracker.press, now: 0)
            _ = tracker.mouseDragged(to: SnapPoint(x: 280, y: 400), now: 0.01)
            #expect(tracker.frameSampled(resized, press: tracker.press, now: 0.02) == [])
            #expect(tracker.phase == .ignored)
            #expect(tracker.mouseDragged(to: SnapPoint(x: 1, y: 400), now: 0.1) == [], "no preview for the rest of the drag")
            #expect(tracker.mouseUp() == [])
        }
    }

    @Test
    func aWindowThatStaysStillIsASelectionOrAFileDrag() {
        var settings = SnapAreaSettings()
        settings.maxStillSamples = 3
        var tracker = SnapDragTracker(settings: settings)
        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        _ = tracker.windowResolved(Self.window, press: tracker.press, now: 0)
        var now = 0.0
        var samples = 0
        for step in 1...40 where tracker.phase != .ignored {
            now += 0.05
            let effects = tracker.mouseDragged(to: SnapPoint(x: 500 - Double(step) * 12, y: 400), now: now)
            if effects.contains(.sampleFrame(window: 42, press: tracker.press)) {
                samples += 1
                _ = tracker.frameSampled(Self.window.frame, press: tracker.press, now: now)
            }
        }
        #expect(samples == 3)
        #expect(tracker.phase == .ignored)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 0, y: 400), now: now + 1) == [])
    }

    @Test
    func samplesAreThrottledAndNeedRealCursorTravel() {
        var tracker = SnapDragTracker()
        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        _ = tracker.windowResolved(Self.window, press: tracker.press, now: 0)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 501, y: 401), now: 0.01) == [], "below the drag threshold")
        #expect(tracker.mouseDragged(to: SnapPoint(x: 510, y: 400), now: 0.02) == [.sampleFrame(window: 42, press: tracker.press)])
        _ = tracker.frameSampled(Self.window.frame, press: tracker.press, now: 0.025)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 520, y: 400), now: 0.03) == [], "within the sample interval")
        #expect(tracker.mouseDragged(to: SnapPoint(x: 530, y: 400), now: 0.07) == [.sampleFrame(window: 42, press: tracker.press)])
    }

    @Test
    func staleResultsFromAnEarlierPressAreIgnored() {
        var tracker = SnapDragTracker()
        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        let old = tracker.press
        _ = tracker.mouseUp()
        _ = tracker.mouseDown(at: SnapPoint(x: 600, y: 400), displays: [Self.primary])
        #expect(tracker.windowResolved(Self.window, press: old, now: 0) == [])
        #expect(tracker.phase == .pressed)
        _ = tracker.windowResolved(Self.window, press: tracker.press, now: 0)
        _ = tracker.mouseDragged(to: SnapPoint(x: 620, y: 400), now: 0.01)
        #expect(tracker.frameSampled(WindowRect(x: 320, y: 200, width: 800, height: 500), press: old, now: 0.02) == [])
        #expect(tracker.phase == .pending(Self.window))
    }

    @Test
    func noWindowFullScreenOrAGoneWindowIgnoresTheDrag() {
        var tracker = SnapDragTracker()
        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        #expect(tracker.windowResolved(nil, press: tracker.press, now: 0) == [])
        #expect(tracker.phase == .ignored)

        let fullScreen = DragWindow(number: 7, frame: Self.primary.frame)
        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        _ = tracker.windowResolved(fullScreen, press: tracker.press, now: 0)
        #expect(tracker.phase == .ignored)

        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        _ = tracker.windowResolved(Self.window, press: tracker.press, now: 0)
        _ = tracker.mouseDragged(to: SnapPoint(x: 520, y: 400), now: 0.01)
        #expect(tracker.frameSampled(nil, press: tracker.press, now: 0.02) == [])
        #expect(tracker.phase == .ignored)

        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [])
        #expect(tracker.phase == .ignored, "no displays")
    }

    @Test
    func dragsWithoutAPressAndReleasesWhilePendingDoNothing() {
        var tracker = SnapDragTracker()
        #expect(tracker.mouseDragged(to: SnapPoint(x: 1, y: 400), now: 0) == [])
        #expect(tracker.mouseUp() == [])
        _ = tracker.mouseDown(at: SnapPoint(x: 500, y: 400), displays: [Self.primary])
        #expect(tracker.mouseDragged(to: SnapPoint(x: 1, y: 400), now: 0.01) == [], "window not resolved yet")
        #expect(tracker.mouseUp() == [])
        #expect(tracker.phase == .idle)
    }

    @Test
    func cancelHidesThePreviewAndIgnoresTheRestOfTheDrag() {
        var tracker = SnapDragTracker()
        _ = startMoving(&tracker)
        _ = tracker.mouseDragged(to: SnapPoint(x: 1, y: 400), now: 0.1)
        #expect(tracker.cancel() == [.hidePreview])
        #expect(tracker.phase == .ignored)
        #expect(tracker.mouseDragged(to: SnapPoint(x: 0, y: 400), now: 0.2) == [])
        #expect(tracker.mouseUp() == [])
        #expect(tracker.cancel() == [])
        #expect(tracker.phase == .idle, "a cancel with no drag leaves the tracker idle")
    }

    @Test
    func aNewPressWhileArmedHidesTheOldPreview() {
        var tracker = SnapDragTracker()
        _ = startMoving(&tracker)
        _ = tracker.mouseDragged(to: SnapPoint(x: 1, y: 400), now: 0.1)
        let press = SnapPoint(x: 600, y: 300)
        #expect(tracker.mouseDown(at: press, displays: [Self.primary]) == [.hidePreview, .resolveWindow(at: press, press: tracker.press)])
    }

    @Test
    func abuttingEdgesNeverArmDuringADrag() {
        var tracker = SnapDragTracker()
        _ = startMoving(&tracker, displays: [Self.primary, Self.right])
        #expect(tracker.mouseDragged(to: SnapPoint(x: 1439, y: 400), now: 0.1) == [])
        #expect(tracker.mouseDragged(to: SnapPoint(x: 1441, y: 400), now: 0.2) == [])
        #expect(tracker.mouseDragged(to: SnapPoint(x: 3359, y: 400), now: 0.3) == [.showPreview(SnapTarget(zone: .rightHalf, display: 1))])
    }

    // MARK: Restore on drag-out

    static let snapped = WindowRect(x: 4, y: 28, width: 712, height: 864)

    @Test
    func aTiledWindowDraggedAwayGetsItsSizeBack() throws {
        var tracker = SnapDragTracker()
        tracker.book.noteTiled(42, before: WindowRect(x: 300, y: 200, width: 800, height: 500), after: Self.snapped)
        let tiled = DragWindow(number: 42, frame: Self.snapped)
        let press = SnapPoint(x: 360, y: 40) // half-way across the title bar, 12 pt below the top
        _ = tracker.mouseDown(at: press, displays: [Self.primary])
        _ = tracker.windowResolved(tiled, press: tracker.press, now: 0)
        _ = tracker.mouseDragged(to: SnapPoint(x: 400, y: 60), now: 0.01)
        let effects = tracker.frameSampled(WindowRect(x: 44, y: 48, width: 712, height: 864), press: tracker.press, now: 0.02)
        let restore = try #require(effects.first)
        guard case let .restore(number, frame) = restore else { Issue.record("expected a restore, got \(effects)"); return }
        #expect(number == 42)
        #expect(frame.width == 800 && frame.height == 500)
        #expect(frame.x == 400 - 0.5 * 800, "the cursor keeps its relative place across the title bar")
        #expect(frame.y == 60 - 12, "and its distance below the top")
        #expect(tracker.book.count == 0, "restored once")
    }

    @Test
    func aWindowMovedOrResizedSinceItsTileIsNotRestored() {
        var tracker = SnapDragTracker()
        tracker.book.noteTiled(42, before: WindowRect(x: 300, y: 200, width: 800, height: 500), after: Self.snapped)
        let resized = DragWindow(number: 42, frame: WindowRect(x: 4, y: 28, width: 600, height: 864))
        _ = tracker.mouseDown(at: SnapPoint(x: 300, y: 40), displays: [Self.primary])
        _ = tracker.windowResolved(resized, press: tracker.press, now: 0)
        _ = tracker.mouseDragged(to: SnapPoint(x: 340, y: 60), now: 0.01)
        #expect(tracker.frameSampled(WindowRect(x: 44, y: 48, width: 600, height: 864), press: tracker.press, now: 0.02) == [])
        #expect(tracker.book.count == 0, "the stale entry is dropped")
    }

    @Test
    func aResizeOfATiledWindowKeepsItsRestoreFrame() {
        var tracker = SnapDragTracker()
        tracker.book.noteTiled(42, before: WindowRect(x: 300, y: 200, width: 800, height: 500), after: Self.snapped)
        _ = tracker.mouseDown(at: SnapPoint(x: 716, y: 400), displays: [Self.primary])
        _ = tracker.windowResolved(DragWindow(number: 42, frame: Self.snapped), press: tracker.press, now: 0)
        _ = tracker.mouseDragged(to: SnapPoint(x: 700, y: 400), now: 0.01)
        #expect(tracker.frameSampled(WindowRect(x: 4, y: 28, width: 696, height: 864), press: tracker.press, now: 0.02) == [])
        #expect(tracker.book.count == 1, "only a move consumes it")
    }

    @Test
    func retilingATiledWindowKeepsItsOriginalFrame() {
        var book = SnapRestoreBook()
        let original = WindowRect(x: 300, y: 200, width: 800, height: 500)
        book.noteTiled(1, before: original, after: Self.snapped)
        let rightHalf = WindowRect(x: 724, y: 28, width: 712, height: 864)
        book.noteTiled(1, before: Self.snapped, after: rightHalf)
        #expect(book.takeOriginal(for: 1, current: Self.snapped) == nil, "the window is no longer at its first tile")
        book.noteTiled(1, before: original, after: Self.snapped)
        book.noteTiled(1, before: Self.snapped, after: rightHalf)
        #expect(book.takeOriginal(for: 1, current: rightHalf) == original)
        #expect(book.takeOriginal(for: 1, current: rightHalf) == nil, "consumed")
        book.noteTiled(2, before: original, after: original)
        #expect(book.count == 0, "a tile that changed nothing has nothing to restore")
    }

    @Test
    func theRestoreBookIsBounded() {
        var book = SnapRestoreBook()
        for number in 0..<UInt32(SnapRestoreBook.capacity + 10) {
            book.noteTiled(number, before: WindowRect(x: 0, y: 0, width: 400, height: 300), after: Self.snapped)
        }
        #expect(book.count == SnapRestoreBook.capacity)
        #expect(book.takeOriginal(for: 0, current: Self.snapped) == nil, "the oldest entries go first")
        #expect(book.takeOriginal(for: UInt32(SnapRestoreBook.capacity + 9), current: Self.snapped) != nil)
    }

    @Test
    func restoreFrameClampsTheGrabPoint() {
        let original = WindowSize(width: 400, height: 300)
        let grabbed = WindowRect(x: 0, y: 0, width: 800, height: 600)
        let outside = SnapRestoreBook.restoreFrame(original: original, grabbed: grabbed, press: SnapPoint(x: -20, y: 500),
                                                   cursor: SnapPoint(x: 100, y: 500))
        #expect(outside.x == 100 && outside.y == 200, "x fraction clamps to 0, the top offset to the restored height")
    }

    // MARK: Settings

    @Test
    func dragToSnapDefaultsOnAndPersists() throws {
        let suite = "SnapAreasTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SurfacePreferences(defaults: defaults).dragToSnap)
        SurfacePreferences.write(.dragToSnap, false, to: defaults)
        #expect(!SurfacePreferences(defaults: defaults).dragToSnap)
        #expect(defaults.object(forKey: SurfacePreferences.Key.dragToSnap) as? Bool == false)
    }

    @Test
    func systemEdgeTilingIsOnUnlessBothOptionsAreOff() throws {
        let suite = "SnapAreasTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SystemEdgeTiling.isEnabled(defaults), "unset keys are the system default, on")
        defaults.set(false, forKey: SystemEdgeTiling.edgeKey)
        #expect(SystemEdgeTiling.isEnabled(defaults), "dragging to the menu bar still fills")
        defaults.set(false, forKey: SystemEdgeTiling.topKey)
        #expect(!SystemEdgeTiling.isEnabled(defaults))
        #expect(!SystemEdgeTiling.isEnabled(nil))
    }
}
