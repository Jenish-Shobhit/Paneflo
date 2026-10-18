import Foundation
import Testing
@testable import PanefloCore

/// Pair replacement, swap and size-limited pairing: one test per decidable row of the v1.1 tiling-pairs matrix.
/// Start state in most tests: A (1) left, B (2) right, paired on the laptop; C (3) floating.
struct TileReplacementTests {
    private let laptop = DisplayArea(frame: WindowRect(x: 0, y: 0, width: 1512, height: 982),
                                     visibleFrame: WindowRect(x: 0, y: 37, width: 1512, height: 875), backingScale: 2)
    private let external = DisplayArea(frame: WindowRect(x: 1512, y: -98, width: 1920, height: 1080),
                                       visibleFrame: WindowRect(x: 1512, y: -73, width: 1920, height: 1055), backingScale: 1)
    private var displays: [DisplayArea] { [laptop, external] }
    private let floating = WindowRect(x: 200, y: 200, width: 640, height: 480)
    private let a = windowID(1), b = windowID(2), c = windowID(3), e = windowID(5)

    private func half(_ zone: LayoutZone, on display: DisplayArea) -> WindowRect {
        LayoutEngine.plan(zone: zone, in: display.visibleFrame, gap: 8, backingScale: display.backingScale).rect!
    }

    private func window(_ id: WindowIdentity, _ frame: WindowRect, minimized: Bool = false, app: String = "example.app") -> WindowRecord {
        WindowRecord(id: id, appIdentifier: app, appName: "Example", title: "Window", frame: frame, isMinimized: minimized)
    }

    /// A left, B right (paired), C floating; records in MRU order C, A, B.
    private func start(c cFrame: WindowRect? = nil) -> (TileGroupRegistry, [WindowRecord]) {
        var registry = TileGroupRegistry()
        let records = [window(c, cFrame ?? floating), window(a, half(.leftHalf, on: laptop)), window(b, half(.rightHalf, on: laptop))]
        registry.reconcile(records: records, displays: displays, now: 0)
        #expect(registry.partner(of: a) == b)
        return (registry, records)
    }

    private func land(_ id: WindowIdentity, _ zone: LayoutZone, on index: Int = 0, frame: WindowRect? = nil) -> TileLanding {
        let rect = half(zone == .maximize ? .maximize : zone, on: displays[index])
        return TileLanding(window: id, zone: zone, display: index, frame: frame ?? rect, requested: rect)
    }

    // MARK: Rows 1–3, 12: replacement and the displaced member

