import Foundation
import Testing
@testable import PanefloCore

struct TileGroupRegistryTests {
    /// Retina laptop (2x) with a menu bar and Dock, and a 1x external display to its right.
    private let laptop = DisplayArea(frame: WindowRect(x: 0, y: 0, width: 1512, height: 982),
                                     visibleFrame: WindowRect(x: 0, y: 37, width: 1512, height: 875), backingScale: 2)
    private let external = DisplayArea(frame: WindowRect(x: 1512, y: -98, width: 1920, height: 1080),
                                       visibleFrame: WindowRect(x: 1512, y: -73, width: 1920, height: 1055), backingScale: 1)
    private var displays: [DisplayArea] { [laptop, external] }

    private func half(_ zone: LayoutZone, on display: DisplayArea, gap: Double = 8) -> WindowRect {
        LayoutEngine.plan(zone: zone, in: display.visibleFrame, gap: gap, backingScale: display.backingScale).rect!
    }

    private func window(_ number: UInt32, _ frame: WindowRect, minimized: Bool = false, pid: Int32 = 7) -> WindowRecord {
        WindowRecord(id: windowID(number, pid: pid), appIdentifier: "example.app", appName: "Example", title: "Window",
                     frame: frame, isMinimized: minimized)
    }

    private let floating = WindowRect(x: 200, y: 200, width: 640, height: 480)

    // MARK: Detection

