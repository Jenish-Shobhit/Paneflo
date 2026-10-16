/// User intent and serialized hardware state are independent during suspension.
/// Each pause cycle can request at most one automatic restart.
public struct TrackpadLifecycleGate: Sendable {
    public enum Reason: UInt8, Sendable { case systemSleep = 1, displaySleep = 2, sessionInactive = 4 }
    public enum Phase: Sendable, Equatable { case disabled, starting, active, stopping, paused, failed }
    public enum Effect: Sendable, Equatable { case start, stop }
    public enum Event: Sendable {
        case enable, disable, pause(Reason), wake(Reason), started, startFailed, stopped(clean: Bool)
    }
    public private(set) var isEnabled = false
    public private(set) var phase: Phase = .disabled
    private var reasons: UInt8 = 0
    private var resumeAttempted = false
    public init() {}

    public mutating func send(_ event: Event) -> Effect? {
        switch event {
        case .enable:
            guard !isEnabled else { return nil }
            isEnabled = true; reasons = 0; resumeAttempted = false
            if phase == .stopping { return nil }
            phase = .starting; return .start
        case .disable:
            isEnabled = false; reasons = 0; resumeAttempted = true
            if phase == .stopping || phase == .failed { return nil }
            if phase == .active || phase == .starting { phase = .stopping; return .stop }
            phase = .disabled; return nil
        case .pause(let reason):
            guard isEnabled else { return nil }
            reasons |= reason.rawValue
            if phase == .stopping || phase == .paused { return nil }
            guard phase == .active || phase == .starting else { return nil }
            resumeAttempted = false
            phase = .stopping; return .stop
        case .wake(let reason):
            reasons &= ~reason.rawValue
            return resumeIfReady()
        case .started:
            guard phase == .starting else { return nil }
            phase = .active; return nil
        case .startFailed:
            guard phase == .starting || phase == .active else { return nil }
            isEnabled = false; reasons = 0; resumeAttempted = true; phase = .failed
            return nil
        case .stopped(let clean):
            guard phase == .stopping else { return nil }
            guard clean else {
                isEnabled = false; reasons = 0; resumeAttempted = true; phase = .failed
                return nil
            }
            phase = isEnabled ? .paused : .disabled
            return resumeIfReady()
        }
    }
    private mutating func resumeIfReady() -> Effect? {
        guard isEnabled, phase == .paused, reasons == 0, !resumeAttempted else { return nil }
        resumeAttempted = true; phase = .starting
        return .start
    }
}
