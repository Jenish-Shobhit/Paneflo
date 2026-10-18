import Foundation
import Testing
@testable import PanefloCore

/// LayoutEngine / DisplayPlacement / DisplayCoordinates properties over random display arrangements.
struct FuzzLayoutTests {
    /// 1 to 4 displays in Accessibility coordinates; mixed scale, negative origins, menu bar and Dock insets.
    private static func randomDisplays(_ rng: inout FuzzRandom) -> [DisplayArea] {
        let count = rng.int(1...4)
        var result: [DisplayArea] = []
        var leftEdge = 0.0, rightEdge = 0.0
        for index in 0..<count {
            let portrait = rng.chance(0.2)
            var width = Double(rng.pick([1280, 1440, 1512, 1728, 1920, 2560, 3008]))
            var height = Double(rng.pick([720, 900, 982, 1117, 1080, 1440]))
            if portrait { swap(&width, &height) }
            let x: Double, y: Double
            if index == 0 { x = 0; y = 0; rightEdge = width }
            else if rng.chance(0.5) { x = leftEdge - width; y = Double(rng.int(-400...400)); }
            else { x = rightEdge; y = Double(rng.int(-400...400)); rightEdge = x + width }
            leftEdge = min(leftEdge, x)
            let menuBar = Double(rng.pick([0, 24, 25, 38]))
            let dock = Double(rng.pick([0, 0, 60, 80]))
            let dockSide = rng.int(0...2) // bottom, left, right
            var visible = WindowRect(x: x, y: y + menuBar, width: width, height: height - menuBar)
            switch dockSide {
            case 0: visible.height -= dock
            case 1: visible.x += dock; visible.width -= dock
            default: visible.width -= dock
            }
            result.append(DisplayArea(frame: WindowRect(x: x, y: y, width: width, height: height), visibleFrame: visible,
                                      backingScale: rng.pick([1, 1.5, 2, 3])))
        }
        return result
    }

