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
}
