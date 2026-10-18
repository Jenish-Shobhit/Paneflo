import Foundation
import Testing
@testable import PanefloCore

struct SnapAssistSessionTests {
    private let a = windowID(1), b = windowID(2), c = windowID(3)

    @Test func leftThenRightPairsOnTheAnchorsDisplay() {
        var assist = SnapAssistSession()
        let step1 = assist.willTile(a, zone: .leftHalf)
        #expect(step1 == .init())
        #expect(assist.pairingHint == "Pick a window for the right half — ⌘⌥→")
        let step2 = assist.didTile(a, zone: .leftHalf, display: 1)
        #expect(step2 == nil)
        #expect(assist.pairingHint != nil)
        let request = assist.willTile(b, zone: .rightHalf)
        #expect(request == .init(explicitDisplay: 1, pairsWith: a))
        #expect(assist.pairingHint == nil)
        #expect(assist.pendingPartner(for: b) == a && assist.pendingPartner(for: a) == b && assist.pendingPartner(for: c) == nil)
        let formation = assist.didTile(b, zone: .rightHalf, display: 1)
        #expect(formation == .init(first: a, second: b, display: 1))
        #expect(assist.anchor == nil && assist.partner == nil && assist.pairingHint == nil)
    }

    @Test func rightThenLeftPairsWithTheLeftWindowFirst() {
        var assist = SnapAssistSession()
        _ = assist.willTile(a, zone: .rightHalf)
        #expect(assist.pairingHint == "Pick a window for the left half — ⌘⌥←")
        _ = assist.didTile(a, zone: .rightHalf, display: 0)
        let step3 = assist.willTile(b, zone: .leftHalf)
        #expect(step3.pairsWith == a)
        let step4 = assist.didTile(b, zone: .leftHalf, display: 0)
        #expect(step4 == .init(first: b, second: a, display: 0))
    }

    @Test func aFastSecondPressBeforeTheFirstPlacementReportsStillPairs() {
        var assist = SnapAssistSession()
        _ = assist.willTile(a, zone: .leftHalf)
        // The anchor's display is not known yet: the partner goes on its own display.
        let step5 = assist.willTile(b, zone: .rightHalf)
        #expect(step5 == .init(explicitDisplay: nil, pairsWith: a))
        let step6 = assist.didTile(b, zone: .rightHalf, display: 0)
        #expect(step6 == nil)
        let step7 = assist.didTile(a, zone: .leftHalf, display: 0)
        #expect(step7 == .init(first: a, second: b, display: 0))
    }

    @Test func halvesThatLandOnDifferentDisplaysDoNotPair() {
        var assist = SnapAssistSession()
        _ = assist.willTile(a, zone: .leftHalf)
        _ = assist.willTile(b, zone: .rightHalf)
        _ = assist.didTile(a, zone: .leftHalf, display: 0)
        let step8 = assist.didTile(b, zone: .rightHalf, display: 1)
        #expect(step8 == nil)
        #expect(assist.anchor == nil && assist.pairingHint == nil)
    }

    @Test func escapeOrSessionEndClearsTheHint() {
        var assist = SnapAssistSession()
        _ = assist.willTile(a, zone: .leftHalf)
        #expect(assist.pairingHint != nil)
        assist.reset()
        #expect(assist.pairingHint == nil)
        // A late placement report for a reset session forms nothing.
        let step9 = assist.didTile(a, zone: .leftHalf, display: 0)
        #expect(step9 == nil)
        let step10 = assist.willTile(b, zone: .rightHalf)
        #expect(step10 == .init())
    }

    @Test func tilingTheSameWindowTwiceNeverPairsItWithItself() {
        var assist = SnapAssistSession()
        _ = assist.willTile(a, zone: .leftHalf)
        _ = assist.didTile(a, zone: .leftHalf, display: 0)
        let step11 = assist.willTile(a, zone: .rightHalf)
        #expect(step11 == .init())
        #expect(assist.anchor?.id == a && assist.anchor?.zone == .rightHalf && assist.partner == nil)
        #expect(assist.pairingHint == "Pick a window for the left half — ⌘⌥←")
        let step12 = assist.didTile(a, zone: .rightHalf, display: 0)
        #expect(step12 == nil)
        let step13 = assist.willTile(a, zone: .rightHalf)
        #expect(step13 == .init())
        let step14 = assist.didTile(a, zone: .rightHalf, display: 0)
        #expect(step14 == nil)
    }

    @Test func theSameHalfForAnotherWindowStartsOver() {
        var assist = SnapAssistSession()
        _ = assist.willTile(a, zone: .leftHalf)
        _ = assist.willTile(b, zone: .leftHalf)
        #expect(assist.anchor?.id == b)
        let step15 = assist.willTile(c, zone: .rightHalf)
        #expect(step15.pairsWith == b)
    }

