import Foundation
import Testing
@testable import PanefloCore

struct PreviewBudgetTests {
    private let mib = 1_024 * 1_024

    @Test
    func testUniqueReservationsAndPhysicalDebtRemainUntilCompletion() throws {
        var budget = PreviewBudget()
        let optionalValue11 = budget.reserve(estimatedBytes: 12 * mib)
        let first = try #require(optionalValue11)
        let optionalValue12 = budget.reserve(estimatedBytes: 12 * mib)
        let second = try #require(optionalValue12)
        #expect(first.id != second.id)
        let outcome14 = budget.reserve(estimatedBytes: 1) == nil
        #expect(outcome14)
        let outcome15 = budget.submit(first)
        #expect(outcome15)
        budget.timeout(first)
        #expect(budget.reservedBytes == 24 * mib)
        let outcome18 = budget.reserve(estimatedBytes: 1) == nil
        #expect(outcome18)
        budget.cancel(second) // queued, so no physical work holds this reservation
        #expect(budget.reservedBytes == 12 * mib)
        let outcome21 = budget.reconcile(first, actualBytes: 12 * mib) == .discarded
        #expect(outcome21)
        #expect(budget.accountedBytes == 0)
        let outcome23 = budget.reconcile(first, actualBytes: 1) == .rejected(.unknownReservation)
        #expect(outcome23)
    }

    @Test
    func testActualStrideReconciliationRejectsOverflowAndOversizedPayload() throws {
        #expect(PreviewBudget.payloadBytes(bytesPerRow: 1_280, height: 200) == 256_000)
        #expect(PreviewBudget.payloadBytes(bytesPerRow: Int.max, height: 2) == nil)
        #expect(PreviewBudget.payloadBytes(bytesPerRow: 0, height: 100) == nil)
        var budget = PreviewBudget()
        let outcome32 = budget.reserve(estimatedBytes: Int.max) == nil
        #expect(outcome32)
        let optionalValue33 = budget.reserve(estimatedBytes: 1_000)
        let pending = try #require(optionalValue33)
        let outcome34 = budget.reconcile(pending, actualBytes: 2_000) == .rejected(.notSubmitted)
        #expect(outcome34)
        let outcome35 = budget.submit(pending)
        #expect(outcome35)
        let result = budget.reconcile(pending, actualBytes: 2_000)
        guard case let .admitted(allocation) = result else { Issue.record("Expected actual allocation"); return }
        #expect(allocation.bytes == 2_000)
        #expect(budget.retainedBytes == 2_000)
        let optionalValue40 = budget.reserve(estimatedBytes: 1_000)
        let oversize = try #require(optionalValue40)
        budget.submit(oversize)
        let outcome42 = budget.reconcile(oversize, actualBytes: 25 * mib) == .rejected(.capacity)
        #expect(outcome42)
        #expect(budget.reservationCount == 0)
        budget.release(allocation)
        #expect(budget.accountedBytes == 0)
    }

    @Test
    func testPressurePurgesPayloadsButKeepsOutstandingReservationsVisible() throws {
        var budget = PreviewBudget()
        let optionalValue51 = budget.reserve(estimatedBytes: 4 * mib)
        let queued = try #require(optionalValue51)
        let optionalValue52 = budget.reserve(estimatedBytes: 12 * mib)
        let running = try #require(optionalValue52)
        budget.submit(running)
        budget.setMode(.memoryPressure)
        #expect(budget.reservedBytes == 12 * mib)
        #expect(budget.isOverLimit)
        let outcome57 = budget.reserve(estimatedBytes: 1) == nil
        #expect(outcome57)
        let outcome58 = budget.reconcile(queued, actualBytes: 1) == .rejected(.unknownReservation)
        #expect(outcome58)
        budget.finishWithoutPayload(running)
        #expect(!(budget.isOverLimit))
        let outcome61 = budget.reserve(estimatedBytes: 1, kind: .liveFrame) == nil
        #expect(outcome61)
        let optionalValue62 = budget.reserve(estimatedBytes: 6 * mib)
        let thumbnail = try #require(optionalValue62)
        budget.submit(thumbnail)
        guard case .admitted = budget.reconcile(thumbnail, actualBytes: 6 * mib) else { Issue.record(); return }
        budget.setMode(.iconsOnly)
        #expect(budget.accountedBytes == 0)
        let outcome67 = budget.reserve(estimatedBytes: 1) == nil
        #expect(outcome67)
    }

    @Test
    func testLRUEvictionAndMetadataCaps() throws {
        var budget = PreviewBudget(reservationLimit: 1, allocationLimit: 2)
        var stored: [PreviewAllocation] = []
        for _ in 0..<3 {
            let optionalValue75 = budget.reserve(estimatedBytes: 1)
            let reservation = try #require(optionalValue75)
            let outcome76 = budget.reserve(estimatedBytes: 1) == nil
            #expect(outcome76)
            budget.submit(reservation)
            guard case let .admitted(allocation) = budget.reconcile(reservation, actualBytes: 1) else { Issue.record(); return }
            stored.append(allocation)
        }
        #expect(budget.allocations.map(\.id) == [stored[1].id, stored[2].id])
        budget.touch(stored[1])
        #expect(budget.allocations.last?.id == stored[1].id)
        #expect(budget.accountedBytes == 2)
    }
}
