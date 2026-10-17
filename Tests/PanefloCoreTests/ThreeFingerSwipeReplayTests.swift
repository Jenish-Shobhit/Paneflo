import Testing
@testable import PanefloCore

/// Replays synthetic trajectories through the recognizer. Each stroke starts and ends with a
/// finger-free frame, so every case is an independent stroke.
struct ThreeFingerSwipeReplayTests {
    private static let frameIntervals: [Double] = [1.0 / 90, 1.0 / 120, 1.0 / 500]
    private typealias Finger = SwipeTrajectory.Finger

    private func expectOnce(_ trajectory: SwipeTrajectory, _ direction: ThreeFingerSwipeDirection,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        for interval in Self.frameIntervals {
            var trajectory = trajectory
            trajectory.frameInterval = interval
            #expect(trajectory.replay() == [direction], "frame interval \(interval)", sourceLocation: sourceLocation)
        }
    }

    private func expectNone(_ trajectory: SwipeTrajectory, sourceLocation: SourceLocation = #_sourceLocation) {
        for interval in Self.frameIntervals {
            var trajectory = trajectory
            trajectory.frameInterval = interval
            #expect(trajectory.replay().isEmpty, "frame interval \(interval)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Recognized

    @Test func fannedSwipesRecognizeBothDirections() {
        expectOnce(.swipe(up: true, fan: 0.03), .up)
        expectOnce(.swipe(up: false, fan: 0.03), .down)
        expectOnce(.swipe(up: true, fan: -0.025, drift: 0.02), .up)
    }

    @Test func curledDownSwipeWithUnequalTravelRecognizes() {
        // Fingertips curl: outer fingers travel less and converge toward the middle.
        expectOnce(.swipe(up: false, travel: 0.22, shares: (0.6, 1, 0.5), fan: -0.03), .down)
        expectOnce(.swipe(up: false, travel: 0.2, shares: (1, 0.7, 0.55), fan: -0.02, duration: 0.18), .down)
        expectOnce(.swipe(up: true, travel: 0.22, shares: (0.6, 1, 0.55)), .up)
    }

    @Test func staggeredLandingsWithMovementDuringLandingRecognize() {
        for stagger in [0.05, 0.1, 0.15] {
            for up in [true, false] {
                // Motion starts when the second finger lands, before the third is down.
                let trajectory = SwipeTrajectory.swipe(up: up, landings: (0, stagger / 2, stagger),
                                                       moveStart: stagger / 2)
                expectOnce(trajectory, up ? .up : .down)
                // Reversed landing order.
                expectOnce(.swipe(up: up, landings: (stagger, stagger / 2, 0), moveStart: stagger / 2), up ? .up : .down)
            }
        }
    }

    @Test func quickFlicksRecognizeOnVelocity() {
        // 8% of the pad in 60 ms, below the distance threshold when recognized.
        expectOnce(.swipe(up: true, travel: 0.08, duration: 0.06), .up)
        expectOnce(.swipe(up: false, travel: 0.08, shares: (0.8, 1, 0.7), duration: 0.06), .down)
    }

    @Test func slowSwipesRecognizeOnDistance() {
        expectOnce(.swipe(up: true, travel: 0.2, duration: 1.0), .up)
        expectOnce(.swipe(up: false, travel: 0.2, shares: (0.7, 1, 0.6), duration: 1.0), .down)
    }

    @Test func bottomEdgeStartedUpSwipeAndTopEdgeStartedDownSwipeRecognize() {
        expectOnce(.swipe(up: true, startY: 0.005), .up)
        expectOnce(.swipe(up: true, startY: -0.02), .up)
        expectOnce(.swipe(up: false, startY: 0.96), .down)
        // Edge fingers along the left rim.
        expectOnce(.swipe(up: true, centerX: 0.13), .up)
    }

    @Test func oneRecognitionPerStrokeAndAgainAfterLift() {
        var recognizer = ThreeFingerSwipe()
        let long = SwipeTrajectory.swipe(up: true, travel: 0.6, startY: 0.1, duration: 0.5)
        #expect(long.replay(&recognizer, startingAt: 10) == [.up])
        #expect(SwipeTrajectory.swipe(up: false).replay(&recognizer, startingAt: 20) == [.down])
        #expect(SwipeTrajectory.swipe(up: true).replay(&recognizer, startingAt: 30) == [.up])
        // Down then back up within one stroke still fires once.
        var reversal = SwipeTrajectory.swipe(up: false, travel: 0.3)
        reversal.hold = 0
        var frames = reversal.frames(startingAt: 40)
        let last = frames.removeLast()
        let base = frames.last!.0
        let finalContacts = frames.last!.1
        for step in 1...30 {
            let moved = finalContacts.map { SwipeContact(id: $0.id, x: $0.x, y: $0.y + Double(step) * 0.015) }
            frames.append((base + Double(step) / 120, moved))
        }
        frames.append((base + 31.0 / 120, last.1))
        var results: [ThreeFingerSwipeDirection] = []
        for (time, contacts) in frames {
            if let direction = recognizer.update(timestamp: time, contacts: contacts) { results.append(direction) }
        }
        #expect(results == [.down])
    }

    /// Seeded variation of fanning, curl, landing stagger, speed, start position and frame rate.
    @Test func variedNaturalSwipesRecognizeEveryTime() {
        var random = SeededRandom(seed: 0x5eed)
        for up in [true, false] {
            var recognized = 0
            let attempts = 40
            for attempt in 0..<attempts {
                let minimumShare = up ? 0.7 : 0.55
                let stagger = random.next(in: 0...0.15)
                let order = attempt % 3
                let landings = order == 0 ? (0, stagger / 2, stagger)
                    : order == 1 ? (stagger, 0, stagger / 2) : (stagger / 2, stagger, 0)
                var trajectory = SwipeTrajectory.swipe(
                    up: up, travel: random.next(in: 0.18...0.35),
                    startY: up ? random.next(in: 0.0...0.4) : random.next(in: 0.55...0.95),
                    centerX: random.next(in: 0.3...0.7),
                    shares: (random.next(in: minimumShare...1), random.next(in: 0.85...1), random.next(in: minimumShare...1)),
                    fan: random.next(in: -0.03...0.03), landings: landings,
                    moveStart: random.next(in: 0...stagger + 0.03),
                    duration: random.next(in: 0.1...0.7), drift: random.next(in: -0.03...0.03),
                    frameInterval: [1.0 / 90, 1.0 / 120, 1.0 / 250][attempt % 3], seed: UInt64(attempt + 1))
                trajectory.jitter = random.next(in: 0.0005...0.003)
                if trajectory.replay() == [up ? .up : .down] { recognized += 1 }
            }
            #expect(recognized == attempts, "\(up ? "up" : "down"): \(recognized)/\(attempts)")
        }
    }

    // MARK: Never recognized

    @Test func palmRestingDoesNotTrigger() {
        // A classified palm beside three swiping fingers cancels the stroke.
        var withPalm = SwipeTrajectory.swipe(up: true)
        withPalm.fingers.append(Finger(id: 9, x: 0.85, y: 0.08, isPalm: true))
        expectNone(withPalm)
        // An unclassified resting palm is a fourth contact.
        var fourth = SwipeTrajectory.swipe(up: true)
        fourth.fingers.append(Finger(id: 9, x: 0.85, y: 0.02))
        expectNone(fourth)
        // A resting bottom-edge contact beside two moving fingers never agrees with them.
        let edge = SwipeTrajectory(fingers: [
            Finger(id: 1, x: 0.45, y: 0.4, dy: 0.3), Finger(id: 2, x: 0.58, y: 0.42, dy: 0.3, land: 0.02),
            Finger(id: 3, x: 0.2, y: 0.01, land: 0.05)
        ])
        expectNone(edge)
    }

    @Test func twoFingerScrollWithRestingThumbDoesNotTrigger() {
        for dy in [0.35, -0.35] {
            let startY = dy > 0 ? 0.3 : 0.75
            // Thumb lands first, inside the landing window.
            expectNone(SwipeTrajectory(fingers: [
                Finger(id: 1, x: 0.3, y: 0.05),
                Finger(id: 2, x: 0.5, y: startY, dy: dy, land: 0.03),
                Finger(id: 3, x: 0.62, y: startY + 0.02, dy: dy, land: 0.05)
            ], moveStart: 0.06, duration: 0.3))
            // Thumb drifts a little with the scroll.
            expectNone(SwipeTrajectory(fingers: [
                Finger(id: 1, x: 0.3, y: 0.05, dx: 0.01, dy: dy * 0.18),
                Finger(id: 2, x: 0.5, y: startY, dy: dy),
                Finger(id: 3, x: 0.62, y: startY + 0.02, dy: dy, land: 0.02)
            ], duration: 0.3))
            // Thumb lands mid-scroll, after the landing window.
            expectNone(SwipeTrajectory(fingers: [
                Finger(id: 2, x: 0.5, y: startY, dy: dy),
                Finger(id: 3, x: 0.62, y: startY + 0.02, dy: dy, land: 0.01),
                Finger(id: 1, x: 0.3, y: 0.05, land: 0.3)
            ], duration: 0.6))
            // A plain two-finger scroll, fast and slow.
            for duration in [0.08, 0.5] {
                expectNone(SwipeTrajectory(fingers: [
                    Finger(id: 2, x: 0.5, y: startY, dy: dy), Finger(id: 3, x: 0.62, y: startY + 0.02, dy: dy)
                ], duration: duration))
            }
        }
    }

    @Test func fourFingerSwipesDoNotTrigger() {
        for up in [true, false] {
            for fourthLanding in [0.0, 0.03, 0.05] {
                var four = SwipeTrajectory.swipe(up: up, moveStart: 0.02)
                four.fingers.append(Finger(id: 4, x: 0.74, y: up ? 0.28 : 0.68, dy: up ? 0.25 : -0.25,
                                           land: fourthLanding))
                expectNone(four)
            }
        }
    }

    @Test func partialAndAbortedSwipesDoNotTrigger() {
        // Short, slow movement.
        expectNone(.swipe(up: true, travel: 0.06, duration: 0.5))
        expectNone(.swipe(up: false, travel: 0.06, duration: 0.5))
        // Very short movement, even if quick.
        expectNone(.swipe(up: true, travel: 0.035, duration: 0.05))
        // A finger lifts before the stroke completes.
        var lifted = SwipeTrajectory.swipe(up: true, travel: 0.3, duration: 0.4)
        lifted.fingers[2].lift = 0.1
        expectNone(lifted)
        // Third finger lands after the window.
        expectNone(.swipe(up: true, landings: (0, 0.05, 0.25), moveStart: 0.26))
    }

    @Test func jitterOnlyRestingFingersDoNotTrigger() {
        var resting = SwipeTrajectory.swipe(up: true, travel: 0, duration: 1.2)
        resting.jitter = 0.004
        expectNone(resting)
    }

    @Test func horizontalAndDiagonalThreeFingerSwipesDoNotTrigger() {
        for dx in [0.3, -0.3] {
            var horizontal = SwipeTrajectory.swipe(up: true, travel: 0.03)
            for index in horizontal.fingers.indices { horizontal.fingers[index].dx = dx }
            expectNone(horizontal)
            var diagonal = SwipeTrajectory.swipe(up: dx > 0, travel: 0.25)
            for index in diagonal.fingers.indices { diagonal.fingers[index].dx = dx * 0.8 }
            expectNone(diagonal)
        }
        // Horizontal first, then vertical, stays rejected.
        let elbow = SwipeTrajectory(fingers: (0..<3).map {
            Finger(id: Int32($0 + 1), x: 0.2 + Double($0) * 0.12, y: 0.3, dx: 0.12, land: 0)
        }, duration: 0.15)
        var recognizer = ThreeFingerSwipe()
        var frames = elbow.frames()
        let finger = frames.removeLast()
        let base = frames.last!.0
        let held = frames.last!.1
        var results: [ThreeFingerSwipeDirection] = []
        for (time, contacts) in frames {
            if let direction = recognizer.update(timestamp: time, contacts: contacts) { results.append(direction) }
        }
        for step in 1...30 {
            let moved = held.map { SwipeContact(id: $0.id, x: $0.x, y: $0.y + Double(step) * 0.01) }
            if let direction = recognizer.update(timestamp: base + Double(step) / 120, contacts: moved) { results.append(direction) }
        }
        _ = recognizer.update(timestamp: base + 31.0 / 120, contacts: finger.1)
        #expect(results.isEmpty)
    }

    @Test func variedTwoFingerScrollsWithRestingThumbNeverTrigger() {
        var random = SeededRandom(seed: 0xbad)
        var falsePositives = 0
        for attempt in 0..<60 {
            let dy = (attempt.isMultiple(of: 2) ? 1.0 : -1.0) * random.next(in: 0.15...0.45)
            let startY = dy > 0 ? random.next(in: 0.2...0.45) : random.next(in: 0.6...0.85)
            let thumbDrift = dy * random.next(in: 0...0.2)
            let trajectory = SwipeTrajectory(fingers: [
                Finger(id: 1, x: random.next(in: 0.05...0.3), y: random.next(in: 0.0...0.12),
                       dx: random.next(in: -0.02...0.02), dy: thumbDrift, land: random.next(in: 0...0.15)),
                Finger(id: 2, x: 0.5, y: startY, dy: dy),
                Finger(id: 3, x: 0.63, y: startY + 0.02, dy: dy * random.next(in: 0.85...1), land: random.next(in: 0...0.05))
            ], moveStart: random.next(in: 0...0.1), duration: random.next(in: 0.08...0.6),
               frameInterval: [1.0 / 90, 1.0 / 120, 1.0 / 250][attempt % 3], seed: UInt64(attempt + 100))
            if !trajectory.replay().isEmpty { falsePositives += 1 }
        }
        #expect(falsePositives == 0)
    }
}

/// Deterministic generator so failures reproduce.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
