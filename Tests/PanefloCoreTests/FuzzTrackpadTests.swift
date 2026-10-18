import Testing
@testable import PanefloCore

/// ST-05: garbage and property tests for ThreeFingerSwipe and TrackpadFrameSanity.
struct FuzzTrackpadTests {
    private static let weirdDoubles: [Double] = [
        .nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude, .leastNonzeroMagnitude,
        -0.0, 0, 1, -0.05, 1.05, -5, 5, 0.5,
    ]

    private static func garbageContact(_ rng: inout FuzzRandom) -> SwipeContact {
        let id = rng.chance(0.2) ? Int32.min : Int32(rng.int(-3...8))
        func coordinate(_ rng: inout FuzzRandom) -> Double {
            rng.chance(0.6) ? rng.pick(weirdDoubles) : rng.double(-2...3)
        }
        return SwipeContact(id: id, x: coordinate(&rng), y: coordinate(&rng), isPalm: rng.chance(0.2))
    }

    @Test func garbageFramesNeverCrashAndNeverFire() {
        for seed in UInt64(0)..<400 {
            var rng = FuzzRandom(seed: seed)
            var recognizer = ThreeFingerSwipe()
            var t = rng.chance(0.5) ? 100.0 : -50.0
            for step in 0..<150 {
                switch rng.int(0...9) {
                case 0: t = rng.pick(Self.weirdDoubles)
                case 1: t -= rng.double(0...5)
                case 2: break // repeated timestamp
                default: t += rng.double(0.001...0.3)
                }
                var contacts = (0..<rng.int(0...20)).map { _ in Self.garbageContact(&rng) }
                // Force every frame to hold at least one definitely-invalid contact (or an impossible count).
                if contacts.count == 3 {
                    contacts[rng.int(0...2)] = SwipeContact(id: 1, x: rng.pick([.nan, .infinity, 9, -9]), y: 0.5)
                }
                let direction = recognizer.update(timestamp: t, contacts: contacts)
                #expect(direction == nil, "seed \(seed) step \(step): fired on garbage (\(contacts.count) contacts, t=\(t))")
                if rng.chance(0.02) { recognizer.reset() }
            }
        }
    }

    @Test func mixedValidStreamsEmitOnlyWithThreeValidContactsAndOncePerStroke() {
        for seed in UInt64(0)..<400 {
            var rng = FuzzRandom(seed: seed)
            var recognizer = ThreeFingerSwipe()
            var t = 10.0
            var emittedThisStroke = false
            for step in 0..<400 {
                t += rng.double(0.004...0.03)
                let count = rng.pick([0, 1, 2, 3, 3, 3, 3, 4])
                let contacts = (0..<count).map { i in
                    SwipeContact(id: Int32(i + 1), x: rng.double(0...1), y: rng.double(0...1), isPalm: rng.chance(0.01))
                }
                if contacts.isEmpty { emittedThisStroke = false }
                if recognizer.update(timestamp: t, contacts: contacts) != nil {
                    #expect(contacts.count == 3 && contacts.allSatisfy { !$0.isPalm }, "seed \(seed) step \(step): emitted without three valid contacts")
                    #expect(!emittedThisStroke, "seed \(seed) step \(step): second emission before lift")
                    emittedThisStroke = true
                }
            }
        }
    }

