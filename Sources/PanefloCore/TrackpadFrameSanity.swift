/// One decoded contact record, as read from the private contact-frame layout.
public struct TrackpadContactSample: Sendable, Equatable {
    public var id: Int32
    public var state: Int32
    public var x: Float
    public var y: Float
    public var size: Float
    public var majorAxis: Float
    public var minorAxis: Float
    public init(id: Int32, state: Int32, x: Float, y: Float, size: Float, majorAxis: Float, minorAxis: Float) {
        self.id = id; self.state = state; self.x = x; self.y = y
        self.size = size; self.majorAxis = majorAxis; self.minorAxis = minorAxis
    }
}

/// Runtime sanity check of the private contact-frame layout, replacing an exact framework-version
/// match. Over the first `requiredFrames` frames that carry contacts it checks that identifiers are
/// small and unique within a frame, touching contacts have positive size and axis, and each
/// identifier's position moves smoothly between frames. A wrong stride or field offset produces
/// out-of-range, duplicated or jumping values. Values out of hard range are rejected by the adapter
/// before they reach this check. Allocation-free; tracks at most four identifiers per frame.
public struct TrackpadFrameSanity: Sendable {
    public enum Verdict: Sendable, Equatable { case pending, plausible, implausible(String) }
    public struct Configuration: Sendable {
        public var requiredFrames = 12
        public var maximumIdentifier: Int32 = 0xFFFF
        /// Largest plausible per-frame movement of one identifier, in normalized pad units.
        public var maximumStep: Float = 0.25
        public var minimumSmoothShare = 0.9
        public var minimumTouchingGeometryShare = 0.8
        public init() {}
    }
    private struct Tracked: Sendable { var id: Int32; var x: Float; var y: Float }
    private struct Slots: Sendable {
        var a: Tracked?, b: Tracked?, c: Tracked?, d: Tracked?
        func find(_ id: Int32) -> Tracked? {
            if a?.id == id { return a }; if b?.id == id { return b }
            if c?.id == id { return c }; if d?.id == id { return d }
            return nil
        }
        /// False when all four slots are full.
        mutating func insert(_ value: Tracked) -> Bool {
            if a == nil { a = value } else if b == nil { b = value }
            else if c == nil { c = value } else if d == nil { d = value } else { return false }
            return true
        }
    }

    public private(set) var verdict: Verdict = .pending
    private let configuration: Configuration
    private var previous = Slots()
    private var current = Slots()
    private var frameHasContacts = false
    private var frames = 0
    private var steps = 0, smoothSteps = 0
    private var touching = 0, touchingWithGeometry = 0
    private var failure: String?

    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    public mutating func beginFrame() {
        current = Slots()
        frameHasContacts = false
    }

    public mutating func observe(_ sample: TrackpadContactSample) {
        guard verdict == .pending else { return }
        frameHasContacts = true
        guard (0...configuration.maximumIdentifier).contains(sample.id) else {
            failure = failure ?? "contact identifiers were out of range"; return
        }
        guard current.find(sample.id) == nil else {
            failure = failure ?? "a frame repeated a contact identifier"; return
        }
        if sample.state == 4 {
            touching += 1
            if sample.size > 0 && sample.majorAxis > 0 && sample.minorAxis >= 0 { touchingWithGeometry += 1 }
        }
        if let before = previous.find(sample.id) {
            steps += 1
            if abs(sample.x - before.x) <= configuration.maximumStep && abs(sample.y - before.y) <= configuration.maximumStep {
                smoothSteps += 1
            }
        }
        _ = current.insert(.init(id: sample.id, x: sample.x, y: sample.y))
    }

    @discardableResult
    public mutating func endFrame() -> Verdict {
        guard verdict == .pending else { return verdict }
        if let failure { verdict = .implausible(failure); return verdict }
        previous = current
        guard frameHasContacts else { return verdict }
        frames += 1
        guard frames >= configuration.requiredFrames else { return verdict }
        if steps > 0 && Double(smoothSteps) < Double(steps) * configuration.minimumSmoothShare {
            verdict = .implausible("contact positions jumped between frames")
        } else if touching > 0 && Double(touchingWithGeometry) < Double(touching) * configuration.minimumTouchingGeometryShare {
            verdict = .implausible("touching contacts reported no size")
        } else if steps == 0 && touching == 0 {
            // Nothing tracked across frames yet; keep waiting for evidence.
            return verdict
        } else {
            verdict = .plausible
        }
        return verdict
    }
}
