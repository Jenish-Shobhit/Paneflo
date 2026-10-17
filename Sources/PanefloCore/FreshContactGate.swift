/// State reported by the validated contact adapter. A new contact must first be
/// observed in `began`; continuing contacts alone cannot prove a fresh stroke.
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

/// Bounded startup gate for a three-contact recognizer. A frame of held contacts
/// quarantines input until a finger-free frame. Each newly appearing identifier
/// must carry make-touch evidence, including staggered landings.
public struct FreshContactGate: Sendable {
    private var quarantined = false
    private var first: Int32?
    private var second: Int32?
    private var third: Int32?

    public init() {}

    public mutating func reset() {
        quarantined = false
        first = nil; second = nil; third = nil
    }

    public mutating func accepts<C: Collection>(_ contacts: C) -> Bool
        where C.Element == SwipeContactEvidence {
        if contacts.isEmpty {
            reset()
            return true
        }
        guard !quarantined, contacts.count <= 3 else { quarantine(); return false }
        var next = FreshContactGate()
        for contact in contacts {
            let wasPresent = contact.id == first || contact.id == second || contact.id == third
            guard wasPresent || contact.phase == .began,
                  contact.id != next.first, contact.id != next.second, contact.id != next.third else {
                quarantine(); return false
            }
            if next.first == nil { next.first = contact.id }
            else if next.second == nil { next.second = contact.id }
            else { next.third = contact.id }
        }
        first = next.first; second = next.second; third = next.third
        return true
    }

    private mutating func quarantine() {
        quarantined = true
        first = nil; second = nil; third = nil
    }
}
