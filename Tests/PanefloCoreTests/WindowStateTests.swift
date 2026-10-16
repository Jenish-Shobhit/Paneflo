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
}
