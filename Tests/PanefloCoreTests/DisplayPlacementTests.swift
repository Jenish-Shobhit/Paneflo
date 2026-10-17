import Foundation
import Testing
@testable import PanefloCore

/// Display fixtures are written the way AppKit reports them (bottom-left origin) and converted,
/// so these tests exercise the same path as the app.
struct DisplayPlacementTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowRect {
        WindowRect(x: x, y: y, width: w, height: h)
    }

    private func display(frame: WindowRect, visible: WindowRect, scale: Double, primaryHeight: Double) -> DisplayArea {
        DisplayArea(appKitFrame: frame, appKitVisibleFrame: visible, backingScale: scale, primaryHeight: primaryHeight)
    }

    /// Notch laptop: 982 pt tall, 37 pt menu bar band, 70 pt Dock at the bottom.
    private var notchPrimary: DisplayArea {
        display(frame: rect(0, 0, 1512, 982), visible: rect(0, 70, 1512, 875), scale: 2, primaryHeight: 982)
    }

    private func id(_ number: UInt32) -> WindowIdentity {
        .init(process: .init(pid: 9, launchToken: 1), number: number, incarnation: 1)
    }

    // MARK: Coordinates

    @Test func conversionRoundTripsForAnyPlacementOfTheSecondaryDisplay() {
        let primaryHeight = 982.0
        let origins: [(Double, Double)] = [(1512, 0), (-1920, -100), (0, 982), (0, -1080), (300, 982 + 400), (-2560, -1440)]
        for (x, y) in origins {
            let appKit = rect(x, y, 2560, 1440)
            let ax = DisplayCoordinates.accessibilityFrame(fromAppKit: appKit, primaryHeight: primaryHeight)
            #expect(DisplayCoordinates.appKitFrame(fromAccessibility: ax, primaryHeight: primaryHeight) == appKit)
            #expect(ax.width == appKit.width && ax.height == appKit.height)
        }
    }

    @Test func primaryDisplayKeepsItsMenuBarBandAboveTheVisibleFrame() {
        let area = notchPrimary
        #expect(area.frame == rect(0, 0, 1512, 982))
        // AX y grows downward: the 37 pt notch/menu band sits above, the Dock below.
        #expect(area.visibleFrame == rect(0, 37, 1512, 875))
        #expect(area.visibleFrame.maxY == 912)
    }

    @Test func displayAbovePrimaryHasNegativeAccessibilityY() {
        let above = display(frame: rect(0, 982, 1920, 1080), visible: rect(0, 982, 1920, 1056), scale: 1, primaryHeight: 982)
        #expect(above.frame == rect(0, -1080, 1920, 1080))
        #expect(above.visibleFrame == rect(0, -1056, 1920, 1056)) // 24 pt menu bar on every display
    }

    @Test func displayBelowAndLeftOfPrimaryConvertConsistently() {
        let below = display(frame: rect(0, -1080, 1920, 1080), visible: rect(0, -1080, 1920, 1080), scale: 1, primaryHeight: 982)
        #expect(below.frame == rect(0, 982, 1920, 1080))
        let left = display(frame: rect(-1920, -50, 1920, 1080), visible: rect(-1920, -50, 1920, 1056), scale: 1, primaryHeight: 982)
        #expect(left.frame == rect(-1920, -48, 1920, 1080))
        #expect(left.visibleFrame == rect(-1920, -48 + 24, 1920, 1056))
    }

    // MARK: Zones per display layout

    @Test func halvesFillTheVisibleFrameForEveryDockPosition() throws {
        let frame = rect(0, 0, 1600, 1000)
        let variants: [(String, WindowRect)] = [
            ("bottom", rect(0, 80, 1600, 896)),   // menu bar 24, Dock 80 below
            ("left", rect(72, 0, 1528, 976)),
            ("right", rect(0, 0, 1528, 976)),
            ("hidden", rect(0, 0, 1600, 976)),
        ]
        for (name, visible) in variants {
            let area = display(frame: frame, visible: visible, scale: 2, primaryHeight: 1000)
            let window = rect(400, 300, 500, 400)
            let left = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: window, displays: [area], gap: 0)).rect
            let right = try #require(DisplayPlacement.planTile(zone: .rightHalf, window: window, displays: [area], gap: 0)).rect
            #expect(left.x == area.visibleFrame.x, "\(name)")
            #expect(right.maxX == area.visibleFrame.maxX, "\(name)")
            #expect(left.maxX == right.x, "\(name)")
            #expect(left.y == area.visibleFrame.y && left.height == area.visibleFrame.height, "\(name)")
        }
    }

    @Test func fillStaysInsideTheNotchSafeArea() throws {
        let area = notchPrimary
        let fill = try #require(DisplayPlacement.planTile(zone: .maximize, window: rect(100, 100, 400, 300), displays: [area], gap: 0)).rect
        #expect(fill == area.visibleFrame)
        #expect(fill.y >= 37)
    }

    @Test func mixedScaleDisplaysAlignToTheirOwnPixelGrid() throws {
        let retina = notchPrimary
        let external = display(frame: rect(1512, 0, 2561, 1440), visible: rect(1512, 0, 2561, 1416), scale: 1, primaryHeight: 982)
        let displays = [retina, external]
        for window in [rect(100, 200, 500, 400), rect(2000, 200, 500, 400)] {
            let plan = try #require(DisplayPlacement.planTile(zone: .rightHalf, window: window, displays: displays, gap: 7.3, cycleDisplays: false))
            let scale = displays[plan.displayIndex].backingScale
            #expect(abs(plan.rect.x * scale - (plan.rect.x * scale).rounded()) < 1e-9)
            #expect(abs(plan.rect.maxX * scale - (plan.rect.maxX * scale).rounded()) < 1e-9)
            #expect(displays[plan.displayIndex].visibleFrame.contains(plan.rect))
        }
    }

    // MARK: Display choice from the fresh frame

    @Test func theWindowsOwnCurrentFrameDecidesTheDisplay() throws {
        let primary = notchPrimary
        let right = display(frame: rect(1512, 0, 1920, 1080), visible: rect(1512, 0, 1920, 1056), scale: 1, primaryHeight: 982)
        let displays = [primary, right]
        // Same window, two different fresh frames: a stale record would have said "primary".
        let onPrimary = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: rect(200, 200, 600, 400), displays: displays, gap: 0))
        let onRight = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: rect(2000, 200, 600, 400), displays: displays, gap: 0))
        #expect(onPrimary.displayIndex == 0)
        #expect(onRight.displayIndex == 1)
        #expect(onRight.rect.x == right.visibleFrame.x)
    }

    @Test func windowStraddlingDisplaysGoesToTheLargerOverlap() {
        let a = display(frame: rect(0, 0, 1000, 800), visible: rect(0, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let b = display(frame: rect(1000, 0, 1000, 800), visible: rect(1000, 0, 1000, 800), scale: 1, primaryHeight: 800)
        #expect(DisplayPlacement.displayIndex(for: rect(900, 100, 500, 300), in: [a, b]) == 1)
        #expect(DisplayPlacement.displayIndex(for: rect(700, 100, 500, 300), in: [a, b]) == 0)
    }

    @Test func offscreenWindowsFallBackToTheNearestDisplay() {
        let a = display(frame: rect(0, 0, 1000, 800), visible: rect(0, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let b = display(frame: rect(1000, 0, 1000, 800), visible: rect(1000, 0, 1000, 800), scale: 1, primaryHeight: 800)
        #expect(DisplayPlacement.displayIndex(for: rect(5000, 100, 300, 300), in: [a, b]) == 1)
        #expect(DisplayPlacement.displayIndex(for: rect(-4000, 100, 300, 300), in: [a, b]) == 0)
        #expect(DisplayPlacement.displayIndex(for: rect(0, 0, 10, 10), in: []) == nil)
    }

    @Test func displayAboveIsChosenForWindowsThereAndFillsItsOwnVisibleFrame() throws {
        let primary = notchPrimary
        let above = display(frame: rect(0, 982, 1920, 1080), visible: rect(0, 982, 1920, 1056), scale: 1, primaryHeight: 982)
        let plan = try #require(DisplayPlacement.planTile(zone: .maximize, window: rect(200, -800, 500, 300), displays: [primary, above], gap: 0))
        #expect(plan.displayIndex == 1)
        #expect(plan.rect == above.visibleFrame)
    }

    @Test func explicitDisplayOverridesWithoutCycling() throws {
        let a = display(frame: rect(0, 0, 1000, 800), visible: rect(0, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let b = display(frame: rect(1000, 0, 1000, 800), visible: rect(1000, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let plan = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: rect(100, 100, 300, 300), displays: [a, b], explicitDisplay: 1, gap: 0))
        #expect(plan.displayIndex == 1 && !plan.cycled)
        #expect(plan.rect == rect(1000, 0, 500, 800))
    }

    // MARK: Repeated half-screen requests

    @Test func repeatingLeftHalfMovesToTheLeftDisplayAndStopsAtTheEdge() throws {
        let left = display(frame: rect(-1920, 0, 1920, 1080), visible: rect(-1920, 0, 1920, 1056), scale: 1, primaryHeight: 1080)
        let primary = display(frame: rect(0, 0, 1728, 1080), visible: rect(0, 0, 1728, 1056), scale: 2, primaryHeight: 1080)
        let displays = [primary, left]
        let first = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: rect(300, 300, 400, 300), displays: displays, gap: 8))
        #expect(first.displayIndex == 0 && !first.cycled)
        let second = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: first.rect, displays: displays, gap: 8))
        #expect(second.displayIndex == 1 && second.cycled)
        #expect(left.visibleFrame.contains(second.rect))
        #expect(second.rect.x == left.visibleFrame.x + 8)
        let third = try #require(DisplayPlacement.planTile(zone: .leftHalf, window: second.rect, displays: displays, gap: 8))
        #expect(third.displayIndex == 1 && !third.cycled && third.rect == second.rect)
    }

    @Test func repeatingRightHalfMovesRightAndOtherZonesNeverCycle() throws {
        let a = display(frame: rect(0, 0, 1000, 800), visible: rect(0, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let b = display(frame: rect(1000, 0, 1000, 800), visible: rect(1000, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let first = try #require(DisplayPlacement.planTile(zone: .rightHalf, window: rect(100, 100, 300, 300), displays: [a, b], gap: 0))
        let second = try #require(DisplayPlacement.planTile(zone: .rightHalf, window: first.rect, displays: [a, b], gap: 0))
        #expect(second.displayIndex == 1 && second.cycled && second.rect == rect(1500, 0, 500, 800))
        let fill = try #require(DisplayPlacement.planTile(zone: .maximize, window: a.visibleFrame, displays: [a, b], gap: 0))
        #expect(fill.displayIndex == 0 && !fill.cycled)
        // A window that merely sits near the half does not cycle.
        let near = try #require(DisplayPlacement.planTile(zone: .rightHalf, window: rect(480, 0, 520, 800), displays: [a, b], gap: 0))
        #expect(!near.cycled)
    }

    @Test func neighbourPrefersVerticalOverlapOverDiagonalDisplays() {
        let main = display(frame: rect(0, 0, 1000, 800), visible: rect(0, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let beside = display(frame: rect(-1000, 0, 1000, 800), visible: rect(-1000, 0, 1000, 800), scale: 1, primaryHeight: 800)
        let diagonal = display(frame: rect(-1000, 800, 1000, 800), visible: rect(-1000, 800, 1000, 800), scale: 1, primaryHeight: 800)
        #expect(DisplayPlacement.neighbourIndex(of: 0, direction: -1, in: [main, diagonal, beside]) == 2)
        #expect(DisplayPlacement.neighbourIndex(of: 0, direction: 1, in: [main, diagonal, beside]) == nil)
    }

    // MARK: Apps that limit their own size

    @Test func smallerThanRequestedIsCenteredInTheZone() {
        let zone = rect(100, 50, 800, 600)
        let bounds = rect(0, 0, 1600, 900)
        let settled = DisplayPlacement.settledFrame(requested: zone, accepted: WindowSize(width: 400, height: 300), within: bounds)
        #expect(settled == rect(300, 200, 400, 300))
        // Only the clamped axis moves.
        let narrow = DisplayPlacement.settledFrame(requested: zone, accepted: WindowSize(width: 400, height: 600), within: bounds)
        #expect(narrow == rect(300, 50, 400, 600))
    }

    @Test func largerThanRequestedKeepsTheOriginAndStaysOnTheDisplay() {
        let bounds = rect(0, 0, 1600, 900)
        let leftZone = rect(0, 0, 800, 900)
        #expect(DisplayPlacement.settledFrame(requested: leftZone, accepted: WindowSize(width: 1000, height: 900), within: bounds)
            == rect(0, 0, 1000, 900))
        // On the right half the same window would overflow, so it shifts left just enough.
        let rightZone = rect(800, 0, 800, 900)
        #expect(DisplayPlacement.settledFrame(requested: rightZone, accepted: WindowSize(width: 1000, height: 900), within: bounds)
            == rect(600, 0, 1000, 900))
        // Wider than the display: pinned to its left edge.
        #expect(DisplayPlacement.settledFrame(requested: rightZone, accepted: WindowSize(width: 2000, height: 900), within: bounds).x == 0)
    }

    @Test func exactSizeSettlesToTheRequestedFrame() {
        let zone = rect(10, 20, 500, 400)
        #expect(DisplayPlacement.settledFrame(requested: zone, accepted: zone.size, within: rect(0, 0, 1000, 800)) == zone)
        #expect(DisplayPlacement.settledFrame(requested: zone, accepted: .zero, within: rect(0, 0, 1000, 800)) == zone)
    }

    // MARK: Undo

    @Test func undoRestoresTheExactFrameWhileItsDisplayRemains() {
        let area = notchPrimary
        let before = rect(333.5, 120.25, 777, 410)
        #expect(DisplayPlacement.restoredFrame(before, displays: [area]) == before)
        // A window that overlapped the Dock area is still restored exactly.
        let overDock = rect(100, 600, 800, 372)
        #expect(DisplayPlacement.restoredFrame(overDock, displays: [area]) == overDock)
    }

    @Test func undoAfterDisplayRemovalClampsIntoTheRemainingDisplay() throws {
        let primary = notchPrimary
        let removed = rect(2200, 300, 900, 600) // lived on an external display that is gone
        let restored = try #require(DisplayPlacement.restoredFrame(removed, displays: [primary]))
        #expect(primary.visibleFrame.contains(restored))
        #expect(restored.size == removed.size)
        let tooBig = rect(-3000, -2000, 3000, 2500)
        let shrunk = try #require(DisplayPlacement.restoredFrame(tooBig, displays: [primary]))
        #expect(primary.visibleFrame.contains(shrunk))
        #expect(DisplayPlacement.restoredFrame(removed, displays: []) == nil)
    }

    @Test func undoPicksTheNearestRemainingDisplayWhenSeveralRemain() throws {
        let left = display(frame: rect(-1920, 0, 1920, 1080), visible: rect(-1920, 0, 1920, 1056), scale: 1, primaryHeight: 1080)
        let primary = display(frame: rect(0, 0, 1728, 1080), visible: rect(0, 0, 1728, 1056), scale: 2, primaryHeight: 1080)
        let gone = rect(-6000, 100, 700, 500)
        let restored = try #require(DisplayPlacement.restoredFrame(gone, displays: [primary, left]))
        #expect(left.visibleFrame.contains(restored))
    }

    private func undo(_ stack: inout GeometryUndoHistory, _ window: WindowIdentity, _ alive: Set<WindowIdentity>) -> GeometryUndoPlan? {
        stack.undo(window: window, surviving: alive)
    }

    @Test func perWindowUndoWalksBackThroughASingleWindowsTiles() throws {
        var stack = GeometryUndoHistory()
        let f0 = rect(0, 0, 400, 300), f1 = rect(10, 0, 500, 300), f2 = rect(20, 0, 600, 300)
        let other = rect(5, 5, 100, 100), otherAfter = rect(6, 6, 100, 100)
        stack.record([GeometryChange(id: id(1), before: f0, after: f1)])
        stack.record([GeometryChange(id: id(2), before: other, after: otherAfter)])
        stack.record([GeometryChange(id: id(1), before: f1, after: f2)])
        let alive: Set = [id(1), id(2)]
        #expect(stack.hasHistory(for: id(2)))
        // Window 2's undo ignores window 1's later tile.
        let stepOther = undo(&stack, id(2), alive)
        #expect(stepOther?.changes.first?.before == other)
        #expect(!stack.hasHistory(for: id(2)))
        let stepOne = undo(&stack, id(1), alive)
        #expect(stepOne?.changes.first?.before == f1)
        let stepTwo = undo(&stack, id(1), alive)
        #expect(stepTwo?.changes.first?.before == f0)
        #expect(undo(&stack, id(1), alive) == nil)
        #expect(stack.count == 0)
    }

    @Test func perWindowUndoSkipsClosedWindowsAndStaysBounded() throws {
        var stack = GeometryUndoHistory()
        stack.record([GeometryChange(id: id(1), before: rect(0, 0, 10, 10), after: rect(1, 0, 10, 10))])
        let plan = undo(&stack, id(1), [])
        #expect(plan?.changes.isEmpty == true && plan?.skipped == [id(1)])
        for n in 1...30 {
            stack.record([GeometryChange(id: id(1), before: rect(Double(n), 0, 10, 10), after: rect(Double(n) + 1, 0, 10, 10))])
        }
        var undone = 0
        while undo(&stack, id(1), [id(1)]) != nil { undone += 1 }
        #expect(undone == GeometryUndoHistory.capacity)
    }
}
