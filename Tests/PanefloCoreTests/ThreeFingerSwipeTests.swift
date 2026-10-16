import Testing
@testable import PanefloCore

struct ThreeFingerSwipeTests {
    private func contacts(_ y: Double, x: Double = 0.3, count: Int = 3) -> [SwipeContact] {
        (0..<count).map { .init(id: Int32($0), x: x + Double($0) * 0.1, y: y) }
    }
    @Test func coherentVerticalSwipeEmitsOnceUntilLiftAndDownMeansDismiss() {
        var swipe = ThreeFingerSwipe()
        #expect(swipe.update(timestamp: 1, contacts: contacts(0.3)) == nil)
        #expect(swipe.update(timestamp: 1.03, contacts: contacts(0.35)) == nil)
        #expect(swipe.update(timestamp: 1.08, contacts: contacts(0.46)) == .up)
        #expect(swipe.update(timestamp: 1.1, contacts: contacts(0.65)) == nil)
        #expect(swipe.update(timestamp: 1.11, contacts: [SwipeContact]()) == nil)
        #expect(swipe.update(timestamp: 1.12, contacts: contacts(0.7)) == nil)
        #expect(swipe.update(timestamp: 1.2, contacts: contacts(0.53)) == .down)
    }
    @Test func extraContactsCannotBecomeSwipe() {
        for initialCount in [4] {
            var swipe = ThreeFingerSwipe()
            #expect(swipe.update(timestamp: 1, contacts: contacts(0.3, count: initialCount)) == nil)
            #expect(swipe.update(timestamp: 1.04, contacts: contacts(0.3)) == nil)
            #expect(swipe.update(timestamp: 1.12, contacts: contacts(0.6)) == nil)
        }
        var swipe = ThreeFingerSwipe()
        _ = swipe.update(timestamp: 1, contacts: contacts(0.3))
        _ = swipe.update(timestamp: 1.04, contacts: contacts(0.35, count: 4))
        #expect(swipe.update(timestamp: 1.12, contacts: contacts(0.6)) == nil)
    }
    @Test func stationaryStaggeredLandingArmsButScrollingAndLateThirdDoNot() {
        var swipe = ThreeFingerSwipe()
        _ = swipe.update(timestamp: 1, contacts: contacts(0.3, count: 1))
        _ = swipe.update(timestamp: 1.03, contacts: contacts(0.305, count: 2))
        _ = swipe.update(timestamp: 1.06, contacts: contacts(0.31))
        #expect(swipe.update(timestamp: 1.14, contacts: contacts(0.5)) == .up)
        for thirdTime in [1.08, 1.12] {
            var scrolling = ThreeFingerSwipe()
            _ = scrolling.update(timestamp: 1, contacts: contacts(0.3, count: 2))
            _ = scrolling.update(timestamp: 1.04, contacts: contacts(0.4, count: 2))
            _ = scrolling.update(timestamp: thirdTime, contacts: contacts(0.4))
            #expect(scrolling.update(timestamp: thirdTime + 0.08, contacts: contacts(0.6)) == nil)
        }
        var late = ThreeFingerSwipe()
        _ = late.update(timestamp: 1, contacts: contacts(0.3, count: 2))
        _ = late.update(timestamp: 1.12, contacts: contacts(0.3))
        #expect(late.update(timestamp: 1.2, contacts: contacts(0.6)) == nil)
    }
    @Test func palmInvalidCoordinatesAndChangedIdentityCancel() {
        var palm = contacts(0.3); palm[1].isPalm = true
        var invalid = contacts(0.3); invalid[1].x = .nan
        var duplicate = contacts(0.3); duplicate[1].id = duplicate[0].id
        for frame in [palm, invalid, duplicate] {
            var swipe = ThreeFingerSwipe()
            _ = swipe.update(timestamp: 1, contacts: frame)
            #expect(swipe.update(timestamp: 1.08, contacts: contacts(0.6)) == nil)
        }
        var swipe = ThreeFingerSwipe()
        _ = swipe.update(timestamp: 1, contacts: contacts(0.3))
        var changed = contacts(0.6); changed[1].id = 99
        #expect(swipe.update(timestamp: 1.08, contacts: changed) == nil)
    }
    @Test func resetGapAndReversedClockRequireLiftBeforeFreshSequence() {
        for mode in 0..<3 {
            var swipe = ThreeFingerSwipe()
            _ = swipe.update(timestamp: 1, contacts: contacts(0.3))
            if mode == 0 { swipe.reset() }
            let next = mode == 1 ? 1.4 : mode == 2 ? 0.9 : 1.08
            #expect(swipe.update(timestamp: next, contacts: contacts(0.6)) == nil)
            _ = swipe.update(timestamp: 2, contacts: [SwipeContact]())
            _ = swipe.update(timestamp: 2.01, contacts: contacts(0.3))
            #expect(swipe.update(timestamp: 2.1, contacts: contacts(0.6)) == .up)
        }
    }
    @Test func diagonalOpposingAndUnequalMotionAreRejected() {
        var diagonal = contacts(0.5, x: 0.4)
        var opposing = contacts(0.5); opposing[2].y = 0.1
        var unequal = contacts(0.5); unequal[2].y = 0.7
        for frame in [diagonal, opposing, unequal] {
            var swipe = ThreeFingerSwipe()
            _ = swipe.update(timestamp: 1, contacts: contacts(0.3))
            #expect(swipe.update(timestamp: 1.08, contacts: frame) == nil)
        }
        diagonal[0].y = .infinity
        var swipe = ThreeFingerSwipe()
        #expect(swipe.update(timestamp: .nan, contacts: diagonal) == nil)
    }
    @Test func travelMustRemainStableForMinimumDurationAndAcceptBorrowedBuffer() {
        var swipe = ThreeFingerSwipe()
        _ = swipe.update(timestamp: 1, contacts: contacts(0.3))
        #expect(swipe.update(timestamp: 1.02, contacts: contacts(0.5)) == nil)
        let frame = contacts(0.52)
        let result = frame.withUnsafeBufferPointer { swipe.update(timestamp: 1.08, contacts: $0) }
        #expect(result == .up)
    }
}
