import Foundation
import Testing
@testable import PanefloCore

struct LayoutEngineTests {
    @Test
    func testAllZonesRemainInsideUsableBoundsAtMixedScales() throws {
        let bounds = WindowRect(x: -900.25, y: 33.25, width: 1_001.5, height: 743.5)
        for scale in [1.0, 1.5, 2.0] {
            for zone in LayoutZone.allCases {
                let rect = try #require(LayoutEngine.plan(zone: zone, in: bounds, gap: 8.2, backingScale: scale).rect)
                #expect(bounds.contains(rect), "\(zone), \(scale)")
                #expect(abs((rect.x * scale) - ((rect.x * scale).rounded())) <= 0.000_001)
                #expect(abs((rect.maxX * scale) - ((rect.maxX * scale).rounded())) <= 0.000_001)
                #expect(abs((rect.y * scale) - ((rect.y * scale).rounded())) <= 0.000_001)
            }
        }
    }

    @Test
    func testThirdsShareBoundariesWithoutOverlapOrSeams() throws {
        let bounds = WindowRect(x: 0, y: 0, width: 1_001, height: 700)
        for scale in [1.0, 2.0] {
            let first = try #require(LayoutEngine.plan(zone: .firstThird, in: bounds, backingScale: scale).rect)
            let middle = try #require(LayoutEngine.plan(zone: .middleThird, in: bounds, backingScale: scale).rect)
            let last = try #require(LayoutEngine.plan(zone: .lastThird, in: bounds, backingScale: scale).rect)
            #expect(first.maxX == middle.x)
            #expect(middle.maxX == last.x)
            #expect(first.width + middle.width + last.width == bounds.width)
        }
        let left = try #require(LayoutEngine.plan(zone: .leftHalf, in: bounds, gap: 9, backingScale: 2).rect)
        let right = try #require(LayoutEngine.plan(zone: .rightHalf, in: bounds, gap: 9, backingScale: 2).rect)
        #expect(right.x - left.maxX == 9)
        #expect(left.x == 9)
        #expect(bounds.maxX - right.maxX == 9)
    }

    @Test
    func testConstraintsAndInvalidNumbersAreExplicitlyRejected() {
        let bounds = WindowRect(x: 0, y: 0, width: 1_000, height: 800)
        #expect(LayoutEngine.plan(zone: .leftHalf, in: bounds, minimumSize: WindowSize(width: 600, height: 200)) == .rejected(.minimumSize))
        #expect(LayoutEngine.plan(zone: .maximize, in: bounds, gap: 500) == .rejected(.insufficientSpace))
        #expect(LayoutEngine.plan(zone: .center, in: bounds, currentSize: WindowSize(width: 1_001, height: 10)) == .rejected(.insufficientSpace))
        #expect(LayoutEngine.plan(zone: .maximize, in: bounds, backingScale: 0) == .rejected(.invalidInput))
        #expect(LayoutEngine.plan(zone: .maximize, in: bounds, gap: .infinity) == .rejected(.invalidInput))
        #expect(LayoutEngine.plan(zone: .maximize, in: WindowRect(x: .nan, y: 0, width: 10, height: 10)) == .rejected(.invalidInput))
    }

    @Test
    func testDisplayTransferPreservesAnchorsAndRecoversOffscreenWindows() throws {
        let source = WindowRect(x: 0, y: 0, width: 1_200, height: 800)
        let destination = WindowRect(x: -600, y: 50, width: 600, height: 1_000)
        let corner = WindowRect(x: 800, y: 500, width: 400, height: 300)
        let transferred = try #require(LayoutEngine.transfer(corner, from: source, to: destination).rect)
        #expect(transferred.maxX == destination.maxX)
        #expect(transferred.maxY == destination.maxY)
        #expect(transferred.size == corner.size)
        let full = try #require(LayoutEngine.transfer(source, from: source, to: destination).rect)
        #expect(full == destination)
        let lost = WindowRect(x: 9_000, y: -9_000, width: 2_000, height: 2_000)
        #expect(LayoutEngine.recover(lost, in: destination).rect == destination)
        let leftHalf = WindowRect(x: 0, y: 0, width: 600, height: 800)
        let portrait = try #require(LayoutEngine.transfer(leftHalf, from: source, to: destination).rect)
        #expect(destination.contains(portrait))
        #expect(portrait.height == 800)
        #expect(portrait.y == 150)
    }

    @Test
    func testUndoIsBoundedAndNeverRestoresReusedWindowNumbers() throws {
        var history = GeometryUndoHistory()
        let before = WindowRect(x: 0, y: 0, width: 300, height: 300)
        for n in 1...25 {
            let after = WindowRect(x: Double(n), y: 0, width: 300, height: 300)
            history.record([GeometryChange(id: windowID(1), before: before, after: after)])
        }
        #expect(history.count == 20)
        let optionalValue78 = history.undo(surviving: [windowID(1, incarnation: 2)])
        let skipped = try #require(optionalValue78)
        #expect(skipped.changes.isEmpty)
        #expect(skipped.skipped == [windowID(1)])
        let optionalValue81 = history.undo(surviving: [windowID(1)])
        let valid = try #require(optionalValue81)
        #expect(valid.changes[0].before == before)
        #expect(valid.changes[0].after.x == 24)
    }
}
