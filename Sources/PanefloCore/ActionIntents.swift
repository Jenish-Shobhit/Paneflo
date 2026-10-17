/// Supersession tokens for interactive window actions. Focus and placement are independent:
/// a focus request never cancels an in-flight placement and a placement never cancels focus,
/// so releasing the switcher focuses immediately while a pending tile completes on its own.
/// A placement is superseded only by a newer placement of the same window; focus only by a
/// newer focus. Callers synchronize access (the worker holds a lock).
public struct ActionIntents: Sendable {
    private var latestFocus: UInt64 = 0
    private var latestPlacement: [WindowIdentity: UInt64] = [:]
    private var placementCounter: UInt64 = 0

    public init() {}

    public var currentFocus: UInt64 { latestFocus }

    public mutating func beginFocus() -> UInt64 {
        latestFocus &+= 1
        return latestFocus
    }

    public mutating func beginPlacement(for id: WindowIdentity) -> UInt64 {
        placementCounter &+= 1
        latestPlacement[id] = placementCounter
        return placementCounter
    }

    public func isCurrentFocus(_ token: UInt64) -> Bool { latestFocus == token }

    public func isCurrentPlacement(_ token: UInt64, for id: WindowIdentity) -> Bool {
        latestPlacement[id] == token
    }

    public mutating func forget(_ id: WindowIdentity) { latestPlacement.removeValue(forKey: id) }
}
