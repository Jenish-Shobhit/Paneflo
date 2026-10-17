import Testing
@testable import PanefloCore

struct AXWorkAdmissionTests {
    private func ticket(_ id: UInt64, _ pid: Int32, _ priority: AXWorkAdmission.Priority) -> AXWorkAdmission.Ticket {
        .init(id: id, pid: pid, priority: priority)
    }

    @Test func interactiveWorkHasItsOwnLaneAndIsNeverBlockedByAScan() {
        var admission = AXWorkAdmission()
        for index in 1...5 { admission.enqueue(ticket(UInt64(index), Int32(index), .background)) }
        #expect(admission.takeReady().map(\.id) == [1, 2])
        // PID 1 is mid-scan (possibly up to its 0.8 s deadline); focus for PID 1 starts now.
        admission.enqueue(ticket(6, 1, .interactive))
        admission.enqueue(ticket(7, 7, .interactive))
        admission.enqueue(ticket(8, 8, .interactive))
        #expect(admission.takeReady().map(\.id) == [6, 7])
        #expect(admission.active.filter { $0.pid == 1 }.count == 2)
        // Interactive slots are separate from scan slots: finishing a scan admits a scan.
        let scanCompleted = admission.finish(1)
        #expect(scanCompleted)
        #expect(admission.takeReady().map(\.id) == [3])
        let focusCompleted = admission.finish(6)
        #expect(focusCompleted)
        #expect(admission.takeReady().map(\.id) == [8])
    }

    @Test func interactiveWorkIsSerializedOnlyAgainstInteractiveWorkForTheSamePID() {
        var admission = AXWorkAdmission()
        admission.enqueue(ticket(1, 1, .interactive))
        #expect(admission.takeReady().map(\.id) == [1])
        admission.enqueue(ticket(2, 1, .interactive))
        admission.enqueue(ticket(3, 1, .background))
        // The scan may run beside the focus job; the second interactive job waits its turn.
        #expect(admission.takeReady().map(\.id) == [3])
        let completed = admission.finish(1)
        #expect(completed)
        #expect(admission.takeReady().map(\.id) == [2])
    }

    @Test func updatesAndScansSerializePerPIDWithSeparateSlots() {
        var admission = AXWorkAdmission()
        admission.enqueue(ticket(1, 1, .background))
        admission.enqueue(ticket(2, 2, .background))
        #expect(admission.takeReady().map(\.id) == [1, 2])
        admission.enqueue(ticket(3, 1, .update))
        admission.enqueue(ticket(4, 3, .update))
        admission.enqueue(ticket(5, 4, .update))
        // Scan slots are full, but updates have their own; PID 1's update waits for its scan.
        #expect(admission.takeReady().map(\.id) == [4, 5])
        _ = admission.finish(1)
        _ = admission.finish(4)
        #expect(admission.takeReady().map(\.id) == [3])
        admission.enqueue(ticket(6, 1, .background))
        #expect(admission.takeReady().isEmpty)
        _ = admission.finish(3)
        #expect(admission.takeReady().map(\.id) == [6])
    }

    @Test func coalescesPendingAndBoundsStorageWithoutReleasingActiveWork() {
        var admission = AXWorkAdmission(maximumPending: 2)
        admission.enqueue(ticket(1, 1, .background))
        _ = admission.takeReady()
        admission.enqueue(ticket(2, 1, .background))
        #expect(admission.enqueue(ticket(3, 1, .background)) == [2])
        admission.enqueue(ticket(4, 2, .background))
        #expect(admission.enqueue(ticket(5, 3, .background)) == [5])
        #expect(admission.enqueue(ticket(6, 4, .interactive)) == [3])
        #expect(admission.pending.count == 2)
        #expect(admission.active.map(\.id) == [1])
        let staleCompleted = admission.finish(2)
        #expect(!staleCompleted)
        #expect(admission.active.count == 1)
    }

    @Test func completionAdmitsOtherPIDsWhileBlockedPIDKeepsOnlyLatestIntent() {
        var admission = AXWorkAdmission()
        admission.enqueue(ticket(1, 1, .interactive))
        admission.enqueue(ticket(2, 2, .background))
        _ = admission.takeReady()
        for id: UInt64 in 3...200 { admission.enqueue(ticket(id, 1, .interactive)) }
        admission.enqueue(ticket(201, 3, .interactive))
        #expect(admission.pending.count == 2)
        #expect(admission.takeReady().map(\.id) == [201])
        let completed = admission.finish(1)
        #expect(completed)
        #expect(admission.takeReady().map(\.id) == [200])
    }
}
