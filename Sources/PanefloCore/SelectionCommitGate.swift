/// Focus is deferred until actual completion of the latest selected-window arrangement.
/// Carries identities only; callers must revalidate the returned identity before focusing.
public struct SelectionCommitGate: Sendable {
    private var generation: UInt64 = 0
    private var pending: UInt64?
    private var deferred: WindowIdentity?
    public init() {}
    public mutating func beginPlacement() -> UInt64 {
        generation &+= 1; pending = generation
        return generation
    }
    public mutating func commit(_ selected: WindowIdentity) -> WindowIdentity? {
        guard pending != nil else { return selected }
        deferred = selected
        return nil
    }
    public mutating func finishPlacement(_ token: UInt64) -> WindowIdentity? {
        guard pending == token else { return nil }
        pending = nil
        defer { deferred = nil }
        return deferred
    }
    public mutating func cancelCommit() { deferred = nil }
}