    @Test func scaledAndTranslatedValidSwipesStillRecognize() {
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            let up = rng.chance(0.5)
            let travel = rng.double(0.2...0.4)
            let centerX = rng.double(0.3...0.7)
            let interval = 1.0 / rng.double(60...250)
            let start = rng.pick([0.5, 10, 12_345.6, 1_000_000])
            let trajectory = SwipeTrajectory.swipe(up: up, travel: travel, startY: up ? rng.double(0.1...0.45) : rng.double(0.55...0.9),
                                                   centerX: centerX, fan: rng.double(-0.02...0.02),
                                                   landings: (0, rng.double(0...0.05), rng.double(0...0.08)),
                                                   duration: rng.double(0.18...0.45), frameInterval: interval, seed: seed)
            var recognizer = ThreeFingerSwipe()
            let results = trajectory.replay(&recognizer, startingAt: start)
            #expect(results == [up ? .up : .down], "seed \(seed): up=\(up) travel=\(travel) interval=\(interval) got \(results)")

            // Mirroring y swaps the direction; translating x changes nothing.
            var mirrored = ThreeFingerSwipe()
            var mirroredResults: [ThreeFingerSwipeDirection] = []
            for (time, contacts) in trajectory.frames(startingAt: start) {
                let flipped = contacts.map { SwipeContact(id: $0.id, x: $0.x, y: 1 - $0.y, isPalm: $0.isPalm) }
                if let d = mirrored.update(timestamp: time, contacts: flipped) { mirroredResults.append(d) }
            }
            #expect(mirroredResults == [up ? .down : .up], "seed \(seed): mirror differs, got \(mirroredResults)")
        }
    }

    @Test func twoFingersWithRestingThumbNeverFire() {
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            let up = rng.chance(0.5)
            let thumb = rng.int(0...2)
            var shares = (1.0, 1.0, 1.0)
            switch thumb { case 0: shares.0 = 0; case 1: shares.1 = 0; default: shares.2 = 0 }
            let trajectory = SwipeTrajectory.swipe(up: up, travel: rng.double(0.15...0.45), shares: shares,
                                                   landings: (0, rng.double(0...0.05), rng.double(0...0.1)),
                                                   duration: rng.double(0.15...0.5), seed: seed)
            #expect(trajectory.replay().isEmpty, "seed \(seed): resting thumb at \(thumb) fired")
        }
    }

    @Test func aStationaryFourthFingerAlwaysRejects() {
        for seed in UInt64(0)..<100 {
            var rng = FuzzRandom(seed: seed)
            var trajectory = SwipeTrajectory.swipe(up: rng.chance(0.5), travel: 0.3, seed: seed)
            trajectory.fingers.append(.init(id: 4, x: rng.double(0.05...0.95), y: rng.double(0.05...0.95)))
            #expect(trajectory.replay().isEmpty, "seed \(seed): four contacts fired")
        }
    }

    @Test func frameSanityTakesArbitraryBytesWithoutTrapping() {
        let weird: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0, -0.0, 1, -1, 1e-40]
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            var sanity = TrackpadFrameSanity()
            var settled: TrackpadFrameSanity.Verdict?
            for _ in 0..<60 {
                if rng.chance(0.9) { sanity.beginFrame() }
                for _ in 0..<rng.int(0...8) {
                    func f() -> Float { rng.chance(0.4) ? weird[rng.int(0...weird.count - 1)] : Float(rng.double(-1...2)) }
                    sanity.observe(.init(id: rng.chance(0.2) ? Int32.min : Int32(rng.int(-5...70_000)), state: Int32(rng.int(-3...9)),
                                         x: f(), y: f(), size: f(), majorAxis: f(), minorAxis: f()))
                }
                if rng.chance(0.9) { sanity.endFrame() }
                if let settled { #expect(sanity.verdict == settled, "seed \(seed): verdict changed after settling") }
                else if sanity.verdict != .pending { settled = sanity.verdict }
            }
        }
    }

    @Test func smoothValidLayoutBecomesPlausibleAndDuplicateIdsAreRejected() {
        var good = TrackpadFrameSanity()
        for frame in 0..<20 {
            good.beginFrame()
            for finger in 0..<3 {
                good.observe(.init(id: Int32(finger + 1), state: 4, x: 0.3 + Float(finger) * 0.1 + Float(frame) * 0.005,
                                   y: 0.4, size: 0.5, majorAxis: 6, minorAxis: 5))
            }
            good.endFrame()
        }
        #expect(good.verdict == .plausible)
        var bad = TrackpadFrameSanity()
        bad.beginFrame()
        for _ in 0..<2 { bad.observe(.init(id: 7, state: 4, x: 0.5, y: 0.5, size: 0.5, majorAxis: 5, minorAxis: 5)) }
        bad.endFrame()
        if case .implausible = bad.verdict {} else { fail("duplicate identifiers must be implausible, got \(bad.verdict)") }
    }
}
