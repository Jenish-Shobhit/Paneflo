import Foundation
import PanefloCore

/// Tile pairs for the surfaces: the pair registry (reconciled on every registry snapshot), the held switcher's
/// snap assist, and the "raise together" setting. Main-actor state read on input; it makes no Accessibility or
/// window-server call itself.
@MainActor
final class TilePairController {
    static let raiseTogetherKey = "tilePairs.raiseTogether"

    private(set) var groups = TileGroupRegistry()
    private(set) var snap = SnapAssistSession()
    private let defaults: UserDefaults
    /// Cached so activation never reads `UserDefaults`.
    private var raiseTogetherValue: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        raiseTogetherValue = defaults.object(forKey: Self.raiseTogetherKey) as? Bool ?? true
    }

    /// Opening a paired window brings its partner forward too (default on).
    var raiseTogether: Bool {
        get { raiseTogetherValue }
        set { raiseTogetherValue = newValue; defaults.set(newValue, forKey: Self.raiseTogetherKey) }
    }

    var pairingHint: String? { snap.pairingHint }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Registry snapshot changed. Returns true when the pairs changed.
    @discardableResult
    func reconcile(_ snapshot: WindowSnapshot, displays: [DisplayArea]) -> Bool {
        let changed = groups.reconcile(records: snapshot.orderedRecords, displays: displays, now: now)
        if changed, RuntimeDiagnostics.isEnabled { RuntimeDiagnostics.mark("tilePairs groups=\(groups.groups.count)") }
        return changed
    }

    /// The small pair indicator for a card; nil when the window has no partner.
    func badge(for id: WindowIdentity) -> String? { groups.group(containing: id) == nil ? nil : "▮▮ Paired" }

    func isPaired(_ id: WindowIdentity) -> Bool { groups.group(containing: id) != nil }

    /// The window to raise before focusing `target`. `explicit`: the user asked to open the pair.
    func partner(for target: WindowIdentity, explicit: Bool) -> WindowIdentity? {
        PairActivation.partner(for: target, groups: groups, pending: snap.pendingPartner(for: target),
                               raiseTogether: raiseTogether, explicit: explicit)
    }

    @discardableResult
    func ungroup(_ id: WindowIdentity) -> Bool { groups.ungroup(id) }

    // MARK: Snap assist

    /// Returns the request and the token to pass back to `didTile`.
    func willTile(_ id: WindowIdentity, zone: LayoutZone) -> (SnapAssistSession.Request, UInt64) {
        let request = snap.willTile(id, zone: zone)
        return (request, snap.requests)
    }
    func willRestore(_ id: WindowIdentity?) { snap.willRestore(id) }
    func resetSnapAssist() { snap.reset() }

    /// A placement finished. Returns true when it formed a pair.
    @discardableResult
    func didTile(_ id: WindowIdentity, zone: LayoutZone, token: UInt64, outcome: TileOutcome?, snapshot: WindowSnapshot,
                 displays: [DisplayArea]) -> Bool {
        if let outcome { groups.notePlacement(id, frame: outcome.frame, now: now) }
        guard let formation = snap.didTile(id, zone: zone, display: outcome?.display, request: token) else { return false }
        let formed = groups.form(formation.first, formation.second, records: snapshot.orderedRecords,
                                 displays: displays, now: now) != nil
        RuntimeDiagnostics.mark("tilePairs snapAssist formed=\(formed)")
        return formed
    }
}
