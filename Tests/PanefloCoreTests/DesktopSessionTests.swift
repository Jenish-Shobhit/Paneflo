import Foundation
import Testing
@testable import PanefloCore

struct DesktopSessionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private var settled: Date { t0.addingTimeInterval(DesktopSession.settleInterval + 0.1) }
    private let finder: Int32 = 100
    private let paneflo: Int32 = 200

    private func session(hidden: Set<Int32> = [1, 2, 3]) -> DesktopSession {
        DesktopSession(generation: 1, startedAt: t0, hidden: hidden, protected: [finder, paneflo])
    }

    @Test
    func testPlanHidesOnlyVisibleRegularAppsOtherThanFinderAndPaneflo() {
        let running = [
            DesktopApp(pid: 3, bundleIdentifier: "b", isRegular: true),
            DesktopApp(pid: 1, bundleIdentifier: "a", isRegular: true),
            DesktopApp(pid: 100, bundleIdentifier: DesktopPlan.finderBundleIdentifier, isRegular: true),
            DesktopApp(pid: 200, bundleIdentifier: "dev.paneflo.Paneflo", isRegular: true),
            DesktopApp(pid: 4, bundleIdentifier: "agent", isRegular: false),
            DesktopApp(pid: 5, bundleIdentifier: "already", isRegular: true, isHidden: true),
            DesktopApp(pid: 6, bundleIdentifier: "dead", isRegular: true, isTerminated: true),
        ]
        #expect(DesktopPlan.appsToHide(running: running, excluding: [200]) == [1, 3])
    }

    @Test
    func testSessionNeverTracksProtectedApps() {
        let s = DesktopSession(generation: 1, startedAt: t0, hidden: [1, 100, 200], protected: [100, 200])
        #expect(s.hiddenPIDs == [1])
    }

    @Test
    func testRestoreForWindowUnhidesOnlyThatApp() {
        var s = session()
        #expect(s.isCurrent)
        let r1 = s.restore(for: 2)
        #expect(r1 == [2])
        #expect(s.hiddenPIDs == [1, 3])
        #expect(!s.isCurrent)
        #expect(s.isActive)
    }

    @Test
    func testRestoreForAppThatWasNotHiddenUnhidesNothingButLeavesTheDesktop() {
        var s = session()
        let r2 = s.restore(for: 99)
        #expect(r2.isEmpty)
        let r3 = s.restore(for: nil)
        #expect(r3.isEmpty)
        #expect(s.hiddenPIDs == [1, 2, 3])
        #expect(!s.isCurrent)
    }

    @Test
    func testRestoreAllReturnsEverythingAndEndsTheSession() {
        var s = session()
        _ = s.restore(for: 1)
        let r4 = s.restoreAll()
        #expect(r4 == [2, 3])
        #expect(s.hiddenPIDs.isEmpty)
        #expect(!s.isActive)
    }

    @Test
    func testUserUnhidingEverythingEndsTheSession() {
        var s = session()
        let r5 = s.apply(.didUnhide(pid: 1), at: settled)
        #expect(!r5)
        #expect(!s.isCurrent)
        let r6 = s.apply(.didUnhide(pid: 2), at: settled)
        #expect(!r6)
        let r7 = s.apply(.didActivate(pid: 3), at: settled)
        #expect(r7)
        #expect(s.hiddenPIDs.isEmpty)
    }

    @Test
    func testSignalsDuringSettleAreOurOwnSideEffects() {
        var s = session()
        let r8 = s.apply(.didActivate(pid: 1), at: t0.addingTimeInterval(0.1))
        #expect(!r8)
        let r9 = s.apply(.didUnhide(pid: 2), at: t0.addingTimeInterval(0.2))
        #expect(!r9)
        #expect(s.hiddenPIDs == [1, 2, 3])
        #expect(s.isCurrent)
    }

    @Test
    func testActivatingFinderOrPanefloKeepsTheDesktopCurrent() {
        var s = session()
        s.apply(.didActivate(pid: finder), at: settled)
        s.apply(.didActivate(pid: paneflo), at: settled)
        #expect(s.isCurrent)
        #expect(s.hiddenPIDs == [1, 2, 3])
    }

    @Test
    func testAppLaunchedWhileDesktopShownLeavesTheDesktopButKeepsHiddenSet() {
        var s = session()
        let r10 = s.apply(.didActivate(pid: 77), at: settled)
        #expect(!r10)
        #expect(!s.isCurrent)
        #expect(s.hiddenPIDs == [1, 2, 3])
    }

    @Test
    func testTerminationDropsAHiddenAppAndEndsEmptyNonCurrentSession() {
        var s = session(hidden: [1])
        s.apply(.didActivate(pid: 77), at: settled)
        let ended = s.apply(.didTerminate(pid: 1), at: t0)
        #expect(ended)
    }

    @Test
    func testRefusedAppsAreReportedAndNeverRestored() {
        var s = session()
        s.noteRefused([2])
        #expect(s.refusedPIDs == [2])
        let r11 = s.restoreAll()
        #expect(r11 == [1, 3])
    }

    @Test
    func testSecondShowDesktopMergesHiddenSetUnderNewGeneration() {
        var s = session(hidden: [1, 2])
        _ = s.restore(for: 1)
        let merged = s.merging(newlyHidden: [1, 4], generation: 2, at: settled)
        #expect(merged.generation == 2)
        #expect(merged.hiddenPIDs == [1, 2, 4])
        #expect(merged.isCurrent)
    }

    @Test
    func testEntryActionTogglesWhenDesktopIsCurrent() {
        var s = session()
        #expect(DesktopEntryAction.resolve(for: nil) == .show)
        #expect(DesktopEntryAction.resolve(for: s) == .restoreAll)
        _ = s.restore(for: 1)
        #expect(DesktopEntryAction.resolve(for: s) == .show)
    }

    @Test
    func testShowDesktopHotkeyResolution() {
        #expect(SystemShowDesktopHotkey.resolve(symbolicHotkeys: nil) == SystemShowDesktopHotkey.factoryDefault)
        #expect(SystemShowDesktopHotkey.resolve(symbolicHotkeys: [:]) == SystemShowDesktopHotkey.factoryDefault)
        let custom: [String: Any] = ["36": ["enabled": 1, "value": ["parameters": [65535, 100, 1_179_648], "type": "standard"]]]
        #expect(SystemShowDesktopHotkey.resolve(symbolicHotkeys: custom) == SystemHotkey(keyCode: 100, modifierMask: 1_179_648))
        let disabled: [String: Any] = ["36": ["enabled": 0, "value": ["parameters": [65535, 103, 8_388_608], "type": "standard"]]]
        #expect(SystemShowDesktopHotkey.resolve(symbolicHotkeys: disabled) == nil)
        let unassigned: [String: Any] = ["36": ["enabled": 1, "value": ["parameters": [65535, 65535, 0], "type": "standard"]]]
        #expect(SystemShowDesktopHotkey.resolve(symbolicHotkeys: unassigned) == nil)
        let malformed: [String: Any] = ["36": ["enabled": 1]]
        #expect(SystemShowDesktopHotkey.resolve(symbolicHotkeys: malformed) == nil)
    }
}
