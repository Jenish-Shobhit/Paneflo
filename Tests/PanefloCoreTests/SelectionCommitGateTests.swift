import Testing
@testable import PanefloCore

struct SelectionCommitGateTests {
    private func id(_ number: UInt32) -> WindowIdentity {
        .init(process: .init(pid: 42, launchToken: 8), number: number, incarnation: 1)
    }
    @Test func releaseWaitsForPlacementAndFocusesCommittedSelection() {
        var gate = SelectionCommitGate()
        let token = gate.beginPlacement()
        let committed = gate.commit(id(2))
        #expect(committed == nil)
        let focus = gate.finishPlacement(token)
        #expect(focus == id(2))
        #expect(gate.finishPlacement(token) == nil)
    }
    @Test func supersededPlacementCannotReleaseFocusEarlyAndEscapeCancelsFocus() {
        var gate = SelectionCommitGate()
        let old = gate.beginPlacement()
        let current = gate.beginPlacement()
        _ = gate.commit(id(3))
        #expect(gate.finishPlacement(old) == nil)
        gate.cancelCommit()
        #expect(gate.finishPlacement(current) == nil)
        #expect(gate.commit(id(4)) == id(4))
    }
    @Test func oldCompletionCannotFocusAfterCancelOrReleaseNewPlacementEarly() {
        var gate = SelectionCommitGate()
        let old = gate.beginPlacement()
        _ = gate.commit(id(1))
        gate.cancelCommit() // Escape/new invocation clears any previous focus request.
        #expect(gate.finishPlacement(old) == nil)
        let current = gate.beginPlacement()
        _ = gate.commit(id(2))
        #expect(gate.finishPlacement(old) == nil)
        #expect(gate.finishPlacement(current) == id(2))
    }

}
