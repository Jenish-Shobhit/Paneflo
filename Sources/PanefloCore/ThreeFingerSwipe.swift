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

/// A conservative, allocation-free state machine. No timing source or device APIs.
/// Stationary staggered landing can arm briefly; scrolling invalidates the sequence until lift.
public struct ThreeFingerSwipe: Sendable {
    public struct Configuration: Sendable {
        public var armingDuration: Double = 0.1
        public var maximumArmingTravel: Double = 0.02
        public var minimumTravel: Double = 0.13
        public var minimumDuration: Double = 0.05
        public var maximumDuration: Double = 1.2
        public var maximumFrameGap: Double = 0.15
        public var verticalDominance: Double = 3
        public var maximumTravelSpread: Double = 0.06
        public init() {}
    }
    private struct Origin: Sendable {
        var contact: SwipeContact
        var displacement: Double = 0
    }
    private enum Phase: Sendable {
        case idle, arming, tracking, waitingForLift
    }
    private var phase: Phase = .idle
    private var first: Origin?
    private var second: Origin?
    private var third: Origin?
    private var began: Double = 0
    private var previousTimestamp: Double?
    private let configuration: Configuration
    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    /// Sleep, lock, disable, device loss and corrupt frames cancel any active sequence.
    public mutating func reset() {
        phase = .waitingForLift
        first = nil; second = nil; third = nil; previousTimestamp = nil
    }

    /// Accepts arrays or borrowed buffers without constructing an intermediate array.
    public mutating func update<C: Collection>(timestamp: Double, contacts: C) -> ThreeFingerSwipeDirection?
        where C.Element == SwipeContact {
        guard timestamp.isFinite else { reset(); return nil }
        if let previousTimestamp,
           timestamp <= previousTimestamp || timestamp - previousTimestamp > configuration.maximumFrameGap {
            reset()
        }
        previousTimestamp = timestamp
        if contacts.isEmpty {
            phase = .idle; first = nil; second = nil; third = nil
            return nil
        }
        guard phase != .waitingForLift else { return nil }
        guard (1...3).contains(contacts.count) else { reset(); previousTimestamp = timestamp; return nil }
        for contact in contacts {
            guard !contact.isPalm, contact.x.isFinite, contact.y.isFinite,
                  (0...1).contains(contact.x), (0...1).contains(contact.y) else {
                reset(); previousTimestamp = timestamp; return nil
            }
        }
        // IDs must be unique before either arming or tracking.
        for contact in contacts {
            var matches = 0
            for other in contacts where other.id == contact.id { matches += 1 }
            guard matches == 1 else { reset(); return nil }
        }
        if phase == .idle {
            began = timestamp
            phase = .arming
        }
        if phase == .arming {
            guard timestamp - began <= configuration.armingDuration else { reset(); return nil }
            // Every previously landed finger must remain present and stationary.
            func stationary(_ origin: Origin?) -> Bool {
                guard let origin else { return true }
                guard let current = contacts.first(where: { $0.id == origin.contact.id }) else { return false }
                return abs(current.x - origin.contact.x) <= configuration.maximumArmingTravel
                    && abs(current.y - origin.contact.y) <= configuration.maximumArmingTravel
            }
            guard stationary(first), stationary(second), stationary(third) else { reset(); return nil }
            for contact in contacts {
                if first?.contact.id == contact.id || second?.contact.id == contact.id || third?.contact.id == contact.id { continue }
                if first == nil { first = Origin(contact: contact) }
                else if second == nil { second = Origin(contact: contact) }
                else if third == nil { third = Origin(contact: contact) }
            }
            guard contacts.count == 3 else { return nil }
            // Once all three have landed, movement starts from their current positions.
            var iterator = contacts.makeIterator()
            first = iterator.next().map { Origin(contact: $0) }
            second = iterator.next().map { Origin(contact: $0) }
            third = iterator.next().map { Origin(contact: $0) }
            began = timestamp; phase = .tracking
            return nil
        }
        guard contacts.count == 3 else { reset(); return nil }
        guard timestamp - began <= configuration.maximumDuration,
              var one = first, var two = second, var three = third else { reset(); return nil }
        var maximumHorizontal: Double = 0
        for contact in contacts {
            let origin: SwipeContact
            if contact.id == one.contact.id { origin = one.contact; one.displacement = contact.y - origin.y }
            else if contact.id == two.contact.id { origin = two.contact; two.displacement = contact.y - origin.y }
            else if contact.id == three.contact.id { origin = three.contact; three.displacement = contact.y - origin.y }
            else { reset(); return nil }
            maximumHorizontal = max(maximumHorizontal, abs(contact.x - origin.x))
        }
        let low = min(one.displacement, two.displacement, three.displacement)
        let high = max(one.displacement, two.displacement, three.displacement)
        let weakestTravel = low > 0 ? low : high < 0 ? -high : 0
        guard weakestTravel >= configuration.minimumTravel else { return nil }
        guard timestamp - began >= configuration.minimumDuration else { return nil }
        guard high - low <= configuration.maximumTravelSpread,
              weakestTravel >= maximumHorizontal * configuration.verticalDominance else {
            reset(); return nil
        }
        phase = .waitingForLift
        return low > 0 ? .up : .down
    }
}