    @Test func complementaryHalvesOnOneDisplayPair() {
        var registry = TileGroupRegistry()
        let records = [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: laptop))]
        let result1 = registry.reconcile(records: records, displays: displays, now: 0)
        #expect(result1)
        let group = try! #require(registry.group(containing: windowID(1)))
        #expect(group.layout == .leftRight && group.first == windowID(1) && group.second == windowID(2))
        #expect(group.display == laptop.frame)
        #expect(registry.partner(of: windowID(2)) == windowID(1))
        #expect(group.role(of: windowID(2)) == .right)
        // Nothing changes on the next identical snapshot.
        let result2 = registry.reconcile(records: records, displays: displays, now: 1)
        #expect(!result2)
        #expect(registry.groups.count == 1 && registry.groups[0].id == group.id)
    }

    @Test func topAndBottomHalvesPair() {
        var registry = TileGroupRegistry()
        registry.reconcile(records: [window(1, half(.bottomHalf, on: external)), window(2, half(.topHalf, on: external))],
                           displays: displays, now: 0)
        let group = try! #require(registry.groups.first)
        #expect(group.layout == .topBottom && group.first == windowID(2) && group.second == windowID(1))
        #expect(group.display == external.frame)
    }

    @Test func toleranceAcceptsOtherGapsAndRejectsThirds() {
        let v = laptop.visibleFrame
        // Zero-gap halves (macOS tiling without margins) and a 16 pt gap both pair.
        for gap in [0.0, 16.0] {
            var registry = TileGroupRegistry()
            registry.reconcile(records: [window(1, half(.leftHalf, on: laptop, gap: gap)),
                                         window(2, half(.rightHalf, on: laptop, gap: gap))], displays: displays, now: 0)
            #expect(registry.groups.count == 1, "gap \(gap)")
        }
        // A window that rounds its width to a character grid (a few points narrower, centred) still pairs.
        var rounded = TileGroupRegistry()
        let left = half(.leftHalf, on: laptop)
        let narrow = WindowRect(x: left.x + 5, y: left.y, width: left.width - 10, height: left.height)
        rounded.reconcile(records: [window(1, narrow), window(2, half(.rightHalf, on: laptop))], displays: displays, now: 0)
        #expect(rounded.groups.count == 1)
        // A first third next to a right half does not.
        var thirds = TileGroupRegistry()
        let third = WindowRect(x: v.x, y: v.y, width: v.width / 3, height: v.height)
        thirds.reconcile(records: [window(1, third), window(2, half(.rightHalf, on: laptop))], displays: displays, now: 0)
        #expect(thirds.groups.isEmpty)
        // Just outside the tolerance does not.
        var outside = TileGroupRegistry()
        let short = WindowRect(x: left.x, y: left.y + 40, width: left.width, height: left.height - 40)
        outside.reconcile(records: [window(1, short), window(2, half(.rightHalf, on: laptop))], displays: displays, now: 0)
        #expect(outside.groups.isEmpty)
    }

    @Test func halvesOnDifferentDisplaysDoNotPairEvenWithMixedScales() {
        var registry = TileGroupRegistry()
        registry.reconcile(records: [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: external))],
                           displays: displays, now: 0)
        #expect(registry.groups.isEmpty)
        // Each display pairs its own halves, independently of the other's scale.
        registry.reconcile(records: [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: external)),
                                     window(3, half(.rightHalf, on: laptop)), window(4, half(.leftHalf, on: external))],
                           displays: displays, now: 1)
        #expect(registry.partner(of: windowID(1)) == windowID(3))
        #expect(registry.partner(of: windowID(4)) == windowID(2))
    }

    @Test func eachWindowJoinsAtMostOnePairAndTheMostRecentWins() {
        var registry = TileGroupRegistry()
        // MRU order: 3 (left), 1 (left, behind it), 2 (right).
        registry.reconcile(records: [window(3, half(.leftHalf, on: laptop)), window(1, half(.leftHalf, on: laptop)),
                                     window(2, half(.rightHalf, on: laptop))], displays: displays, now: 0)
        #expect(registry.groups.count == 1)
        #expect(registry.partner(of: windowID(2)) == windowID(3))
        #expect(registry.group(containing: windowID(1)) == nil)
    }

    @Test func minimizedAndFloatingWindowsNeverPair() {
        var registry = TileGroupRegistry()
        registry.reconcile(records: [window(1, half(.leftHalf, on: laptop), minimized: true), window(2, half(.rightHalf, on: laptop)),
                                     window(3, floating)], displays: displays, now: 0)
        #expect(registry.groups.isEmpty)
    }

    // MARK: Dissolution

    @Test func pairDissolvesWhenAMemberCloses() {
        var registry = paired()
        let result3 = registry.reconcile(records: [window(2, half(.rightHalf, on: laptop))], displays: displays, now: 1)
        #expect(result3)
        #expect(registry.groups.isEmpty)
    }

    @Test func pairDissolvesWhenAMemberMinimizes() {
        var registry = paired()
        registry.reconcile(records: [window(1, half(.leftHalf, on: laptop), minimized: true), window(2, half(.rightHalf, on: laptop))],
                           displays: displays, now: 1)
        #expect(registry.groups.isEmpty)
    }

    @Test func pairDissolvesWhenAMemberMovesToAnotherDisplay() {
        var registry = paired()
        registry.reconcile(records: [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: external))],
                           displays: displays, now: 1)
        #expect(registry.groups.isEmpty)
    }

    @Test func pairDissolvesWhenAFrameLeavesItsHalfButSurvivesSmallDrift() {
        var registry = paired()
        let left = half(.leftHalf, on: laptop)
        let drifted = WindowRect(x: left.x + 6, y: left.y, width: left.width, height: left.height - 4)
        let result4 = registry.reconcile(records: [window(1, drifted), window(2, half(.rightHalf, on: laptop))], displays: displays, now: 1)
        #expect(!result4)
        #expect(registry.groups.count == 1)
        registry.reconcile(records: [window(1, floating), window(2, half(.rightHalf, on: laptop))], displays: displays, now: 2)
        #expect(registry.groups.isEmpty)
    }

    @Test func pairDissolvesWhenItsDisplayIsGoneOrResized() {
        var registry = TileGroupRegistry()
        let records = [window(1, half(.leftHalf, on: external)), window(2, half(.rightHalf, on: external))]
        registry.reconcile(records: records, displays: displays, now: 0)
        #expect(registry.groups.count == 1)
        // The external display is unplugged: the windows' frames now map to the laptop, outside its halves.
        registry.reconcile(records: records, displays: [laptop], now: 1)
        #expect(registry.groups.isEmpty)
    }

    @Test func swappedHalvesFormANewPairInsteadOfKeepingStaleRoles() {
        var registry = paired()
        let oldID = registry.groups[0].id
        registry.reconcile(records: [window(1, half(.rightHalf, on: laptop)), window(2, half(.leftHalf, on: laptop))],
                           displays: displays, now: 1)
        let group = try! #require(registry.groups.first)
        #expect(group.id != oldID && group.first == windowID(2) && group.second == windowID(1))
    }

    // MARK: Ungroup and explicit pairing

    @Test func ungroupIsRespectedUntilAWindowLeavesItsHalf() {
        var registry = paired()
        let records = [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: laptop))]
        let result5 = registry.ungroup(windowID(2))
        #expect(result5)
        let result6 = registry.ungroup(windowID(2))
        #expect(!result6)
        let result7 = registry.reconcile(records: records, displays: displays, now: 1)
        #expect(!result7)
        #expect(registry.groups.isEmpty)
        // The ungrouped windows still pair with others.
        registry.reconcile(records: records + [window(3, half(.leftHalf, on: laptop))], displays: displays, now: 2)
        #expect(registry.partner(of: windowID(2)) == windowID(3))
        registry.reconcile(records: records, displays: displays, now: 3)
        #expect(registry.groups.isEmpty)
        // Window 1 leaves and comes back: detection applies again.
        registry.reconcile(records: [window(1, floating), window(2, half(.rightHalf, on: laptop))], displays: displays, now: 4)
        registry.reconcile(records: records, displays: displays, now: 5)
        #expect(registry.partner(of: windowID(1)) == windowID(2))
    }

    @Test func explicitPairingOverridesUngroupAndReplacesEarlierPairs() {
        var registry = paired()
        registry.ungroup(windowID(1))
        let records = [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: laptop)),
                       window(3, half(.leftHalf, on: external)), window(4, half(.rightHalf, on: external))]
        let formed = registry.form(windowID(2), windowID(1), records: records, displays: displays, now: 1)
        #expect(formed?.first == windowID(1) && formed?.second == windowID(2))
        registry.reconcile(records: records, displays: displays, now: 2)
        #expect(registry.groups.count == 2)
        // Self-pairs, minimized windows and non-complementary halves are refused.
        let result8 = registry.form(windowID(1), windowID(1), records: records, displays: displays, now: 3)
        #expect(result8 == nil)
        let result9 = registry.form(windowID(1), windowID(3), records: records, displays: displays, now: 3)
        #expect(result9 == nil)
        let result10 = registry.form(windowID(2), windowID(4), records: records, displays: displays, now: 3)
        #expect(result10 == nil)
    }

    @Test func freshPlacementFramesStandInForStaleRecordsUntilTheGraceExpires() {
        var registry = TileGroupRegistry()
        let left = half(.leftHalf, on: laptop), right = half(.rightHalf, on: laptop)
        // Both windows were just placed; the registry still has their old frames.
        registry.notePlacement(windowID(1), frame: left, now: 10)
        registry.notePlacement(windowID(2), frame: right, now: 10.1)
        let stale = [window(1, floating), window(2, floating)]
        let result11 = registry.form(windowID(1), windowID(2), records: stale, displays: displays, now: 10.2)
        #expect(result11 != nil)
        let result12 = registry.reconcile(records: stale, displays: displays, now: 10.5)
        #expect(!result12)
        // The records catch up: the pair stays.
        let fresh = [window(1, left), window(2, right)]
        let result13 = registry.reconcile(records: fresh, displays: displays, now: 10.6)
        #expect(!result13)
        // A placement that never shows up in the records expires.
        var expiring = TileGroupRegistry()
        expiring.notePlacement(windowID(1), frame: left, now: 0)
        expiring.notePlacement(windowID(2), frame: right, now: 0)
        expiring.reconcile(records: stale, displays: displays, now: 0.1)
        #expect(expiring.groups.count == 1)
        expiring.reconcile(records: stale, displays: displays, now: 0.1 + TileGroupRegistry.placementGrace + 0.1)
        #expect(expiring.groups.isEmpty)
    }

    @Test func roleClassificationCoversEveryHalf() {
        for role in TileGroupRole.allCases {
            let frame = half(role.zone, on: laptop)
            #expect(TileGroupRegistry.role(of: frame, on: laptop) == role)
            #expect(TileGroupRole(zone: role.zone) == role)
            #expect(role.complement.complement == role && role.complement.layout == role.layout)
        }
        #expect(TileGroupRegistry.role(of: half(.maximize, on: laptop), on: laptop) == nil)
        #expect(TileGroupRole(zone: .maximize) == nil)
    }

    private func paired() -> TileGroupRegistry {
        var registry = TileGroupRegistry()
        registry.reconcile(records: [window(1, half(.leftHalf, on: laptop)), window(2, half(.rightHalf, on: laptop))],
                           displays: displays, now: 0)
        return registry
    }
}
