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
}
