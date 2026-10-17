import Testing
@testable import PanefloCore

struct AXWorkAdmissionLaneTests {
    private func ticket(_ id: UInt64, _ pid: Int32, lane: UInt8) -> AXWorkAdmission.Ticket {
        .init(id: id, pid: pid, priority: .interactive, lane: lane)
    }

    @Test func focusAndPlacementForOnePIDRunSideBySide() {
        var admission = AXWorkAdmission()
        admission.enqueue(ticket(1, 7, lane: 1)) // placement
        admission.enqueue(ticket(2, 7, lane: 0)) // focus issued right after
        #expect(admission.takeReady().map(\.id) == [1, 2])
    }

    @Test func focusNeverEvictsAPendingPlacementButAnotherPlacementDoes() {
        var admission = AXWorkAdmission()
        admission.enqueue(ticket(1, 7, lane: 1))
        #expect(admission.takeReady().map(\.id) == [1])
        // A second tile queues behind the running one; a focus for the same PID must not drop it.
        #expect(admission.enqueue(ticket(2, 7, lane: 1)).isEmpty)
        #expect(admission.enqueue(ticket(3, 7, lane: 0)).isEmpty)
        #expect(admission.enqueue(ticket(4, 7, lane: 1)) == [2])
        #expect(admission.pending.map(\.id) == [3, 4])
    }
}
