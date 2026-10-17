import Testing
@testable import PanefloCore

struct FreshContactGateTests {
    private func frame(_ pairs: [(Int32, SwipeContactPhase)]) -> [SwipeContactEvidence] {
        pairs.map { .init(id: $0.0, phase: $0.1) }
    }
    private func accepts(_ gate: inout FreshContactGate, _ contacts: [SwipeContactEvidence]) -> Bool {
        gate.accepts(contacts)
    }

    @Test func freshSimultaneousAndStaggeredLandingsAreAccepted() {
        var simultaneous = FreshContactGate()
        #expect(accepts(&simultaneous, frame([(1, .began), (2, .began), (3, .began)])))
        #expect(accepts(&simultaneous, frame([(1, .continuing), (2, .continuing), (3, .continuing)])))

        var staggered = FreshContactGate()
        #expect(accepts(&staggered, frame([(1, .began)])))
        #expect(accepts(&staggered, frame([(1, .continuing), (2, .began)])))
        #expect(accepts(&staggered, frame([(1, .continuing), (2, .continuing), (3, .began)])))
    }

    @Test func heldMixedAndFourthContactsRequireFullLift() {
        for initial in [
            frame([(1, .continuing)]),
            frame([(1, .began), (2, .continuing)]),
            frame([(1, .began), (2, .began), (3, .began), (4, .began)]),
            frame([(1, .began), (1, .began)])
        ] {
            var gate = FreshContactGate()
            #expect(!accepts(&gate, initial))
            #expect(!accepts(&gate, frame([(5, .began), (6, .began), (7, .began)])))
            #expect(accepts(&gate, [SwipeContactEvidence]()))
            #expect(accepts(&gate, frame([(5, .began), (6, .began), (7, .began)])))
        }
    }

    @Test func newlyAppearingHeldIdentityQuarantinesStaggeredSequence() {
        var gate = FreshContactGate()
        #expect(accepts(&gate, frame([(1, .began)])))
        #expect(!accepts(&gate, frame([(1, .continuing), (2, .continuing)])))
        #expect(!accepts(&gate, frame([(1, .continuing), (2, .began), (3, .began)])))
        #expect(accepts(&gate, [SwipeContactEvidence]()))
        #expect(accepts(&gate, frame([(9, .began)])))
    }

    @Test func oneDroppedMakeTouchFrameAfterFingerFreeFrameIsTolerated() {
        // Staggered landing where the second finger's make-touch frame was dropped.
        var staggered = FreshContactGate()
        #expect(accepts(&staggered, [SwipeContactEvidence]()))
        #expect(accepts(&staggered, frame([(1, .began)])))
        #expect(accepts(&staggered, frame([(1, .continuing), (2, .continuing)])))
        #expect(accepts(&staggered, frame([(1, .continuing), (2, .continuing), (3, .began)])))

        // Simultaneous landing whose single make-touch frame was dropped.
        var simultaneous = FreshContactGate()
        #expect(accepts(&simultaneous, [SwipeContactEvidence]()))
        #expect(accepts(&simultaneous, frame([(1, .continuing), (2, .continuing), (3, .continuing)])))

        // The allowance renews with every finger-free frame.
        #expect(accepts(&simultaneous, [SwipeContactEvidence]()))
        #expect(accepts(&simultaneous, frame([(4, .continuing)])))
    }

    @Test func secondUnprovenFrameInOneStrokeQuarantinesUntilLift() {
        var gate = FreshContactGate()
        #expect(accepts(&gate, [SwipeContactEvidence]()))
        #expect(accepts(&gate, frame([(1, .continuing)])))
        #expect(!accepts(&gate, frame([(1, .continuing), (2, .continuing)])))
        #expect(!accepts(&gate, frame([(1, .continuing), (2, .continuing), (3, .began)])))
        #expect(accepts(&gate, [SwipeContactEvidence]()))
        #expect(accepts(&gate, frame([(5, .began)])))
    }

    @Test func resetForgetsFingerFreeEvidence() {
        var gate = FreshContactGate()
        #expect(accepts(&gate, [SwipeContactEvidence]()))
        gate.reset()
        // Contacts held across a restart are not proven fresh.
        #expect(!accepts(&gate, frame([(1, .continuing), (2, .continuing), (3, .continuing)])))
    }
}