    /// Containment with a 1e-6 point allowance for floating-point rounding.
    static func inside(_ rect: WindowRect, _ bounds: WindowRect) -> Bool {
        rect.isValid && bounds.isValid && rect.x >= bounds.x - 1e-6 && rect.y >= bounds.y - 1e-6
            && rect.maxX <= bounds.maxX + 1e-6 && rect.maxY <= bounds.maxY + 1e-6
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    private func aligned(_ value: Double, scale: Double) -> Bool {
        let scaled = value * scale
        return abs(scaled - scaled.rounded()) < 1e-6
    }

    @Test func everyZoneStaysInsideItsVisibleFrameAndTilesCleanly() {
        for seed in UInt64(0)..<1000 {
            var rng = FuzzRandom(seed: seed)
            for display in Self.randomDisplays(&rng) {
                let gap = Double(rng.pick([0, 0, 1, 8, 16, 33, 64]))
                let scale = display.backingScale
                let bounds = display.visibleFrame
                func plan(_ zone: LayoutZone) -> WindowRect? {
                    LayoutEngine.plan(zone: zone, in: bounds, gap: gap, backingScale: scale).rect
                }
                for zone in LayoutZone.allCases {
                    guard let rect = plan(zone) else { fail("seed \(seed): \(zone) rejected on \(bounds) gap \(gap)"); continue }
                    #expect(Self.inside(rect, bounds), "seed \(seed): \(zone) escapes visibleFrame \(rect) vs \(bounds)")
                    #expect([rect.x, rect.y, rect.maxX, rect.maxY].allSatisfy { aligned($0, scale: scale) }, "seed \(seed): \(zone) not pixel aligned at scale \(scale)")
                    #expect(LayoutEngine.plan(zone: zone, in: bounds, gap: gap, backingScale: scale).rect == rect, "plan is not pure")
                }
                guard let full = plan(.maximize), let left = plan(.leftHalf), let right = plan(.rightHalf),
                      let top = plan(.topHalf), let bottom = plan(.bottomHalf) else { continue }
                let seam = gap + 2 / scale + 1e-6
                #expect(left.maxX <= right.x + 1e-9 && right.x - left.maxX <= seam, "seed \(seed): halves overlap or leave a gap, \(left) \(right)")
                #expect(near(left.x, full.x) && near(right.maxX, full.maxX) && near(left.y, full.y) && near(left.height, full.height), "seed \(seed): halves do not cover the zone \(left) \(right) full \(full) gap \(gap) scale \(scale)")
                #expect(top.maxY <= bottom.y + 1e-9 && bottom.y - top.maxY <= seam && near(top.y, full.y) && near(bottom.maxY, full.maxY), "seed \(seed): vertical halves top \(top) bottom \(bottom) full \(full) gap \(gap) scale \(scale) bounds \(bounds)")
                if let a = plan(.firstThird), let b = plan(.middleThird), let c = plan(.lastThird) {
                    #expect(a.maxX <= b.x + 1e-9 && b.maxX <= c.x + 1e-9 && b.x - a.maxX <= seam && c.x - b.maxX <= seam, "seed \(seed): thirds overlap/gap")
                    #expect(near(a.x, full.x) && near(c.maxX, full.maxX), "seed \(seed): thirds do not span the zone")
                }
                if let tl = plan(.topLeftQuarter), let tr = plan(.topRightQuarter), let bl = plan(.bottomLeftQuarter), let br = plan(.bottomRightQuarter) {
                    #expect(tl.intersectionArea(tr) < 1e-6 && tl.intersectionArea(bl) < 1e-6 && br.intersectionArea(tr) < 1e-6 && br.intersectionArea(bl) < 1e-6, "seed \(seed): quarters overlap \(tl) \(tr) \(bl) \(br) gap \(gap) scale \(scale) bounds \(bounds)")
                    #expect(near(tl.x, full.x) && near(br.maxX, full.maxX) && near(tl.y, full.y) && near(br.maxY, full.maxY), "seed \(seed): quarters do not span the zone")
                }
                // Translation invariance (integer shift at scale 1 is exact).
                if scale == 1 {
                    let dx = Double(rng.int(-3000...3000)), dy = Double(rng.int(-3000...3000))
                    let moved = WindowRect(x: bounds.x + dx, y: bounds.y + dy, width: bounds.width, height: bounds.height)
                    let shifted = LayoutEngine.plan(zone: .leftHalf, in: moved, gap: gap, backingScale: 1).rect
                    #expect(shifted?.isClose(to: WindowRect(x: left.x + dx, y: left.y + dy, width: left.width, height: left.height), tolerance: 1 / scale + 1e-6) == true, "seed \(seed): translation changed the plan beyond one pixel")
                }
            }
        }
    }

    @Test func coordinateConversionRoundTripsExactlyAndApproximately() {
        for seed in UInt64(0)..<500 {
            var rng = FuzzRandom(seed: seed)
            let height = Double(rng.int(300...3000))
            let dyadic = WindowRect(x: Double(rng.int(-8000...8000)) / 4, y: Double(rng.int(-8000...8000)) / 4,
                                    width: Double(rng.int(1...8000)) / 4, height: Double(rng.int(1...8000)) / 4)
            let there = DisplayCoordinates.appKitFrame(fromAccessibility: dyadic, primaryHeight: height)
            #expect(DisplayCoordinates.accessibilityFrame(fromAppKit: there, primaryHeight: height) == dyadic, "seed \(seed): lossy round trip")
            let wild = WindowRect(x: rng.double(-1e5...1e5), y: rng.double(-1e5...1e5), width: rng.double(1...1e4), height: rng.double(1...1e4))
            let back = DisplayCoordinates.accessibilityFrame(fromAppKit: DisplayCoordinates.appKitFrame(fromAccessibility: wild, primaryHeight: height), primaryHeight: height)
            #expect(back.isClose(to: wild, tolerance: 1e-7), "seed \(seed): drift \(back) vs \(wild)")
            // The AppKit initializer agrees with converting by hand.
            let area = DisplayArea(appKitFrame: dyadic, appKitVisibleFrame: dyadic, backingScale: 2, primaryHeight: height)
            #expect(area.frame == DisplayCoordinates.accessibilityFrame(fromAppKit: dyadic, primaryHeight: height))
        }
    }

    @Test func undoClampAlwaysLandsOnAScreenAndTilesStayInsideTheirDisplay() {
        for seed in UInt64(0)..<1000 {
            var rng = FuzzRandom(seed: seed)
            let displays = Self.randomDisplays(&rng)
            for _ in 0..<20 {
                let before = WindowRect(x: rng.double(-6000...8000), y: rng.double(-4000...5000),
                                        width: rng.double(50...5000), height: rng.double(50...3000))
                guard let restored = DisplayPlacement.restoredFrame(before, displays: displays) else {
                    fail("seed \(seed): valid frame had no restore target"); continue
                }
                #expect(restored.isValid, "seed \(seed)")
                if restored == before {
                    let onScreen = displays.reduce(0.0) { $0 + $1.frame.intersectionArea(before) }
                    #expect(onScreen >= before.width * before.height * 0.95 - 1e-6, "seed \(seed): off-screen frame returned unchanged")
                } else {
                    #expect(displays.contains { Self.inside(restored, $0.visibleFrame) }, "seed \(seed): clamped frame \(restored) not inside any visible frame")
                    #expect(restored.width <= before.width + 1e-9 && restored.height <= before.height + 1e-9, "seed \(seed): clamp grew the window")
                }
                let zone = rng.pick(LayoutZone.allCases)
                if let tile = DisplayPlacement.planTile(zone: zone, window: before, displays: displays, gap: Double(rng.pick([0, 8, 24]))) {
                    #expect(displays.indices.contains(tile.displayIndex) && Self.inside(tile.rect, displays[tile.displayIndex].visibleFrame), "seed \(seed): tile \(zone) escapes display")
                }
            }
        }
    }

    @Test func recoverTransferAndSettleStayInsideBounds() {
        for seed in UInt64(0)..<400 {
            var rng = FuzzRandom(seed: seed)
            let displays = Self.randomDisplays(&rng)
            let source = displays[0], destination = displays[displays.count - 1]
            let rect = WindowRect(x: source.visibleFrame.x + rng.double(-200...1500), y: source.visibleFrame.y + rng.double(-200...900),
                                  width: rng.double(80...2200), height: rng.double(80...1500))
            if let moved = LayoutEngine.transfer(rect, from: source.visibleFrame, to: destination.visibleFrame, backingScale: destination.backingScale).rect {
                #expect(Self.inside(moved, destination.visibleFrame), "seed \(seed): transfer escaped destination")
            }
            if let recovered = LayoutEngine.recover(rect, in: destination.visibleFrame, backingScale: destination.backingScale).rect {
                #expect(Self.inside(recovered, destination.visibleFrame), "seed \(seed): recover escaped")
                #expect(recovered.width <= rect.width + 1e-9 && recovered.height <= rect.height + 1e-9, "seed \(seed): recover grew")
            }
            let zone = rng.pick(LayoutZone.allCases)
            if let requested = LayoutEngine.plan(zone: zone, in: destination.visibleFrame, gap: 8, backingScale: destination.backingScale).rect {
                let accepted = WindowSize(width: requested.width * rng.double(0.3...1), height: requested.height * rng.double(0.3...1))
                let settled = DisplayPlacement.settledFrame(requested: requested, accepted: accepted, within: destination.visibleFrame)
                #expect(Self.inside(settled, requested), "seed \(seed): shrunken window left its zone")
            }
        }
    }

    @Test func twoDisplayNeighboursAreSymmetric() {
        for seed in UInt64(0)..<200 {
            var rng = FuzzRandom(seed: seed)
            var displays = Self.randomDisplays(&rng)
            while displays.count > 2 { displays.removeLast() }
            guard displays.count == 2 else { continue }
            if displays[0].frame.centerX == displays[1].frame.centerX { continue }
            let rightOfFirst = displays[0].frame.centerX < displays[1].frame.centerX
            #expect(DisplayPlacement.neighbourIndex(of: 0, direction: rightOfFirst ? 1 : -1, in: displays) == 1, "seed \(seed)")
            #expect(DisplayPlacement.neighbourIndex(of: 1, direction: rightOfFirst ? -1 : 1, in: displays) == 0, "seed \(seed)")
        }
    }
}
