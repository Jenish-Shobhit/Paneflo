/// State reported by the validated contact adapter. `began` is make-touch evidence for a new
/// contact; `continuing` covers touching and break-touch frames.
public enum SwipeContactPhase: Sendable, Equatable {
    case began, continuing
}

public struct SwipeContactEvidence: Sendable, Equatable {
    public var id: Int32
    public var phase: SwipeContactPhase
    public init(id: Int32, phase: SwipeContactPhase) {
        self.id = id
        self.phase = phase
    }
}

/// Bounded startup gate for a three-contact recognizer. It keeps contacts that were already
/// held when observation began (or that arrive without evidence of a fresh touch) away from the
/// recognizer until a finger-free frame.
///
/// A newly appearing identifier is fresh when it carries make-touch evidence, or when the gate has
/// observed a finger-free frame since its last reset: a contact absent from that frame touched down
/// afterwards, so a single dropped make-touch frame does not lose the stroke. At most
/// `maximumUnprovenFramesPerStroke` frames per stroke may introduce identifiers without make-touch
/// evidence; more than that quarantines the stroke.
public struct FreshContactGate: Sendable {
    public var maximumUnprovenFramesPerStroke = 1
    private var quarantined = false
    /// Cleared by `reset()`; set by a finger-free frame.
    private var observedFingerFree = false
    private var unprovenFrames = 0
    private var first: Int32?
    private var second: Int32?
    private var third: Int32?

    public init() {}

    /// Forget all evidence, including the last finger-free frame. Call when observation (re)starts.
    public mutating func reset() {
        quarantined = false
        observedFingerFree = false
        unprovenFrames = 0
        first = nil; second = nil; third = nil
    }

    public mutating func accepts<C: Collection>(_ contacts: C) -> Bool
        where C.Element == SwipeContactEvidence {
        if contacts.isEmpty {
            quarantined = false
            observedFingerFree = true
            unprovenFrames = 0
            first = nil; second = nil; third = nil
            return true
        }
        guard !quarantined, contacts.count <= 3 else { quarantine(); return false }
        var nextFirst: Int32?, nextSecond: Int32?, nextThird: Int32?
        var unprovenInFrame = false
        for contact in contacts {
            guard contact.id != nextFirst, contact.id != nextSecond, contact.id != nextThird else {
                quarantine(); return false
            }
            let wasPresent = contact.id == first || contact.id == second || contact.id == third
            if !wasPresent && contact.phase != .began {
                guard observedFingerFree else { quarantine(); return false }
                unprovenInFrame = true
            }
            if nextFirst == nil { nextFirst = contact.id }
            else if nextSecond == nil { nextSecond = contact.id }
            else { nextThird = contact.id }
        }
        if unprovenInFrame {
            guard unprovenFrames < maximumUnprovenFramesPerStroke else { quarantine(); return false }
            unprovenFrames += 1
        }
        first = nextFirst; second = nextSecond; third = nextThird
        return true
    }

    private mutating func quarantine() {
        quarantined = true
        first = nil; second = nil; third = nil
    }
}
