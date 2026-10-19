import Foundation
import Testing
@testable import PanefloCore

struct SwitcherSessionTests {
    private let snapshot = WindowSnapshot(records: [record(1, title: "Browser"), record(2, title: "Editor"), record(3, title: "BROWSER research")])

    @Test
    func testSessionFreezesOrderAndCommitDoesNotMutateMRU() {
        var registry = WindowRegistry()
        snapshot.records.forEach { _ = registry.upsert($0) }
        registry.commitFocus(windowID(1))
        var session = SwitcherSession(snapshot: registry.snapshot)
        #expect(session.selectedID == windowID(2))
        registry.commitFocus(windowID(3))
        registry.upsert(record(4))
        #expect(session.orderedIDs == [windowID(1), windowID(2), windowID(3)])
        let outcome18 = session.commit() == windowID(2)
        #expect(outcome18)
        #expect(registry.snapshot.mostRecent == [windowID(3), windowID(1)])
        let outcome20 = session.commit() == nil
        #expect(outcome20)
        session.advance()
        #expect(session.selectedID == windowID(2))
    }

    @Test
    func testForwardReverseWrapAndCancel() {
        var session = SwitcherSession(snapshot: snapshot, direction: .backward)
        #expect(session.selectedID == windowID(3))
        session.advance(.forward)
        #expect(session.selectedID == windowID(1))
        session.advance(.backward)
        #expect(session.selectedID == windowID(3))
        session.cancel()
        let outcome34 = session.commit() == nil
        #expect(outcome34)
        #expect(session.status == .cancelled)
        let outcome36 = !(session.select(windowID(1)))
        #expect(outcome36)
    }

    @Test
    func testSearchKeepsRelativeOrderAndHandlesNoMatches() {
        var session = SwitcherSession(snapshot: snapshot)
        session.setSearchQuery("browser")
        #expect(session.filteredIDs == [windowID(1), windowID(3)])
        #expect(session.selectedID == windowID(1))
        session.advance()
        #expect(session.selectedID == windowID(3))
        session.setSearchQuery("")
        #expect(session.orderedIDs == [windowID(1), windowID(2), windowID(3)])
        #expect(session.selectedID == windowID(3))
        session.setSearchQuery("no such title")
        #expect(session.filteredIDs.isEmpty)
        #expect(session.selectedID == nil)
        session.advance()
        let outcome54 = session.commit() == nil
        #expect(outcome54)
    }

    @Test
    func testBlankQueryMatchesEverythingAndFoldingStillApplies() {
        var session = SwitcherSession(snapshot: snapshot)
        session.setSearchQuery("   ")
        #expect(session.filteredIDs == [windowID(1), windowID(2), windowID(3)])
        session.setSearchQuery("  BRÓWSER  rese ")
        #expect(session.filteredIDs == [windowID(3)])
        #expect(SwitcherSession.desktopMatches(""))
        #expect(SwitcherSession.desktopMatches(" dèsk "))
        #expect(!SwitcherSession.desktopMatches("browser"))
    }

    @Test
    func testExplicitRefreshSeedsAsyncDiscoveryAndPreservesQuerySelection() {
        var session = SwitcherSession(snapshot: WindowSnapshot(records: []))
        session.setSearchQuery("browser")
        session.refresh(snapshot: snapshot)
        #expect(session.filteredIDs == [windowID(1), windowID(3)])
        #expect(session.selectedID == windowID(1))
        session.select(windowID(3))
        session.refresh(snapshot: WindowSnapshot(records: snapshot.records + [record(4, title: "Browser new")], mostRecent: [windowID(4)]))
        #expect(session.searchQuery == "browser")
        #expect(session.selectedID == windowID(3))
        #expect(session.filteredIDs == [windowID(4), windowID(1), windowID(3)])
        session.refresh(snapshot: WindowSnapshot(records: [record(4, title: "Browser new")]))
        #expect(session.selectedID == windowID(4))
    }

    @Test
    func testRemovalPreservesNearestSelectionAndEmptyIsSafe() {
        var session = SwitcherSession(snapshot: snapshot)
        session.remove(windowID(2))
        #expect(session.selectedID == windowID(3))
        session.remove(windowID(1))
        #expect(session.selectedID == windowID(3))
        session.remove(windowID(3))
        #expect(session.selectedID == nil)
        session.advance(.backward)
        let outcome67 = session.commit() == nil
        #expect(outcome67)
    }

    @Test
    func testTilePairsSitSideBySideWithoutChangingTheQuickSwitchTarget() {
        let five = WindowSnapshot(records: (1...5).map { record(UInt32($0)) })
        // Windows 2 (right half) and 4 (left half) are a pair: they sit together where 2 stood, left first.
        let pair = TilePairMembers(first: windowID(4), second: windowID(2))
        var session = SwitcherSession(snapshot: five, pairs: [pair])
        #expect(session.orderedIDs == [windowID(1), windowID(4), windowID(2), windowID(3), windowID(5)])
        #expect(session.selectedID == windowID(2), "A quick press still returns to the previous window")
        #expect(session.pairStarts(in: session.orderedTargets) == [1])
        session.advance()
        #expect(session.selectedID == windowID(3))
        let backward = SwitcherSession(snapshot: five, direction: .backward, pairs: [pair])
        #expect(backward.selectedID == windowID(5))
        // The frontmost window's partner follows it; a Desktop that is current goes after the whole pair.
        let front = SwitcherSession(snapshot: five, desktop: .current, pairs: [TilePairMembers(first: windowID(1), second: windowID(3))])
        #expect(front.orderedTargets == [.window(windowID(1)), .window(windowID(3)), .desktop, .window(windowID(2)),
                                         .window(windowID(4)), .window(windowID(5))])
        #expect(front.selectedTarget == .window(windowID(1)))
        // Pairs with a missing member are ignored; a search that separates the members drops the pair start.
        let stale = SwitcherSession(snapshot: five, pairs: [TilePairMembers(first: windowID(9), second: windowID(2))])
        #expect(stale.orderedIDs == five.orderedRecords.map(\.id) && stale.pairs.isEmpty)
        #expect(session.pairStarts(in: [.window(windowID(4)), .window(windowID(3))]).isEmpty)
        #expect(SwitcherSession.arrange([windowID(1), windowID(2)], pairs: []) == [windowID(1), windowID(2)])
    }
}