    @Test func fillScreenUndoAndFailedPlacementsAbandonTheirPart() {
        var fill = SnapAssistSession()
        _ = fill.willTile(a, zone: .leftHalf)
        _ = fill.willTile(c, zone: .maximize)
        #expect(fill.anchor?.id == a, "Filling an unrelated window keeps the anchor")
        _ = fill.willTile(a, zone: .maximize)
        #expect(fill.anchor == nil)

        var undo = SnapAssistSession()
        _ = undo.willTile(a, zone: .leftHalf)
        undo.willRestore(b)
        #expect(undo.anchor != nil)
        undo.willRestore(a)
        #expect(undo.anchor == nil)

        var failedAnchor = SnapAssistSession()
        _ = failedAnchor.willTile(a, zone: .leftHalf)
        let step16 = failedAnchor.didTile(a, zone: .leftHalf, display: nil)
        #expect(step16 == nil)
        #expect(failedAnchor.pairingHint == nil)

        var failedPartner = SnapAssistSession()
        _ = failedPartner.willTile(a, zone: .leftHalf)
        _ = failedPartner.didTile(a, zone: .leftHalf, display: 0)
        _ = failedPartner.willTile(b, zone: .rightHalf)
        let step17 = failedPartner.didTile(b, zone: .rightHalf, display: nil)
        #expect(step17 == nil)
        #expect(failedPartner.pairingHint != nil, "The anchor waits for another window")
        let step18 = failedPartner.willTile(c, zone: .rightHalf)
        #expect(step18.pairsWith == a)
    }
}

@MainActor
private final class RecordingExecutor: PairActivationExecutor {
    var log: [String] = []
    var heldRaise: (@MainActor () -> Void)?
    var completesRaiseImmediately = true
    func raiseWithoutFocus(_ id: WindowIdentity, completion: @escaping @MainActor () -> Void) {
        log.append("raise \(id.number)")
        if completesRaiseImmediately { completion() } else { heldRaise = completion }
    }
    func focus(_ id: WindowIdentity) { log.append("focus \(id.number)") }
}

@MainActor
private final class Timers {
    var pending: [(Double, @MainActor () -> Void)] = []
    func schedule(_ delay: Double, _ block: @escaping @MainActor () -> Void) { pending.append((delay, block)) }
    func fireAll() { let blocks = pending; pending.removeAll(); for (_, block) in blocks { block() } }
}

@MainActor
struct PairActivationTests {
    private let target = windowID(1), partner = windowID(2)

    @Test func partnerIsRaisedBeforeTheTargetIsFocused() {
        let executor = RecordingExecutor(), timers = Timers()
        PairActivator.open(target, partner: partner, executor: executor, schedule: timers.schedule)
        #expect(executor.log == ["raise 2", "focus 1"])
        #expect(timers.pending.count == 1 && timers.pending[0].0 == PairActivation.raiseDeadline)
        timers.fireAll()
        #expect(executor.log == ["raise 2", "focus 1"], "Focus is issued once")
    }

    @Test func focusWaitsForASlowRaiseOnlyUntilTheDeadline() {
        let executor = RecordingExecutor(), timers = Timers()
        executor.completesRaiseImmediately = false
        PairActivator.open(target, partner: partner, executor: executor, schedule: timers.schedule)
        #expect(executor.log == ["raise 2"])
        timers.fireAll()
        #expect(executor.log == ["raise 2", "focus 1"])
        executor.heldRaise?()
        #expect(executor.log == ["raise 2", "focus 1"])
    }

    @Test func aWindowWithoutPartnerIsFocusedAtOnce() {
        let executor = RecordingExecutor(), timers = Timers()
        PairActivator.open(target, partner: nil, executor: executor, schedule: timers.schedule)
        #expect(executor.log == ["focus 1"] && timers.pending.isEmpty)
        PairActivator.open(target, partner: target, executor: executor, schedule: timers.schedule)
        #expect(executor.log == ["focus 1", "focus 1"], "A window is never its own partner")
    }

    @Test func partnerChoiceFollowsTheSettingAndExplicitOpenPair() {
        var groups = TileGroupRegistry()
        let laptop = DisplayArea(frame: WindowRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: WindowRect(x: 0, y: 37, width: 1512, height: 875), backingScale: 2)
        func half(_ zone: LayoutZone) -> WindowRect { LayoutEngine.plan(zone: zone, in: laptop.visibleFrame, gap: 8, backingScale: 2).rect! }
        let records = [WindowRecord(id: target, appIdentifier: "a", appName: "A", title: "T", frame: half(.leftHalf)),
                       WindowRecord(id: partner, appIdentifier: "b", appName: "B", title: "P", frame: half(.rightHalf))]
        groups.reconcile(records: records, displays: [laptop], now: 0)
        #expect(PairActivation.partner(for: target, groups: groups, raiseTogether: true) == partner)
        #expect(PairActivation.partner(for: target, groups: groups, raiseTogether: false) == nil)
        #expect(PairActivation.partner(for: target, groups: groups, raiseTogether: false, explicit: true) == partner)
        // A snap-assist half still being placed stands in until the pair forms.
        let other = windowID(9)
        #expect(PairActivation.partner(for: other, groups: groups, pending: target, raiseTogether: true) == target)
        #expect(PairActivation.partner(for: other, groups: groups, pending: other, raiseTogether: true) == nil)
        #expect(PairActivation.partner(for: other, groups: groups, raiseTogether: true) == nil)
    }
}
