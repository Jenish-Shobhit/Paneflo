import Foundation
import Testing
@testable import PanefloCore

struct OverviewSlotStoreTests {
    @Test
    func testFocusOrderSearchAndNewWindowsPreserveSlots() {
        var store = OverviewSlotStore()
        store.reconcile([record(1, title: "Browser"), record(2, title: "Editor"), record(3)])
        let original = store.slots
        store.reconcile([record(3), record(2, title: "Renamed"), record(1, title: "Browser")])
        #expect(store.slots == original)
        #expect(store.matches(query: "browser", records: [record(1, title: "Browser"), record(2)]) == [original[0].id])
        #expect(store.slots == original)
        store.reconcile([record(1), record(3)])
        #expect(store.slots[1].binding == nil)
        store.reconcile([record(4), record(1), record(3)])
        #expect(store.slots.map(\.id) == original.map(\.id))
        #expect(store.slots.map(\.binding) == [windowID(1), windowID(4), windowID(3)])
    }

    @Test
    func testQueryEligibilityContainsOnlyMatchingBoundWindowsInStableSlotOrder() {
        var store = OverviewSlotStore()
        let records = [record(1, title: "Finder"), record(2, title: "Fixture One"), record(3, title: "Fixture Two")]
        store.reconcile(records)
        store.move(slotID: store.slots[2].id, to: 0)
        let positions = store.slots
        #expect(store.matchingWindowIDs(query: "fixture", records: records) == [windowID(3), windowID(2)])
        #expect(store.matchingWindowIDs(query: "no results", records: records).isEmpty)
        #expect(store.slots == positions)
        store.reconcile([records[0], records[2]])
        #expect(store.matchingWindowIDs(query: "fixture", records: [records[0], records[2]]) == [windowID(3)])
    }

    @Test
    func testPinnedVacancyAndExplicitReorder() {
        var store = OverviewSlotStore()
        store.reconcile([record(1), record(2)])
        let pinnedID = store.slots[0].id
        store.pin(slotID: pinnedID)
        store.reconcile([record(2), record(3)])
        #expect(store.slots.count == 3)
        #expect(store.slots[0].binding == nil)
        #expect(store.slots[1].binding == windowID(2))
        store.move(slotID: pinnedID, to: 99)
        #expect(store.slots.last?.id == pinnedID)
        store.unpin(slotID: pinnedID)
        store.reconcile([record(2), record(3), record(4)])
        #expect(store.slots.last?.binding == windowID(4))
    }

    @Test
    func testMatchingRequiresUniqueWindowAndUniqueSlotClaim() throws {
        var store = OverviewSlotStore()
        store.reconcile([record(1)])
        store.pin(slotID: store.slots[0].id, matchingRule: SlotMatchingRule(appIdentifier: "example.app"))
        store = try OverviewSlotStore(metadata: store.encodedMetadata())
        store.reconcile([record(2), record(3)])
        #expect(store.slots[0].binding == nil)
        #expect(store.slots.count == 3)
        var exact = OverviewSlotStore()
        exact.reconcile([record(1)])
        exact.pin(slotID: exact.slots[0].id, matchingRule: SlotMatchingRule(appIdentifier: "example.app", documentKey: "document-A"))
        exact = try OverviewSlotStore(metadata: exact.encodedMetadata())
        exact.reconcile([record(4, document: "document-B"), record(5, document: "document-A")])
        #expect(exact.slots[0].binding == windowID(5))
    }

    @Test
    func testPersistenceContainsNoRuntimeIdentityOrTitleAndRejectsUnknownSchema() throws {
        var store = OverviewSlotStore()
        store.reconcile([record(12, title: "PRIVATE_WINDOW_TITLE")])
        store.pin(slotID: store.slots[0].id)
        let encoded = try store.encodedMetadata()
        let encodedAgain = try store.encodedMetadata()
        #expect(encoded == encodedAgain)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!(text.contains("PRIVATE_WINDOW_TITLE")))
        #expect(!(text.contains("launchToken")))
        #expect(!(text.contains("binding")))
        let restored = try OverviewSlotStore(metadata: encoded)
        #expect(restored.slots.map(\.id) == store.slots.map(\.id))
        #expect(restored.slots[0].binding == nil)
        #expect(restored.slots[0].isPinned)
        let future = Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
        #expect(throws: (any Error).self) { try OverviewSlotStore(metadata: future) }
        #expect(throws: (any Error).self) { try OverviewSlotStore(metadata: Data("broken".utf8)) }
    }

    @Test
    func testPlaceSwapAndRemoveFreeSlotsKeepOtherPositions() {
        var store = OverviewSlotStore()
        store.reconcile([record(1), record(2), record(3), record(4)])
        let ids = store.slots.map(\.id)
        store.reconcile([record(1), record(3), record(4)])
        #expect(OverviewSlotStore.isFree(store.slots[1]))
        // Window 4 dropped on the free slot: it moves there, its old place becomes free, nothing else shifts.
        let placed = store.place(slotID: ids[3], into: ids[1])
        #expect(placed)
        #expect(store.slots.map(\.binding) == [windowID(1), windowID(4), windowID(3), nil])
        #expect(store.slots.map(\.id) == [ids[0], ids[3], ids[2], ids[1]])
        // A bound target is refused by place and accepted by swap.
        let refused = store.place(slotID: ids[0], into: ids[2])
        let swapped = store.swap(ids[0], ids[2])
        #expect(!refused && swapped)
        #expect(store.slots.map(\.binding) == [windowID(3), windowID(4), windowID(1), nil])
        let same = store.swap(ids[0], ids[0]), unknown = store.swap(ids[0], UUID())
        #expect(!same && !unknown)
        // A new window still takes the free slot.
        store.reconcile([record(1), record(3), record(4), record(5)])
        #expect(store.slots[3].binding == windowID(5))
    }

    @Test
    func testRemovingFreeSlotsKeepsPinnedVacanciesAndWindows() {
        var store = OverviewSlotStore()
        store.reconcile([record(1), record(2), record(3), record(4)])
        let kept = store.slots[0].id
        store.pin(slotID: kept, matchingRule: SlotMatchingRule(appIdentifier: "other.app"))
        store.reconcile([record(3)])
        #expect(store.slots.count == 4)
        let removedBound = store.remove(slotID: store.slots[2].id)
        let removedFree = store.removeFreeSlots()
        #expect(!removedBound && removedFree == 2)
        #expect(store.slots.map(\.binding) == [nil, windowID(3)] && store.slots[0].id == kept)
        let removedKept = store.remove(slotID: kept)
        #expect(removedKept && store.slots.map(\.binding) == [windowID(3)])
        store.reset([record(7), record(8)])
        #expect(store.slots.map(\.binding) == [windowID(7), windowID(8)] && store.slots.allSatisfy { !$0.isPinned })
    }
}
