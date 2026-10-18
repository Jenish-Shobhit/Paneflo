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

/// The two windows of a tile pair, left (or top) first.
public struct TilePairMembers: Equatable, Hashable, Sendable {
    public let first: WindowIdentity
    public let second: WindowIdentity
    public init(first: WindowIdentity, second: WindowIdentity) { self.first = first; self.second = second }
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

    /// Whether a search query matches the Desktop entry (the same rule as window search; empty matches).
    public static func desktopMatches(_ query: String) -> Bool { WindowSearch.matches(query, text: desktopTitle) }

    public private(set) var orderedTargets: [SwitchTarget]
    public private(set) var selectedTarget: SwitchTarget?
    public private(set) var status: SwitcherStatus = .active
    public private(set) var searchQuery = ""
    public let desktopMode: DesktopLoopMode
    private var records: [WindowIdentity: WindowRecord]

    public var orderedIDs: [WindowIdentity] { orderedTargets.compactMap(\.windowID) }
    public var selectedID: WindowIdentity? { selectedTarget?.windowID }

    /// Tile pairs as (left or top, right or bottom), kept adjacent in the loop for this session.
    public let pairs: [TilePairMembers]

    /// `pairs` places each tile pair's two members side by side, spatial order, at the position of the more recently
    /// used member. The initial selection is the one the plain MRU loop would choose, so a quick press still returns
    /// to the previous window.
    public init(snapshot: WindowSnapshot, direction: CycleDirection = .forward, desktop: DesktopLoopMode = .hidden,
                pairs: [TilePairMembers] = []) {
        let ordered = snapshot.orderedRecords
        let mru = ordered.map(\.id)
        let present = Set(mru)
        let pairs = pairs.filter { $0.first != $0.second && present.contains($0.first) && present.contains($0.second) }
        let arranged = Self.arrange(mru, pairs: pairs)
        var targets = arranged.map { SwitchTarget.window($0) }
        var plain = mru.map { SwitchTarget.window($0) }
        switch desktop {
        case .hidden: break
        case .trailing:
            targets.append(.desktop); plain.append(.desktop)
        case .current:
            plain.insert(.desktop, at: min(1, plain.count))
            var after = min(1, targets.count)
            if let first = mru.first, let index = arranged.firstIndex(of: first) {
                let partnerFollows = index + 1 < arranged.count && pairs.contains { $0.first == first && $0.second == arranged[index + 1] }
                after = index + (partnerFollows ? 2 : 1)
            }
            targets.insert(.desktop, at: min(after, targets.count))
        }
        self.desktopMode = desktop
        self.pairs = pairs
        self.orderedTargets = targets
        self.records = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        if desktop == .current, direction == .forward {
            self.selectedTarget = plain.first
        } else if plain.count > 1 {
            self.selectedTarget = direction == .forward ? plain[1] : plain.last
        } else {
            self.selectedTarget = plain.first
        }
    }

    /// MRU order with each pair's members adjacent (first member first) where the more recent one stood.
    public static func arrange(_ mru: [WindowIdentity], pairs: [TilePairMembers]) -> [WindowIdentity] {
        guard !pairs.isEmpty else { return mru }
        var partnerOf: [WindowIdentity: TilePairMembers] = [:]
        for pair in pairs where partnerOf[pair.first] == nil && partnerOf[pair.second] == nil {
            partnerOf[pair.first] = pair; partnerOf[pair.second] = pair
        }
        var emitted = Set<WindowIdentity>()
        var result: [WindowIdentity] = []
        result.reserveCapacity(mru.count)
        for id in mru where !emitted.contains(id) {
            if let pair = partnerOf[id] {
                for member in [pair.first, pair.second] where emitted.insert(member).inserted { result.append(member) }
            } else {
                emitted.insert(id); result.append(id)
            }
        }
        return result
    }

    /// Indices in `targets` where a pair's first member is directly followed by its second.
    public func pairStarts(in targets: [SwitchTarget]) -> Set<Int> {
        guard !pairs.isEmpty, targets.count > 1 else { return [] }
        var starts = Set<Int>()
        for index in 0..<(targets.count - 1) {
            guard case .window(let a) = targets[index], case .window(let b) = targets[index + 1] else { continue }
            if pairs.contains(where: { $0.first == a && $0.second == b }) { starts.insert(index) }
        }
        return starts
    }

    /// Explicit refresh for a manually opened surface. Shortcut invocations must not call this.
    /// Preserves the query and an eligible selection while accepting newly discovered windows.
    public mutating func refresh(snapshot: WindowSnapshot) {
        let query = searchQuery
        let previous = selectedTarget
        self = SwitcherSession(snapshot: snapshot, desktop: desktopMode, pairs: pairs)
        setSearchQuery(query)
        if let previous { _ = select(previous) }
    }

    private func matches(_ target: SwitchTarget) -> Bool {
        switch target {
        case .window(let id):
            return records[id].map { WindowSearch.matches(searchQuery, record: $0) } ?? false
        case .desktop:
            return Self.desktopMatches(searchQuery)
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
