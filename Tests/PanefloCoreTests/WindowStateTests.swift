import Foundation
import Testing
@testable import PanefloCore

func windowID(_ number: UInt32, incarnation: UInt64 = 1, launch: UInt64 = 1, pid: Int32 = 7) -> WindowIdentity {
    WindowIdentity(process: ProcessIdentity(pid: pid, launchToken: launch), number: number, incarnation: incarnation)
}

func record(_ number: UInt32, title: String = "Window", app: String = "example.app",
            incarnation: UInt64 = 1, launch: UInt64 = 1, document: String? = nil) -> WindowRecord {
    WindowRecord(id: windowID(number, incarnation: incarnation, launch: launch), appIdentifier: app,
                 appName: "Example", title: title, frame: WindowRect(x: 0, y: 0, width: 800, height: 600),
                 documentKey: document)
}

struct WindowStateTests {
    @Test
    func testIdentityReuseAndDelayedUpdatesCannotRetarget() {
        var registry = WindowRegistry()
        let first = record(42)
        let replacement = record(42, incarnation: 2)
        let outcome22 = registry.upsert(first)
        #expect(outcome22)
        let outcome23 = registry.commitFocus(first.id)
        #expect(outcome23)
        let outcome24 = registry.upsert(replacement)
        #expect(outcome24)
        let outcome25 = !(registry.upsert(first))
        #expect(outcome25)
        registry.remove(first.id)
        #expect(registry.snapshot.records.map(\.id) == [replacement.id])
        let outcome28 = !(registry.commitFocus(first.id))
        #expect(outcome28)
        registry.remove(replacement.id)
        let outcome30 = !(registry.upsert(replacement))
        #expect(outcome30)
        let outcome31 = !(registry.upsert(first))
        #expect(outcome31)
        let outcome32 = registry.upsert(record(42, launch: 2))
        #expect(outcome32)
        let outcome33 = !(registry.upsert(record(42, incarnation: 99, launch: 1)))
        #expect(outcome33)
    }

    @Test
    func testDestroyBeforeCreateAndEndedLifetimeAreTombstoned() {
        var registry = WindowRegistry()
        registry.remove(windowID(4, incarnation: 3), revision: 10)
        let outcome40 = !(registry.upsert(record(4, incarnation: 3), revision: 11))
        #expect(outcome40)
        let outcome41 = !(registry.upsert(record(4, incarnation: 2), revision: 12))
        #expect(outcome41)
        let outcome42 = registry.upsert(record(4, incarnation: 4), revision: 13)
        #expect(outcome42)
        registry.processEnded(ProcessIdentity(pid: 7, launchToken: 1))
        #expect(registry.snapshot.records.isEmpty)
        let outcome45 = !(registry.upsert(record(99), revision: 14))
        #expect(outcome45)
        let outcome46 = registry.upsert(record(99, launch: 2), revision: 15)
        #expect(outcome46)
    }

    @Test
    func testRevisionedAttributesAndMRUOnlyChangeOnConfirmedFocus() {
        var registry = WindowRegistry()
        let outcome52 = registry.upsert(record(1, title: "New"), revision: 20)
        #expect(outcome52)
        let outcome53 = !(registry.upsert(record(1, title: "Old"), revision: 19))
        #expect(outcome53)
        let outcome54 = !(registry.upsert(record(1, title: "Duplicate"), revision: 20))
        #expect(outcome54)
        let outcome55 = registry.upsert(record(2), revision: 21)
        #expect(outcome55)
        #expect(registry.snapshot.mostRecent.isEmpty)
        let outcome57 = registry.commitFocus(windowID(1))
        #expect(outcome57)
        let outcome58 = registry.commitFocus(windowID(2))
        #expect(outcome58)
        #expect(registry.snapshot.orderedRecords.map(\.id) == [windowID(2), windowID(1)])
        #expect(registry.snapshot.records.first?.title == "New")
        let outcome61 = registry.upsert(record(1, title: "Renamed"), revision: 22)
        #expect(outcome61)
        #expect(registry.snapshot.mostRecent == [windowID(2), windowID(1)])
        registry.remove(windowID(1), revision: 21)
        #expect(registry.snapshot.records.count == 2)
    }

    @Test
    func testSnapshotDeduplicatesUnknownAndRepeatedMRUKeys() {
        let snapshot = WindowSnapshot(records: [record(1), record(2), record(1)],
                                      mostRecent: [windowID(99), windowID(2), windowID(2)])
        #expect(snapshot.orderedRecords.map(\.id) == [windowID(2), windowID(1)])
    }

    private func seeded(_ numbers: [UInt32]) -> WindowRegistry {
        var registry = WindowRegistry()
        for number in numbers { registry.upsert(record(number)) }
        return registry
    }

