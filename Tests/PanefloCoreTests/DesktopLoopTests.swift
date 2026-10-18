import Foundation
import Testing
@testable import PanefloCore

struct DesktopLoopTests {
    private let snapshot = WindowSnapshot(records: [record(1, title: "Browser"), record(2, title: "Editor"), record(3, title: "Notes")])
    private var w1: SwitchTarget { .window(windowID(1)) }
    private var w2: SwitchTarget { .window(windowID(2)) }
    private var w3: SwitchTarget { .window(windowID(3)) }

    @Test
    func testHiddenModeMatchesWindowOnlyLoop() {
        let session = SwitcherSession(snapshot: snapshot)
        #expect(session.orderedTargets == [w1, w2, w3])
        #expect(session.selectedTarget == w2)
        #expect(session.selectedID == windowID(2))
    }

    @Test
    func testDesktopIsLastStopOfTheLoopNormally() {
        var session = SwitcherSession(snapshot: snapshot, desktop: .trailing)
        #expect(session.orderedTargets == [w1, w2, w3, .desktop])
        #expect(session.orderedIDs == [windowID(1), windowID(2), windowID(3)])
        #expect(session.selectedTarget == w2)
        session.advance()
        session.advance()
        #expect(session.selectedTarget == .desktop)
        #expect(session.selectedID == nil)
        session.advance()
        #expect(session.selectedTarget == w1)
        session.advance(.backward)
        #expect(session.selectedTarget == .desktop)
    }

    @Test
    func testBackwardStartLandsOnDesktopWhenTrailing() {
        let session = SwitcherSession(snapshot: snapshot, direction: .backward, desktop: .trailing)
        #expect(session.selectedTarget == .desktop)
    }

    @Test
    func testDesktopSitsAtIndexOneWhenTheDesktopIsCurrent() {
        var session = SwitcherSession(snapshot: snapshot, desktop: .current)
        #expect(session.orderedTargets == [w1, .desktop, w2, w3])
        // Releasing immediately returns to the window the user left, not the Desktop.
        #expect(session.selectedTarget == w1)
        session.advance()
        #expect(session.selectedTarget == .desktop)
        let r1 = session.commitTarget()
        #expect(r1 == .desktop)
    }

    @Test
    func testCurrentDesktopCommitWithoutSteppingReturnsToLastWindow() {
        var session = SwitcherSession(snapshot: snapshot, desktop: .current)
        let r2 = session.commit()
        #expect(r2 == windowID(1))
    }

    @Test
    func testCurrentDesktopWithNoWindowsAndWithOneWindow() {
        let empty = SwitcherSession(snapshot: WindowSnapshot(records: []), desktop: .current)
        #expect(empty.orderedTargets == [.desktop])
        #expect(empty.selectedTarget == .desktop)
        let one = SwitcherSession(snapshot: WindowSnapshot(records: [record(1)]), desktop: .current)
        #expect(one.orderedTargets == [w1, .desktop])
        #expect(one.selectedTarget == w1)
    }

    @Test
    func testTrailingDesktopWithSingleWindowIsTheSecondStop() {
        let one = SwitcherSession(snapshot: WindowSnapshot(records: [record(1)]), desktop: .trailing)
        #expect(one.orderedTargets == [w1, .desktop])
        #expect(one.selectedTarget == .desktop)
    }

    @Test
    func testOrderStaysFrozenWhileTheRegistryChanges() {
        var registry = WindowRegistry()
        snapshot.records.forEach { _ = registry.upsert($0) }
        registry.commitFocus(windowID(1))
        var session = SwitcherSession(snapshot: registry.snapshot, desktop: .trailing)
        let frozen = session.orderedTargets
        registry.commitFocus(windowID(3))
        registry.upsert(record(4))
        session.advance()
        session.advance()
        #expect(session.orderedTargets == frozen)
        #expect(session.orderedTargets.last == .desktop)
        // Committing the Desktop emits an intent and does not touch the registry's MRU.
        let r3 = session.select(.desktop)
        #expect(r3)
        let r4 = session.commitTarget()
        #expect(r4 == .desktop)
        #expect(registry.snapshot.mostRecent.first == windowID(3))
    }

    @Test
    func testDesktopDisabledSettingKeepsDesktopOutOfTheLoop() {
        let suite = "desktop-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DesktopSettings(defaults: defaults)
        #expect(settings.showsDesktopEntry)
        #expect(!settings.usesSystemShowDesktop)
        #expect(settings.loopMode(desktopIsCurrent: false) == .trailing)
        #expect(settings.loopMode(desktopIsCurrent: true) == .current)
        settings.showsDesktopEntry = false
        #expect(settings.loopMode(desktopIsCurrent: true) == .hidden)
        var session = SwitcherSession(snapshot: snapshot, desktop: settings.loopMode(desktopIsCurrent: false))
        #expect(!session.orderedTargets.contains(.desktop))
        let r5 = session.select(.desktop)
        #expect(r5 == false)
    }

    @Test
    func testSearchMatchesDesktopByTitleOnly() {
        var session = SwitcherSession(snapshot: snapshot, desktop: .trailing)
        session.setSearchQuery("desk")
        #expect(session.filteredTargets == [.desktop])
        #expect(session.selectedTarget == .desktop)
        session.setSearchQuery("editor")
        #expect(session.filteredTargets == [w2])
        #expect(session.selectedTarget == w2)
        session.setSearchQuery("")
        #expect(session.filteredTargets.count == 4)
    }

    @Test
    func testRemovingTheSelectedWindowMovesToNeighbourIncludingDesktop() {
        var session = SwitcherSession(snapshot: WindowSnapshot(records: [record(1), record(2)]), desktop: .trailing)
        #expect(session.selectedTarget == .window(windowID(2)))
        session.remove(windowID(2))
        #expect(session.selectedTarget == .desktop)
        #expect(session.orderedTargets == [.window(windowID(1)), .desktop])
    }

    @Test
    func testRefreshKeepsDesktopModeAndSelection() {
        var session = SwitcherSession(snapshot: WindowSnapshot(records: []), desktop: .trailing)
        session.refresh(snapshot: snapshot)
        #expect(session.orderedTargets.last == .desktop)
        session.select(.desktop)
        session.refresh(snapshot: snapshot)
        #expect(session.selectedTarget == .desktop)
        #expect(session.desktopMode == .trailing)
    }

    @Test
    func testCancelledSessionIgnoresDesktopSelection() {
        var session = SwitcherSession(snapshot: snapshot, desktop: .trailing)
        session.cancel()
        let r6 = session.select(.desktop)
        #expect(r6 == false)
        let r7 = session.commitTarget()
        #expect(r7 == nil)
    }

    @Test
    func testDesktopMatchesUsesWindowSearchRules() {
        #expect(SwitcherSession.desktopMatches(""))
        #expect(SwitcherSession.desktopMatches("desk"))
        #expect(SwitcherSession.desktopMatches("DÉSKTOP"))
        #expect(!SwitcherSession.desktopMatches("document 12"))
        #expect(!SwitcherSession.desktopMatches("desk notes"))
    }
}
