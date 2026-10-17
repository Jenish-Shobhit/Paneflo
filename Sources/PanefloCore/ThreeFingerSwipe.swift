/// Coordinates use normalized trackpad space, with positive y pointing up.
public enum ThreeFingerSwipeDirection: Sendable, Equatable { case up, down }

public struct SwipeContact: Sendable, Equatable {
    public var id: Int32
    public var x: Double
    public var y: Double
    /// Set only by a device adapter whose contact classification has been validated.
    public var isPalm: Bool
    public init(id: Int32, x: Double, y: Double, isPalm: Bool = false) {
        self.id = id; self.x = x; self.y = y; self.isPalm = isPalm
    }
}

/// Allocation-free three-finger vertical swipe recognizer. No timing source or device APIs.
///
/// A stroke starts at the first contact after a finger-free frame. All three fingers must land
/// within `landingWindow`, and fingers may already move while landing: every finger's travel is
/// measured from its own landing position. The decision uses the centroid (mean of the three
/// displacements), so curled fingertips and unequal travel still count, while per-finger agreement
/// rejects a resting thumb or palm beside two scrolling fingers. A stroke fires at most once and
/// then waits for every finger to lift. Four or more contacts, a palm, a lifted finger, a new finger
/// after landing, a horizontal swipe or a stalled stroke end the stroke until lift.
public struct ThreeFingerSwipe: Sendable {
    public struct Configuration: Sendable {
        /// Time from the first landing until the third finger must have landed.
        public var landingWindow: Double = 0.2
        /// Centroid vertical travel that recognizes a deliberate swipe.
        public var minimumTravel: Double = 0.1
        /// A quick flick may recognize with this much centroid travel at `flickVelocity`.
        public var flickTravel: Double = 0.05
        /// Centroid vertical speed, in normalized pad heights per second.
        public var flickVelocity: Double = 1.0
        /// Span of the recent velocity estimate. The estimate uses 0.5–1× this span.
        public var velocityWindow: Double = 0.04
        /// Time all three fingers must have been down before recognition.
        public var minimumTrackingDuration: Double = 0.03
        /// Time from the first landing after which an unrecognized stroke is abandoned.
        public var maximumDuration: Double = 1.5
        public var maximumFrameGap: Double = 0.15
        /// Centroid |dy| must be at least this multiple of centroid |dx|.
        public var verticalDominance: Double = 1.6
        /// Every finger must travel in the swipe direction at least this share of centroid travel.
        public var minimumFingerShare: Double = 0.4
        /// Difference between the longest and shortest finger travel, as a share of centroid travel.
        public var maximumSpreadRatio: Double = 0.9
        /// Centroid horizontal travel that, when it dominates, marks a horizontal swipe.
        public var horizontalAbortTravel: Double = 0.08
        /// Adapters may report contacts slightly outside the unit square at the pad's edge.
        public var coordinateTolerance: Double = 0.1
        public init() {}
    }

    private struct Finger: Sendable {
        var id: Int32
        var landingX: Double, landingY: Double
        var x: Double, y: Double
    }
    private struct Sample: Sendable { var time: Double; var y: Double }
    private enum Phase: Sendable { case idle, landing, tracking, waitingForLift }

    private var phase: Phase = .idle
    private var first: Finger?
    private var second: Finger?
    private var third: Finger?
    private var firstLanding: Double = 0
    private var allLanded: Double = 0
    private var olderSample: Sample?
    private var newerSample: Sample?
    private var previousTimestamp: Double?
    private let configuration: Configuration
    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    /// Sleep, lock, disable, device loss and corrupt frames cancel any active sequence.
    public mutating func reset() {
        endStroke()
        previousTimestamp = nil
    }

    private mutating func endStroke() {
        phase = .waitingForLift
        first = nil; second = nil; third = nil
        olderSample = nil; newerSample = nil
    }