    @Test
    func testLaunchMRUFollowsStackingThenStableDiscoveryOrder() {
        // Discovered in AX/app order 1...5; window server front-to-back is 3, 1, 4.
        // 2 and 5 are off screen (minimized, hidden, or another Space).
        var registry = seeded([1, 2, 3, 4, 5])
        registry.updateStacking(frontToBack: [windowID(3), windowID(1), windowID(99), windowID(4), windowID(3)])
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [3, 1, 4, 2, 5])
        // The frontmost app's focused window is confirmed by the first scan.
        let observed = registry.observeFocus(windowID(1), sequence: 0)
        #expect(observed)
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [1, 3, 4, 2, 5])
        // A later stacking change reorders only never-focused windows.
        registry.updateStacking(frontToBack: [windowID(4), windowID(1), windowID(3)])
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [1, 4, 3, 2, 5])
        registry.remove(windowID(4))
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [1, 3, 2, 5])
    }

    @Test
    func testOptimisticCommitMovesWindowToFrontBeforeConfirmation() {
        var registry = seeded([1, 2, 3])
        registry.updateStacking(frontToBack: [windowID(1), windowID(2), windowID(3)])
        let requested = registry.requestFocus(windowID(3), sequence: 1)
        #expect(requested)
        #expect(registry.snapshot.orderedRecords.first?.id == windowID(3))
        #expect(registry.hasPendingFocus)
        // A scan that began before the request still reports the old focus: stale.
        let stale = registry.observeFocus(windowID(1), sequence: 0)
        #expect(!stale)
        // Transitional focus on another window while the request is pending is ignored.
        let transitional = registry.observeFocus(windowID(2), sequence: 1)
        #expect(!transitional)
        let confirmed = registry.observeFocus(windowID(3), sequence: 1)
        #expect(confirmed)
        registry.finishFocusRequest(sequence: 1)
        #expect(!registry.hasPendingFocus)
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [3, 1, 2])
        let missing = registry.requestFocus(windowID(42), sequence: 2)
        #expect(!missing)
    }

    @Test
    func testRapidToggleAlternatesBetweenTwoWindows() {
        var registry = seeded([1, 2, 3])
        registry.updateStacking(frontToBack: [windowID(1), windowID(2), windowID(3)])
        _ = registry.observeFocus(windowID(1), sequence: 0)
        var expectedFront = windowID(1)
        var sequence: UInt64 = 0
        for _ in 0..<20 {
            // A Command-Tab session freezes the order and selects ordered[1].
            let session = SwitcherSession(snapshot: registry.snapshot)
            let target = session.selectedID!
            #expect(target != expectedFront)
            #expect(Set([target, expectedFront]) == Set([windowID(1), windowID(2)]))
            sequence += 1
            let requested = registry.requestFocus(target, sequence: sequence)
            #expect(requested)
            // Late notifications from the previous request are rejected.
            let late = registry.observeFocus(expectedFront, sequence: sequence - 1)
            #expect(!late)
            let transitional = registry.observeFocus(expectedFront, sequence: sequence)
            #expect(!transitional)
            expectedFront = target
            #expect(registry.snapshot.orderedRecords.prefix(2).map(\.id) == [target, target == windowID(1) ? windowID(2) : windowID(1)])
        }
        // Requests that finish out of order never resurrect an older intent.
        registry.finishFocusRequest(sequence: sequence - 1)
        #expect(registry.hasPendingFocus)
        registry.finishFocusRequest(sequence: sequence)
        #expect(!registry.hasPendingFocus)
        let older = registry.requestFocus(windowID(3), sequence: sequence - 1)
        #expect(!older)
    }

    @Test
    func testFocusNotificationsReorderWithoutARescan() {
        var registry = seeded([1, 2, 3])
        registry.updateStacking(frontToBack: [windowID(1), windowID(2), windowID(3)])
        _ = registry.observeFocus(windowID(1), sequence: 0)
        // The user clicks window 3, then window 2 (no Paneflo request involved).
        let third = registry.observeFocus(windowID(3), sequence: 0)
        #expect(third)
        let second = registry.observeFocus(windowID(2), sequence: 0)
        #expect(second)
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [2, 3, 1])
        // After a request finishes, observations are accepted as truth again.
        _ = registry.requestFocus(windowID(1), sequence: 5)
        registry.finishFocusRequest(sequence: 5)
        let click = registry.observeFocus(windowID(3), sequence: 5)
        #expect(click)
        #expect(registry.snapshot.orderedRecords.map(\.id.number) == [3, 1, 2])
        // A closed pending target releases the hold.
        _ = registry.requestFocus(windowID(2), sequence: 6)
        registry.remove(windowID(2))
        #expect(!registry.hasPendingFocus)
        let afterClose = registry.observeFocus(windowID(1), sequence: 6)
        #expect(afterClose)
    }
}
