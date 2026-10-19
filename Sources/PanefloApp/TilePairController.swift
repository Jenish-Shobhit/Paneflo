import Foundation
import PanefloCore

/// Tile pairs for the surfaces: the pair registry (reconciled on every registry snapshot), the held switcher's
/// snap assist, the "raise together" setting, and the one tiling path every arrangement takes (⌘⌥ in the held
/// switcher or the Overview, ⌃⌥ anywhere, the menu bar), which keeps pairs complete: replacement, swap, displaced
/// members and size-limited partners (decision matrix in `TileGroupRegistry.resolve`). Main-actor state read on
/// input; it makes no Accessibility or window-server call itself (placements go through `WindowService`).
@MainActor
final class TilePairController {
    /// Written by Settings › Tiling (Raise tile pairs together).
    static let raiseTogetherKey = SurfacePreferences.Key.raiseTogether

    private(set) var groups = TileGroupRegistry()
    private(set) var snap = SnapAssistSession()
    /// Last floating frame per window: where a displaced pair member goes back to.
    private(set) var homes = TileHomeFrames()
    /// The pairs changed outside a registry snapshot (a tile resolved, an undo re-formed a pair).
    var onPairsChanged: (() -> Void)?
    private let defaults: UserDefaults
    /// Cached so activation never reads `UserDefaults`; refreshed whenever the defaults change.
    private(set) var raiseTogether: Bool
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        raiseTogether = Self.read(defaults)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.raiseTogether = Self.read($0.defaults) } }
        }
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Opening a paired window brings its partner forward too (default on).
    private static func read(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: raiseTogetherKey) as? Bool ?? true
    }


    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Registry snapshot changed. Returns true when the pairs changed.
    @discardableResult
    func reconcile(_ snapshot: WindowSnapshot, displays: [DisplayArea]) -> Bool {
        homes.observe(snapshot.records, displays: displays)
        let changed = groups.reconcile(records: snapshot.orderedRecords, displays: displays, now: now)
        if changed, RuntimeDiagnostics.isEnabled { RuntimeDiagnostics.mark("tilePairs groups=\(groups.groups.count)") }
        return changed
    }

    /// Snap assist is waiting for the other half: the half to fill and the window already placed.
    var pendingHalf: (zone: LayoutZone, anchor: WindowIdentity)? {
        guard let anchor = snap.anchor, snap.partner == nil, let zone = SnapAssistSession.complement(of: anchor.zone) else { return nil }
        return (zone, anchor.id)
    }

    func isPaired(_ id: WindowIdentity) -> Bool { groups.group(containing: id) != nil }

    /// The window to raise before focusing `target`. `explicit`: the user asked to open the pair.
    func partner(for target: WindowIdentity, explicit: Bool) -> WindowIdentity? {
        PairActivation.partner(for: target, groups: groups, pending: snap.pendingPartner(for: target),
                               raiseTogether: raiseTogether, explicit: explicit)
    }

    @discardableResult
    func ungroup(_ id: WindowIdentity) -> Bool { groups.ungroup(id) }

    // MARK: Tiling

    /// Tiles `id` into `zone` and keeps the pairs complete. `snapAssist`: a held-switcher or Overview arrangement
    /// that takes part in snap assist. Steps, in order:
    /// 1. A tile into the partner's half is a swap: the partner's move into the half `id` leaves starts at once, on the
    ///    pair's display, so neither half is empty for long.
    /// 2. `id` is placed. A superseded or failed placement decides nothing.
    /// 3. The landing is resolved against the registry; follow-ups (displaced member home, swap partner, the rest of
    ///    the display beside a size-limited window) are issued only after `id` landed, so the half never shows the
    ///    desktop. Every placement joins one undo operation, which also re-forms the pairs this tile ended.
    /// `display`: tile on this display (index in `WindowService.displayAreas()` order) rather than the window's own,
    /// for a window dropped on a screen edge.
    func tile(_ id: WindowIdentity, zone: LayoutZone, service: WindowService, snapAssist: Bool, display: Int? = nil,
              completion: (@MainActor (TileOutcome?, TileResolution?) -> Void)? = nil) {
        let displays = WindowService.displayAreas()
        let operation = service.beginOperation()
        var explicitDisplay = display
        var token: UInt64 = 0
        if snapAssist {
            let (request, requestToken) = willTile(id, zone: zone)
            explicitDisplay = request.explicitDisplay
            token = requestToken
        }
        if let group = groups.group(containing: id) { service.attachUndoPairs([group.pairMembers], to: operation) }
        if let swap = groups.plannedSwap(for: id, zone: zone, records: service.snapshot.orderedRecords, displays: displays,
                                         explicitDisplay: explicitDisplay, now: now) {
            explicitDisplay = explicitDisplay ?? swap.display
            groups.notePlacement(swap.window, frame: swap.frame, now: now)
            execute(swap, operation: operation, service: service)
            RuntimeDiagnostics.mark("tilePairs swap requested")
        }
        service.tile(id, zone: zone, screenIndex: explicitDisplay, operation: operation) { [weak self] outcome in
            guard let self else { completion?(outcome, nil); return }
            let landed = outcome.flatMap { $0.superseded ? nil : $0 }
            // Snap assist hears every report (a superseded one carries its own, older token and is ignored there).
            let formation = snapAssist ? self.snap.didTile(id, zone: zone, display: outcome?.display, request: token) : nil
            guard let landed, let display = landed.display else { completion?(outcome, nil); return }
            if let before = landed.before { self.homes.note(id, before: before, displays: displays) }
            let preferred = formation.map { $0.first == id ? $0.second : $0.first } ?? (snapAssist ? self.snap.anchor?.id : nil)
            let resolution = self.groups.resolve(
                TileLanding(window: id, zone: zone, display: display, frame: landed.frame, requested: landed.requested),
                records: service.snapshot.orderedRecords, displays: displays, now: self.now,
                busy: service.busyWindows.subtracting([id]), homes: self.homes, preferredPartner: preferred == id ? nil : preferred)
            service.attachUndoPairs(resolution.dissolved, to: operation)
            for move in resolution.moves { self.execute(move, operation: operation, service: service) }
            // A pair completed by this landing ends snap assist: no cue asks for a half that is already taken.
            if resolution.group != nil { self.snap.reset() }
            RuntimeDiagnostics.mark("tilePairs resolved kind=\(resolution.kind.rawValue) moves=\(resolution.moves.count) groups=\(self.groups.groups.count)")
            if resolution.kind != .unpaired || !resolution.dissolved.isEmpty { self.onPairsChanged?() }
            completion?(outcome, resolution)
        }
    }

    /// ⌃⌥ arrangement (or Tile Front Window) of the frontmost window, resolved fresh at keypress time
    /// (`WindowService.resolveFrontmostWindow`), with the same pair handling as the surfaces. `failed` receives the
    /// reason nothing could be resolved; placement failures arrive through `WindowService.onPlacementFailed`.
    /// `notResizable` fires after a window that can only be moved was moved.
    func tileFrontWindow(_ zone: LayoutZone, service: WindowService, failed: @escaping @MainActor (FrontWindowResolution.Failure) -> Void,
                         completion: (@MainActor (TileOutcome?) -> Void)? = nil, notResizable: (@MainActor (WindowRect) -> Void)? = nil) {
        RuntimeDiagnostics.mark("tile chord zone=\(zone.rawValue) standalone")
        service.resolveFrontmostWindow { [weak self] target in
            guard let self else { return }
            switch target {
            case .failure(let failure):
                failed(failure); completion?(nil)
            case .window(let id, let resizable):
                self.tile(id, zone: zone, service: service, snapAssist: false) { outcome, _ in
                    if let outcome {
                        RuntimeDiagnostics.mark("tile front final=x:\(outcome.frame.x),y:\(outcome.frame.y),w:\(outcome.frame.width),h:\(outcome.frame.height)")
                        if !resizable { notResizable?(outcome.frame) }
                    }
                    completion?(outcome)
                }
            }
        }
    }

    /// ⌃⌥Z: undo the frontmost window's last arrangement, resolved fresh (else the most recent arrangement).
    func undoFrontWindow(service: WindowService, failed: @escaping @MainActor (String) -> Void) {
        service.resolveFrontmostWindow { [weak self] target in
            guard let self else { return }
            switch target {
            case .failure(.accessibilityOff): failed(FrontWindowResolution.Failure.accessibilityOff.message)
            case .failure: if !self.undo(preferring: nil, service: service, fallback: true) { failed("Nothing to undo") }
            case .window(let id, _): if !self.undo(preferring: id, service: service, fallback: true) { failed("Nothing to undo") }
            }
        }
    }

    /// Issues one follow-up placement; its real landing replaces the planned frame.
    private func execute(_ move: TileMove, operation: UInt64, service: WindowService) {
        let id = move.window
        service.recordPlanned(id, to: move.frame, operation: operation)
        let landed: @MainActor @Sendable (TileOutcome?) -> Void = { [weak self] outcome in
            guard let self, let outcome, !outcome.superseded else { return }
            self.groups.notePlacement(id, frame: outcome.frame, now: self.now)
        }
        if let zone = move.zone {
            service.tile(id, zone: zone, screenIndex: move.display, operation: operation, completion: landed)
        } else {
            service.place(id, frame: move.frame, operation: operation, completion: landed)
        }
    }

    /// Undoes the preferred window's last arrangement (every window it moved) and re-forms the pairs it ended at once;
    /// the restore frames stand in until the windows report them.
    /// `fallback`: with no history for `preferred`, undo the most recent arrangement instead. Returns false when there
    /// was nothing to undo.
    @discardableResult
    func undo(preferring preferred: WindowIdentity?, service: WindowService, fallback: Bool = false) -> Bool {
        willRestore(preferred)
        guard let (plan, restored) = service.undo(preferring: preferred, fallback: fallback) else { return false }
        guard !plan.pairs.isEmpty else { return true }
        for (id, frame) in restored { groups.notePlacement(id, frame: frame, now: now) }
        let formed = groups.restore(plan.pairs, records: service.snapshot.orderedRecords, displays: WindowService.displayAreas(), now: now)
        RuntimeDiagnostics.mark("tilePairs undo reformed=\(formed.count)")
        if !formed.isEmpty { onPairsChanged?() }
        return true
    }

    // MARK: Snap assist

    /// Returns the request and the token to pass back to `SnapAssistSession.didTile`.
    func willTile(_ id: WindowIdentity, zone: LayoutZone) -> (SnapAssistSession.Request, UInt64) {
        let request = snap.willTile(id, zone: zone)
        return (request, snap.requests)
    }
    func willRestore(_ id: WindowIdentity?) { snap.willRestore(id) }
    func resetSnapAssist() { snap.reset() }
}