    /// Accepts arrays or borrowed buffers without constructing an intermediate array.
    public mutating func update<C: Collection>(timestamp: Double, contacts: C) -> ThreeFingerSwipeDirection?
        where C.Element == SwipeContact {
        guard timestamp.isFinite else { reset(); return nil }
        // Finger-free idle may produce no callbacks; only an in-flight sequence expires.
        // A regressed clock still quarantines even a fresh stroke.
        if let previousTimestamp,
           timestamp <= previousTimestamp || (phase != .idle && timestamp - previousTimestamp > configuration.maximumFrameGap) {
            reset()
        }
        previousTimestamp = timestamp
        if contacts.isEmpty {
            phase = .idle; first = nil; second = nil; third = nil
            olderSample = nil; newerSample = nil
            return nil
        }
        guard phase != .waitingForLift else { return nil }
        guard contacts.count <= 3 else { endStroke(); return nil }
        let low = -configuration.coordinateTolerance, high = 1 + configuration.coordinateTolerance
        for contact in contacts {
            guard !contact.isPalm, contact.x.isFinite, contact.y.isFinite,
                  (low...high).contains(contact.x), (low...high).contains(contact.y) else {
                endStroke(); return nil
            }
            var matches = 0
            for other in contacts where other.id == contact.id { matches += 1 }
            guard matches == 1 else { endStroke(); return nil }
        }
        if phase == .idle {
            phase = .landing
            firstLanding = timestamp
        }
        // A finger that lifts before recognition ends the stroke.
        guard isPresent(first, in: contacts), isPresent(second, in: contacts), isPresent(third, in: contacts) else {
            endStroke(); return nil
        }
        for contact in contacts {
            if update(&first, with: contact) || update(&second, with: contact) || update(&third, with: contact) { continue }
            // A finger that arrives after all three have landed is a different gesture.
            guard phase == .landing else { endStroke(); return nil }
            let finger = Finger(id: contact.id, landingX: contact.x, landingY: contact.y, x: contact.x, y: contact.y)
            if first == nil { first = finger } else if second == nil { second = finger } else { third = finger }
        }
        if phase == .landing {
            guard timestamp - firstLanding <= configuration.landingWindow else { endStroke(); return nil }
            guard third != nil else { return nil }
            phase = .tracking
            allLanded = timestamp
        }
        guard timestamp - firstLanding <= configuration.maximumDuration,
              let one = first, let two = second, let three = third else { endStroke(); return nil }

        let dy1 = one.y - one.landingY, dy2 = two.y - two.landingY, dy3 = three.y - three.landingY
        let dx = ((one.x - one.landingX) + (two.x - two.landingX) + (three.x - three.landingX)) / 3
        let dy = (dy1 + dy2 + dy3) / 3
        let velocity = recordVelocity(timestamp: timestamp, centroidY: dy)
        // A horizontal three-finger swipe never turns into a vertical one.
        if abs(dx) >= configuration.horizontalAbortTravel && abs(dx) > abs(dy) { endStroke(); return nil }
        guard timestamp - allLanded >= configuration.minimumTrackingDuration else { return nil }

        let travel = abs(dy)
        guard travel > 0 else { return nil }
        let sign: Double = dy > 0 ? 1 : -1
        let flick = travel >= configuration.flickTravel && velocity * sign >= configuration.flickVelocity
        guard travel >= configuration.minimumTravel || flick,
              travel >= abs(dx) * configuration.verticalDominance else { return nil }
        let along1 = dy1 * sign, along2 = dy2 * sign, along3 = dy3 * sign
        let shortest = min(along1, along2, along3), longest = max(along1, along2, along3)
        guard shortest >= travel * configuration.minimumFingerShare,
              longest - shortest <= travel * configuration.maximumSpreadRatio else { return nil }
        endStroke()
        return dy > 0 ? .up : .down
    }

    private func isPresent<C: Collection>(_ finger: Finger?, in contacts: C) -> Bool where C.Element == SwipeContact {
        guard let finger else { return true }
        return contacts.contains { $0.id == finger.id }
    }

    private func update(_ finger: inout Finger?, with contact: SwipeContact) -> Bool {
        guard var current = finger, current.id == contact.id else { return false }
        current.x = contact.x; current.y = contact.y
        finger = current
        return true
    }

    /// Centroid velocity over the most recent 0.5–1 velocity windows, independent of frame rate.
    private mutating func recordVelocity(timestamp: Double, centroidY: Double) -> Double {
        let sample = Sample(time: timestamp, y: centroidY)
        guard let newer = newerSample else { newerSample = sample; return 0 }
        if timestamp - newer.time >= configuration.velocityWindow / 2 {
            olderSample = newer; newerSample = sample
        }
        guard let older = olderSample ?? newerSample, timestamp > older.time else { return 0 }
        return (centroidY - older.y) / (timestamp - older.time)
    }
}
