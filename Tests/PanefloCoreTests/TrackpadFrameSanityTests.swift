import Testing
@testable import PanefloCore

struct TrackpadFrameSanityTests {
    private func sample(_ id: Int32, _ x: Float, _ y: Float, state: Int32 = 4, size: Float = 0.6) -> TrackpadContactSample {
        .init(id: id, state: state, x: x, y: y, size: size, majorAxis: 9, minorAxis: 7)
    }

    /// Feeds `count` frames from `make(frameIndex)` and returns the final verdict.
    private func run(_ check: inout TrackpadFrameSanity, frames count: Int,
                     _ make: (Int) -> [TrackpadContactSample]) -> TrackpadFrameSanity.Verdict {
        var verdict = TrackpadFrameSanity.Verdict.pending
        for index in 0..<count {
            check.beginFrame()
            for contact in make(index) { check.observe(contact) }
            verdict = check.endFrame()
        }
        return verdict
    }

    @Test func smoothContactsBecomePlausibleAfterRequiredFrames() {
        var check = TrackpadFrameSanity()
        let swipe: (Int) -> [TrackpadContactSample] = { index in
            let y = 0.3 + Float(index) * 0.01
            return [self.sample(1, 0.4, y, state: index == 0 ? 3 : 4), self.sample(2, 0.5, y + 0.02), self.sample(3, 0.6, y)]
        }
        #expect(run(&check, frames: 11, swipe) == .pending)
        #expect(run(&check, frames: 1) { swipe($0 + 11) } == .plausible)
        // The verdict is final.
        #expect(run(&check, frames: 1) { _ in [self.sample(1, 0.4, 0.3), self.sample(1, 0.4, 0.3)] } == .plausible)
    }

    @Test func emptyFramesDoNotCount() {
        var check = TrackpadFrameSanity()
        #expect(run(&check, frames: 40) { _ in [] } == .pending)
        // Hover-only contacts carry no geometry evidence yet but still track continuity.
        #expect(run(&check, frames: 12) { _ in [self.sample(1, 0.5, 0.5, state: 1, size: 0)] } == .plausible)
    }

    @Test func layoutMismatchSignaturesAreImplausible() {
        var jumping = TrackpadFrameSanity()
        let jump = run(&jumping, frames: 12) { index in
            [self.sample(1, index.isMultiple(of: 2) ? 0.05 : 0.95, index.isMultiple(of: 2) ? 0.95 : 0.05)]
        }
        #expect(jump == .implausible("contact positions jumped between frames"))

        var duplicated = TrackpadFrameSanity()
        #expect(run(&duplicated, frames: 1) { _ in [self.sample(1, 0.4, 0.3), self.sample(1, 0.5, 0.3)] }
            == .implausible("a frame repeated a contact identifier"))

        var outOfRange = TrackpadFrameSanity()
        #expect(run(&outOfRange, frames: 1) { _ in [self.sample(-7, 0.4, 0.3)] }
            == .implausible("contact identifiers were out of range"))

        var sizeless = TrackpadFrameSanity()
        #expect(run(&sizeless, frames: 12) { _ in [self.sample(1, 0.4, 0.3, size: 0)] }
            == .implausible("touching contacts reported no size"))
    }

    @Test func occasionalLargeStepIsTolerated() {
        var check = TrackpadFrameSanity()
        let verdict = run(&check, frames: 12) { index in
            [self.sample(1, 0.4, index >= 5 ? 0.9 : 0.4)]
        }
        #expect(verdict == .plausible)
    }
}
