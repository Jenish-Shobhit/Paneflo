import Foundation

public enum CycleDirection: Sendable {
    case forward, backward
}

public enum SwitcherStatus: Equatable, Sendable {
    case active, cancelled, committed
}

/// One stop in the switch loop. The Desktop is a distinct case, never a fake `WindowIdentity`.
public enum SwitchTarget: Hashable, Sendable {
    case window(WindowIdentity)
    case desktop

    public var windowID: WindowIdentity? {
        if case .window(let id) = self { return id }
        return nil
    }
}

/// Whether and where the Desktop pseudo-entry appears in a session's loop.
public enum DesktopLoopMode: Equatable, Sendable {
    /// No Desktop entry. Behaviour is identical to a window-only loop.
    case hidden
    /// The Desktop is the last stop of the MRU loop.
    case trailing
    /// The user is on the desktop right now (it was just shown). The entry sits at index 1, directly after the
    /// most recently used window, and the initial selection is index 0: releasing the shortcut returns to the
    /// window the user left, and one more step reaches the Desktop entry.
    case current

    /// `enabled` is the user setting; `desktopIsCurrent` is `DesktopService.isDesktopShown`.
    public static func make(enabled: Bool, desktopIsCurrent: Bool) -> DesktopLoopMode {
        guard enabled else { return .hidden }
        return desktopIsCurrent ? .current : .trailing
    }
}

/// Value-owned records freeze ordering and search metadata for one invocation.
///
/// The window-only API (`orderedIDs`, `filteredIDs`, `selectedID`, `select(_: WindowIdentity)`, `commit()`) keeps its
/// meaning and ignores the Desktop. The target API (`orderedTargets`, `filteredTargets`, `selectedTarget`,
/// `select(_: SwitchTarget)`, `commitTarget()`) includes it. `advance` and `remove` operate on the whole loop, so with
/// a Desktop entry `selectedID` is nil while the Desktop is selected.
public struct SwitcherSession: Sendable {
    public static let desktopTitle = "Desktop"

    public private(set) var orderedTargets: [SwitchTarget]
    public private(set) var selectedTarget: SwitchTarget?
    public private(set) var status: SwitcherStatus = .active
    public private(set) var searchQuery = ""
    public let desktopMode: DesktopLoopMode
    private var records: [WindowIdentity: WindowRecord]

    public var orderedIDs: [WindowIdentity] { orderedTargets.compactMap(\.windowID) }
    public var selectedID: WindowIdentity? { selectedTarget?.windowID }

    public init(snapshot: WindowSnapshot, direction: CycleDirection = .forward, desktop: DesktopLoopMode = .hidden) {
        let ordered = snapshot.orderedRecords
        var targets = ordered.map { SwitchTarget.window($0.id) }
        switch desktop {
        case .hidden: break
        case .trailing: targets.append(.desktop)
        case .current: targets.insert(.desktop, at: min(1, targets.count))
        }
        self.desktopMode = desktop
        self.orderedTargets = targets
        self.records = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        if desktop == .current, direction == .forward {
            self.selectedTarget = targets.first
        } else if targets.count > 1 {
            self.selectedTarget = direction == .forward ? targets[1] : targets.last
        } else {
            self.selectedTarget = targets.first
        }
    }

    /// Explicit refresh for a manually opened surface. Shortcut invocations must not call this.
    /// Preserves the query and an eligible selection while accepting newly discovered windows.
    public mutating func refresh(snapshot: WindowSnapshot) {
        let query = searchQuery
        let previous = selectedTarget
        self = SwitcherSession(snapshot: snapshot, desktop: desktopMode)
        setSearchQuery(query)
        if let previous { _ = select(previous) }
    }

    private func matches(_ target: SwitchTarget) -> Bool {
        switch target {
        case .window(let id):
            return records[id].map { WindowSearch.matches(searchQuery, record: $0) } ?? false
        case .desktop:
            return WindowSearch.matches(searchQuery, text: Self.desktopTitle)
        }
    }

    public var filteredTargets: [SwitchTarget] { orderedTargets.filter(matches) }

    public var filteredIDs: [WindowIdentity] { filteredTargets.compactMap(\.windowID) }

    public mutating func advance(_ direction: CycleDirection = .forward) {
        guard status == .active else { return }
        let candidates = filteredTargets
        guard !candidates.isEmpty else { selectedTarget = nil; return }
        guard let selectedTarget, let index = candidates.firstIndex(of: selectedTarget) else {
            self.selectedTarget = direction == .forward ? candidates.first : candidates.last
            return
        }
        let step = direction == .forward ? 1 : candidates.count - 1
        self.selectedTarget = candidates[(index + step) % candidates.count]
    }

    @discardableResult
    public mutating func select(_ id: WindowIdentity) -> Bool { select(.window(id)) }

    @discardableResult
    public mutating func select(_ target: SwitchTarget) -> Bool {
        guard status == .active, filteredTargets.contains(target) else { return false }
        selectedTarget = target
        return true
    }

    public mutating func setSearchQuery(_ query: String) {
        guard status == .active else { return }
        searchQuery = query
        let candidates = filteredTargets
        if selectedTarget.map({ candidates.contains($0) }) != true { selectedTarget = candidates.first }
    }

    public mutating func remove(_ id: WindowIdentity) {
        guard status == .active else { return }
        let oldCandidates = filteredTargets
        let oldIndex = selectedTarget.flatMap { oldCandidates.firstIndex(of: $0) } ?? 0
        orderedTargets.removeAll { $0 == .window(id) }
        records.removeValue(forKey: id)
        if selectedTarget == .window(id) {
            let remaining = filteredTargets
            selectedTarget = remaining.isEmpty ? nil : remaining[min(oldIndex, remaining.count - 1)]
        }
    }

    public mutating func cancel() {
        guard status == .active else { return }
        status = .cancelled
    }

    /// Emits an intent only. The caller must revalidate identity and later confirm actual focus.
    /// Returns nil when nothing or the Desktop is selected; use `commitTarget()` to see the Desktop.
    public mutating func commit() -> WindowIdentity? {
        commitTarget()?.windowID
    }

    public mutating func commitTarget() -> SwitchTarget? {
        guard status == .active else { return nil }
        status = .committed
        return selectedTarget
    }
}