    @Test func tilingIntoAPairedHalfReplacesThatMemberAndKeepsItsFrameWithoutAHome() {
        var (registry, records) = start()
        let result = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && result.displaced == a)
        #expect(result.group?.first == c && result.group?.second == b)
        #expect(registry.partner(of: b) == c && registry.group(containing: a) == nil)
        #expect(result.dissolved == [TilePairMembers(first: a, second: b)])
        // No known home: A keeps its frame (no invented size, no minimize, no other display).
        #expect(result.moves.isEmpty)
        // The next snapshot keeps C+B even though A still sits behind C in the left half.
        records[0] = window(c, half(.leftHalf, on: laptop))
        registry.reconcile(records: records, displays: displays, now: 2)
        #expect(registry.partner(of: b) == c && registry.groups.count == 1)
    }

    @Test func aDisplacedMemberGoesBackToItsHomeFrameAfterTheNewWindowLands() {
        var (registry, records) = start()
        var homes = TileHomeFrames()
        let home = WindowRect(x: 300, y: 150, width: 700, height: 500)
        homes.note(a, before: home, displays: displays)
        let result = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1, homes: homes)
        #expect(result.kind == .replaced)
        #expect(result.moves == [TileMove(window: a, frame: home, display: 0, reason: .restoreDisplaced)])
        // The planned frame stands in at once: A no longer counts as in the left half.
        records[0] = window(c, half(.leftHalf, on: laptop))
        registry.reconcile(records: records, displays: displays, now: 1.2)
        #expect(registry.partner(of: c) == b && registry.group(containing: a) == nil)
    }

    @Test func homeFramesKeepOnlyFloatingFramesAndRefuseOffscreenRestores() {
        var homes = TileHomeFrames()
        homes.note(a, before: half(.leftHalf, on: laptop), displays: displays)
        homes.note(a, before: half(.maximize, on: laptop), displays: displays)
        #expect(homes.frame(for: a) == nil)
        homes.note(a, before: floating, displays: displays)
        homes.note(a, before: half(.rightHalf, on: laptop), displays: displays)
        #expect(homes.frame(for: a) == floating)
        // A snapshot updates a floating window's home and forgets closed windows.
        let moved = WindowRect(x: 50, y: 90, width: 500, height: 400)
        homes.observe([window(a, moved), window(b, half(.rightHalf, on: laptop))], displays: displays)
        #expect(homes.frame(for: a) == moved && homes.frame(for: b) == nil)
        homes.observe([], displays: displays)
        #expect(homes.frame(for: a) == nil)
        // A home on a display that is gone is not restored.
        var gone = TileHomeFrames()
        gone.note(a, before: WindowRect(x: 1600, y: 100, width: 600, height: 400), displays: displays)
        #expect(gone.restoreTarget(for: a, displays: displays) != nil)
        #expect(gone.restoreTarget(for: a, displays: [laptop]) == nil)
    }

    // MARK: Row 4: another display

    @Test func aWindowLandingOnAnotherDisplayNeverReplacesThisDisplaysPair() {
        var (registry, records) = start(c: WindowRect(x: 1700, y: 100, width: 600, height: 400))
        let result = registry.resolve(land(c, .leftHalf, on: 1), records: records, displays: displays, now: 1)
        #expect(result.kind == .unpaired && registry.partner(of: a) == b)
        // Cycled onto the laptop (a repeated press), it replaces A there.
        records[0] = window(c, half(.leftHalf, on: external))
        let cycled = registry.resolve(land(c, .leftHalf, on: 0), records: records, displays: displays, now: 2)
        #expect(cycled.kind == .replaced && registry.partner(of: b) == c)
    }

    // MARK: Row 5: the incoming window was in another pair

    @Test func aWindowFromAnotherPairLeavesItAndItsOldPartnerStaysPut() {
        var registry = TileGroupRegistry()
        let records = [window(c, half(.leftHalf, on: external)), window(e, half(.rightHalf, on: external)),
                       window(a, half(.leftHalf, on: laptop)), window(b, half(.rightHalf, on: laptop))]
        registry.reconcile(records: records, displays: displays, now: 0)
        #expect(registry.groups.count == 2)
        let result = registry.resolve(land(c, .leftHalf, on: 0), records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && registry.partner(of: c) == b)
        #expect(registry.group(containing: e) == nil && !result.moves.contains { $0.window == e })
        #expect(Set(result.dissolved) == [TilePairMembers(first: c, second: e), TilePairMembers(first: a, second: b)])
    }

    // MARK: Row 6: minimized incoming window

    @Test func aMinimizedWindowThatWasJustPlacedPairs() {
        var (registry, records) = start()
        records[0] = window(c, floating, minimized: true)
        let result = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && registry.partner(of: b) == c)
        // The placement frame stands in for the stale minimized record until the record catches up.
        registry.reconcile(records: records, displays: displays, now: 1.2)
        #expect(registry.partner(of: b) == c)
    }

    // MARK: Row 10: same app

    @Test func sameAppWindowsReplaceLikeAnyOther() {
        var registry = TileGroupRegistry()
        let records = [window(c, floating, app: "one.app"), window(a, half(.leftHalf, on: laptop), app: "one.app"),
                       window(b, half(.rightHalf, on: laptop), app: "one.app")]
        registry.reconcile(records: records, displays: displays, now: 0)
        let result = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && registry.partner(of: c) == b)
    }

    // MARK: Row 11: swap

    @Test func tilingAMemberIntoItsPartnersHalfSwapsThemAtRequestTime() {
        var (registry, records) = start()
        let planned = registry.plannedSwap(for: a, zone: .rightHalf, records: records, displays: displays, now: 1)
        #expect(planned == TileMove(window: b, frame: half(.leftHalf, on: laptop), display: 0, zone: .leftHalf, reason: .swap))
        // The coordinator notes the partner's planned frame; A then lands right.
        registry.notePlacement(b, frame: planned!.frame, now: 1)
        let result = registry.resolve(land(a, .rightHalf), records: records, displays: displays, now: 1.05)
        #expect(result.kind == .swapped && result.moves.isEmpty)
        #expect(result.group?.first == b && result.group?.second == a)
        #expect(result.dissolved == [TilePairMembers(first: a, second: b)])
        // Records catch up: the swapped pair stays.
        records = [window(c, floating), window(a, half(.rightHalf, on: laptop)), window(b, half(.leftHalf, on: laptop))]
        registry.reconcile(records: records, displays: displays, now: 2)
        #expect(registry.groups.first?.first == b)
    }

    @Test func aSwapResolvedOnlyAtLandingMovesThePartnerItself() {
        var (registry, records) = start()
        let result = registry.resolve(land(a, .rightHalf), records: records, displays: displays, now: 1)
        #expect(result.kind == .swapped)
        #expect(result.moves == [TileMove(window: b, frame: half(.leftHalf, on: laptop), display: 0, zone: .leftHalf, reason: .swap)])
        // A partner with its own placement in flight is never moved by a follow-up.
        var (busyRegistry, _) = start()
        let busy = busyRegistry.resolve(land(a, .rightHalf), records: records, displays: displays, now: 1, busy: [b])
        #expect(busy.moves.isEmpty && busy.kind == .left)
        records.removeAll()
    }

    @Test func noSwapIsPlannedWhenTheWindowWouldLandOnAnotherDisplay() {
        let (registry, records) = start()
        #expect(registry.plannedSwap(for: a, zone: .rightHalf, records: records, displays: displays, explicitDisplay: 1, now: 1) == nil)
        #expect(registry.plannedSwap(for: a, zone: .leftHalf, records: records, displays: displays, now: 1) == nil)
        #expect(registry.plannedSwap(for: c, zone: .rightHalf, records: records, displays: displays, now: 1) == nil)
    }

    // MARK: Row 13: own side again

    @Test func tilingAMemberOntoItsOwnSideLeavesThePairAlone() {
        var (registry, records) = start()
        let id = registry.groups[0].id
        let result = registry.resolve(land(b, .rightHalf), records: records, displays: displays, now: 1)
        #expect(result.kind == .unchanged && result.moves.isEmpty && result.dissolved.isEmpty)
        #expect(registry.groups.count == 1 && registry.groups[0].id == id)
        // With a display in that direction the repeat moves on (documented cycling): B leaves, A stays.
        records[2] = window(b, half(.rightHalf, on: laptop))
        let cycled = registry.resolve(land(b, .rightHalf, on: 1), records: records, displays: displays, now: 2)
        #expect(cycled.kind == .left && cycled.dissolved == [TilePairMembers(first: a, second: b)] && cycled.moves.isEmpty)
    }

    // MARK: Row 14: Fill

    @Test func fillingAMemberDissolvesThePairAndLeavesThePartnerUntouched() {
        var (registry, records) = start()
        let result = registry.resolve(land(a, .maximize), records: records, displays: displays, now: 1)
        #expect(result.kind == .left && result.moves.isEmpty && registry.groups.isEmpty)
        #expect(result.dissolved == [TilePairMembers(first: a, second: b)])
        // Not an ungroup: once A is back in its half the pair is detected again.
        records[1] = window(a, half(.leftHalf, on: laptop))
        registry.reconcile(records: records, displays: displays, now: 5)
        #expect(registry.partner(of: a) == b)
    }

    // MARK: Row 15: undo

    @Test func undoOfAReplacementRestoresEveryWindowAndReformsThePair() {
        var history = GeometryUndoHistory()
        let left = half(.leftHalf, on: laptop), home = WindowRect(x: 300, y: 150, width: 700, height: 500)
        // The tile of C, then the displaced A's restore joins the same operation, with the pair it ended.
        history.record([GeometryChange(id: c, before: floating, after: left)], operation: 7)
        history.attach(pairs: [TilePairMembers(first: a, second: b)], to: 7)
        history.record([GeometryChange(id: a, before: left, after: home)], operation: 7)
        history.record([GeometryChange(id: e, before: floating, after: left)], operation: 8)
        let plan = history.undo(window: c, surviving: [a, b, c, e])
        #expect(plan?.changes.map(\.id) == [c, a] && plan?.changes.map(\.before) == [floating, left])
        #expect(plan?.pairs == [TilePairMembers(first: a, second: b)])
        #expect(history.hasHistory(for: e) && !history.hasHistory(for: a))
        // The registry re-forms the pair once both are back (the restore frames stand in).
        var (registry, records) = start()
        registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1)
        records[0] = window(c, left)
        registry.notePlacement(c, frame: floating, now: 2)
        registry.notePlacement(a, frame: left, now: 2)
        let formed = registry.restore(plan!.pairs, records: records, displays: displays, now: 2)
        #expect(formed.count == 1 && registry.partner(of: a) == b && registry.group(containing: c) == nil)
        // A closed member is skipped, and nothing forms.
        var other = GeometryUndoHistory()
        other.record([GeometryChange(id: c, before: floating, after: left)], operation: 1)
        other.record([GeometryChange(id: a, before: left, after: home)], operation: 1)
        let partial = other.undo(window: c, surviving: [c])
        #expect(partial?.changes.map(\.id) == [c] && partial?.skipped == [a])
    }

    @Test func mergedChangesKeepTheFirstBeforeAndPairsAloneNeverTakeAnUndoStep() {
        var history = GeometryUndoHistory()
        let f0 = WindowRect(x: 0, y: 0, width: 100, height: 100), f1 = WindowRect(x: 5, y: 0, width: 100, height: 100)
        let f2 = WindowRect(x: 9, y: 0, width: 100, height: 100)
        history.record([GeometryChange(id: a, before: f0, after: f1)], operation: 3)
        history.record([GeometryChange(id: a, before: f1, after: f2)], operation: 3)
        history.attach(pairs: [TilePairMembers(first: a, second: b)], to: 4)
        #expect(history.count == 1)
        let plan = history.undo(surviving: [a])
        #expect(plan?.changes == [GeometryChange(id: a, before: f0, after: f2)] && plan?.pairs.isEmpty == true)
        #expect(history.undo(surviving: [a]) == nil)
        // Pairs attached before the operation's first change join it when it records one.
        history.attach(pairs: [TilePairMembers(first: a, second: b)], to: 5)
        history.record([GeometryChange(id: a, before: f0, after: f1)], operation: 5)
        #expect(history.undo(window: a, surviving: [a])?.pairs == [TilePairMembers(first: a, second: b)])
    }

    // MARK: Row 16: manual drag or resize

    @Test func draggingOneMemberDissolvesButResizingTheSharedEdgeKeepsThePair() {
        var (registry, records) = start()
        let left = half(.leftHalf, on: laptop), right = half(.rightHalf, on: laptop)
        // Both resized together along the seam (macOS tiled resize): still complementary.
        let wideLeft = WindowRect(x: left.x, y: left.y, width: left.width + 200, height: left.height)
        let narrowRight = WindowRect(x: right.x + 200, y: right.y, width: right.width - 200, height: right.height)
        records[1] = window(a, wideLeft); records[2] = window(b, narrowRight)
        registry.reconcile(records: records, displays: displays, now: 1)
        #expect(registry.partner(of: a) == b)
        // One member resized alone: a 200 pt overlap breaks the seam, and Paneflo moves nothing.
        records[2] = window(b, right)
        let changed = registry.reconcile(records: records, displays: displays, now: 2)
        #expect(changed && registry.groups.isEmpty)
    }

    // MARK: Row 17: a member closes mid-operation

    @Test func aPartnerThatClosedBeforeTheLandingIsNotReplacedAndNothingIsDisplaced() {
        var (registry, records) = start()
        var homes = TileHomeFrames()
        homes.note(a, before: floating, displays: displays)
        records.removeLast() // B closed
        registry.reconcile(records: records, displays: displays, now: 0.5)
        let result = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1, homes: homes)
        #expect(result.kind == .unpaired && result.moves.isEmpty && result.displaced == nil)
        // The displaced member closed instead: replacement still pairs, no move for the closed window.
        var (second, all) = start()
        all.remove(at: 1) // A closed, its pair is still recorded until the next reconcile
        let replaced = second.resolve(land(c, .leftHalf), records: all, displays: displays, now: 1, homes: homes)
        #expect(replaced.kind == .replaced && replaced.moves.isEmpty && second.partner(of: b) == c)
    }

    // MARK: Rows 18–19: supersession and rapid replacements

    @Test func aDisplacedMemberWithItsOwnPlacementInFlightIsNotMoved() {
        var (registry, records) = start()
        var homes = TileHomeFrames()
        homes.note(a, before: floating, displays: displays)
        let result = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1, busy: [a], homes: homes)
        #expect(result.kind == .replaced && result.moves.isEmpty)
        records.removeAll()
    }

    @Test func rapidReplacementsEndWithTheLastCommand() {
        var (registry, records) = start()
        let d = windowID(4)
        records.insert(window(d, WindowRect(x: 400, y: 300, width: 500, height: 400)), at: 0)
        var homes = TileHomeFrames()
        homes.observe(records, displays: displays)
        let first = registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1, homes: homes)
        #expect(first.displaced == a)
        let second = registry.resolve(land(d, .leftHalf), records: records, displays: displays, now: 1.1, homes: homes)
        #expect(second.kind == .replaced && second.displaced == c && registry.partner(of: b) == d)
        #expect(second.moves == [TileMove(window: c, frame: floating, display: 0, reason: .restoreDisplaced)])
        #expect(registry.groups.count == 1)
    }

    // MARK: Rows 20, 26: neighbours and snap assist

    @Test func tilingNextToAnUnpairedWindowPairsAtOnceAndPrefersTheSnapAnchor() {
        var registry = TileGroupRegistry()
        let d = windowID(4)
        let records = [window(c, floating), window(d, half(.leftHalf, on: laptop)), window(a, half(.leftHalf, on: laptop))]
        registry.reconcile(records: records, displays: displays, now: 0)
        #expect(registry.groups.isEmpty)
        let plain = registry.resolve(land(c, .rightHalf), records: records, displays: displays, now: 1)
        #expect(plain.kind == .formed && registry.partner(of: c) == d)
        var snapped = TileGroupRegistry()
        snapped.resolve(land(c, .rightHalf), records: records, displays: displays, now: 1, preferredPartner: a)
        #expect(snapped.partner(of: c) == a)
        // An explicit arrangement overrides an earlier Ungroup of the same two windows.
        registry.ungroup(c)
        let again = registry.resolve(land(c, .rightHalf), records: records, displays: displays, now: 2)
        #expect(again.kind == .formed && registry.partner(of: c) == d)
    }

    // MARK: Row 21: display sizes and scales

    @Test func replacementWorksOnA1xExternalDisplayNextToA2xLaptop() {
        var registry = TileGroupRegistry()
        let records = [window(c, WindowRect(x: 1600, y: 0, width: 500, height: 400)),
                       window(a, half(.topHalf, on: external)), window(b, half(.bottomHalf, on: external))]
        registry.reconcile(records: records, displays: displays, now: 0)
        #expect(registry.partner(of: a) == b)
        let result = registry.resolve(land(c, .bottomHalf, on: 1), records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && result.displaced == b && registry.groups.first?.first == a)
    }

    // MARK: Row 23: size limits

    @Test func aWindowWithAMinimumWidthKeepsItAndThePartnerTakesTheRest() {
        var (registry, records) = start()
        let left = half(.leftHalf, on: laptop)
        // C accepts no less than 900 pt: placed at the left half's origin, it overlaps B.
        let wide = WindowRect(x: left.x, y: left.y, width: 900, height: left.height)
        let result = registry.resolve(TileLanding(window: c, zone: .leftHalf, display: 0, frame: wide, requested: left),
                                      records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && result.group?.first == c && result.group?.second == b)
        let rest = try! #require(result.moves.first { $0.reason == .remainder })
        #expect(rest.window == b && rest.frame.x == wide.maxX + 8 && rest.frame.maxX == half(.rightHalf, on: laptop).maxX)
        // Validated by the seam rule on the next snapshot.
        records[0] = window(c, wide); records[2] = window(b, rest.frame)
        registry.reconcile(records: records, displays: displays, now: 3)
        #expect(registry.partner(of: c) == b)
    }

    @Test func aWindowWithAMaximumWidthMovesToItsEdgeAndThePartnerGrows() {
        var (registry, records) = start()
        let left = half(.leftHalf, on: laptop)
        // C stays at most 500 pt wide and was centred in the half.
        let narrow = WindowRect(x: left.x + (left.width - 500) / 2, y: left.y, width: 500, height: left.height)
        let result = registry.resolve(TileLanding(window: c, zone: .leftHalf, display: 0, frame: narrow, requested: left),
                                      records: records, displays: displays, now: 1)
        #expect(result.group?.first == c)
        #expect(result.moves.map(\.reason) == [.alignEdge, .remainder])
        #expect(result.moves[0].frame.x == left.x && result.moves[1].frame.x == left.x + 500 + 8)
        records.removeAll()
    }

    @Test func noPairWhenTheRemainderIsTooSmallOrBothMembersAreLimited() {
        var (registry, records) = start()
        let left = half(.leftHalf, on: laptop)
        let huge = WindowRect(x: left.x, y: left.y, width: 1350, height: left.height)
        let result = registry.resolve(TileLanding(window: c, zone: .leftHalf, display: 0, frame: huge, requested: left),
                                      records: records, displays: displays, now: 1)
        #expect(result.kind == .replaced && result.group == nil && result.moves.isEmpty)
        // A short window (height-limited) does not span the display: no pair, no moves.
        var (second, all) = start()
        let short = WindowRect(x: left.x, y: left.y + 100, width: left.width, height: 400)
        let limited = second.resolve(TileLanding(window: c, zone: .leftHalf, display: 0, frame: short, requested: left),
                                     records: all, displays: displays, now: 1)
        #expect(limited.group == nil && limited.moves.isEmpty)
        records.removeAll(); all.removeAll()
    }

    // MARK: Row 24: raise together follows the new pair

    @Test func openingTheNewWindowRaisesItsNewPartnerNotTheDisplacedOne() {
        var (registry, records) = start()
        registry.resolve(land(c, .leftHalf), records: records, displays: displays, now: 1)
        #expect(PairActivation.partner(for: c, groups: registry, raiseTogether: true) == b)
        #expect(PairActivation.partner(for: b, groups: registry, raiseTogether: true) == c)
        #expect(PairActivation.partner(for: a, groups: registry, raiseTogether: true) == nil)
        records.removeAll()
    }

    // MARK: Seam rule

    @Test func complementAcceptsHalvesAndSeamsAndRejectsGapsSliversAndOtherDisplays() {
        let left = half(.leftHalf, on: laptop), right = half(.rightHalf, on: laptop)
        #expect(TileGroupRegistry.complement(left, right, on: laptop)?.layout == .leftRight)
        #expect(TileGroupRegistry.complement(right, left, on: laptop)?.aIsFirst == false)
        let top = half(.topHalf, on: laptop), bottom = half(.bottomHalf, on: laptop)
        #expect(TileGroupRegistry.complement(bottom, top, on: laptop).map { $0.layout == .topBottom && !$0.aIsFirst } == true)
        // A 100 pt gap between them, a sliver, or windows on the other display do not complement.
        let shifted = WindowRect(x: right.x + 100, y: right.y, width: right.width - 100, height: right.height)
        #expect(TileGroupRegistry.complement(left, shifted, on: laptop) == nil)
        let sliver = WindowRect(x: left.x, y: left.y, width: 150, height: left.height)
        let rest = WindowRect(x: 158, y: right.y, width: right.maxX - 158, height: right.height)
        #expect(TileGroupRegistry.complement(sliver, rest, on: laptop) == nil)
        #expect(TileGroupRegistry.complement(half(.leftHalf, on: external), half(.rightHalf, on: external), on: laptop) == nil)
    }
}
