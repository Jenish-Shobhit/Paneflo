@testable import PanefloCore

/// Synthetic contact-frame trajectories for replay tests. They model the shapes that matter to the
/// recognizer (staggered landing, movement during landing, unequal and curled travel, fanning,
/// eased velocity, sensor jitter, resting contacts) rather than any recorded session.
struct SwipeTrajectory {
    struct Finger {
        var id: Int32
        var x: Double
        var y: Double
        /// Total displacement over the motion.
        var dx: Double = 0
        var dy: Double = 0
        /// Seconds after the stroke starts at which this finger touches down.
        var land: Double = 0
        /// Seconds after the stroke starts at which this finger lifts; nil lifts with the stroke.
        var lift: Double? = nil
        var isPalm = false
    }

    var fingers: [Finger]
    /// Motion starts at `moveStart` and lasts `duration`, with a smooth ease-in/ease-out.
    var moveStart: Double = 0.03
    var duration: Double = 0.25
    /// Contacts stay down this long after motion completes.
    var hold: Double = 0.05
    var frameInterval: Double = 1.0 / 120
    var jitter: Double = 0.0015
    var seed: UInt64 = 1

    /// Frames from a finger-free frame through the stroke to a finger-free frame.
    func frames(startingAt start: Double = 10) -> [(Double, [SwipeContact])] {
        var generator = seed &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> Double {
            generator = generator &* 6364136223846793005 &+ 1442695040888963407
            return (Double(generator >> 11) / Double(1 << 53) - 0.5) * 2 * jitter
        }
        let end = moveStart + duration + hold
        var result: [(Double, [SwipeContact])] = [(start - frameInterval, [])]
        var t = 0.0
        while t <= end + 1e-9 {
            let progress = min(max((t - moveStart) / duration, 0), 1)
            let eased = progress * progress * (3 - 2 * progress)
            var contacts: [SwipeContact] = []
            for finger in fingers where t >= finger.land - 1e-9 && t < (finger.lift ?? .infinity) {
                contacts.append(.init(id: finger.id, x: finger.x + finger.dx * eased + noise(),
                                      y: finger.y + finger.dy * eased + noise(), isPalm: finger.isPalm))
            }
            result.append((start + t, contacts))
            t += frameInterval
        }
        result.append((start + t, []))
        return result
    }

    /// Replays the frames and returns every recognition.
    func replay(_ recognizer: inout ThreeFingerSwipe, startingAt start: Double = 10) -> [ThreeFingerSwipeDirection] {
        var results: [ThreeFingerSwipeDirection] = []
        for (time, contacts) in frames(startingAt: start) {
            if let direction = recognizer.update(timestamp: time, contacts: contacts) { results.append(direction) }
        }
        return results
    }

    func replay() -> [ThreeFingerSwipeDirection] {
        var recognizer = ThreeFingerSwipe()
        return replay(&recognizer)
    }

    // MARK: Shapes

    /// Three fingers side by side moving vertically. `travel` is per finger before `shares`.
    static func swipe(up: Bool, travel: Double = 0.25, startY: Double? = nil, centerX: Double = 0.5,
                      shares: (Double, Double, Double) = (1, 1, 1), fan: Double = 0,
                      landings: (Double, Double, Double) = (0, 0, 0), moveStart: Double = 0.03,
                      duration: Double = 0.25, drift: Double = 0, frameInterval: Double = 1.0 / 120,
                      seed: UInt64 = 1) -> SwipeTrajectory {
        let sign: Double = up ? 1 : -1
        let y = startY ?? (up ? 0.3 : 0.7)
        let shareList = [shares.0, shares.1, shares.2]
        let landList = [landings.0, landings.1, landings.2]
        let fingers = (0..<3).map { index -> Finger in
            let offset = Double(index - 1)
            // Middle finger sits slightly higher, like a real hand.
            return Finger(id: Int32(index + 1), x: centerX + offset * 0.12, y: y + (index == 1 ? 0.03 : 0),
                          dx: offset * fan + drift, dy: sign * travel * shareList[index], land: landList[index])
        }
        return SwipeTrajectory(fingers: fingers, moveStart: moveStart, duration: duration,
                               frameInterval: frameInterval, seed: seed)
    }
}
