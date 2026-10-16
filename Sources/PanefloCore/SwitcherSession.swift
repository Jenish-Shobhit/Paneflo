import Foundation

public enum CycleDirection: Sendable {
    case forward, backward
}

public enum SwitcherStatus: Equatable, Sendable {
    case active, cancelled, committed
}

/// Value-owned records freeze ordering and search metadata for one invocation.
public struct SwitcherSession: Sendable {
    public private(set) var orderedIDs: [WindowIdentity]
    public private(set) var selectedID: WindowIdentity?
    public private(set) var status: SwitcherStatus = .active
    public private(set) var searchQuery = ""
    private var records: [WindowIdentity: WindowRecord]

    public init(snapshot: WindowSnapshot, direction: CycleDirection = .forward) {
        let ordered = snapshot.orderedRecords
        self.orderedIDs = ordered.map(\.id)
        self.records = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        if ordered.count > 1 {
            self.selectedID = direction == .forward ? ordered[1].id : ordered.last?.id
        } else {
            self.selectedID = ordered.first?.id
        }
    }

    public var filteredIDs: [WindowIdentity] {
        orderedIDs.filter { id in records[id].map { WindowSearch.matches(searchQuery, record: $0) } ?? false }
    }

    public mutating func advance(_ direction: CycleDirection = .forward) {
        guard status == .active else { return }
        let candidates = filteredIDs
        guard !candidates.isEmpty else { selectedID = nil; return }
        guard let selectedID, let index = candidates.firstIndex(of: selectedID) else {
            self.selectedID = direction == .forward ? candidates.first : candidates.last
            return
        }
        let step = direction == .forward ? 1 : candidates.count - 1
        self.selectedID = candidates[(index + step) % candidates.count]
    }

    @discardableResult
    public mutating func select(_ id: WindowIdentity) -> Bool {
        guard status == .active, filteredIDs.contains(id) else { return false }
        selectedID = id
        return true
    }

    public mutating func setSearchQuery(_ query: String) {
        guard status == .active else { return }
        searchQuery = query
        let candidates = filteredIDs
        if selectedID.map({ candidates.contains($0) }) != true { selectedID = candidates.first }
    }

    public mutating func remove(_ id: WindowIdentity) {
        guard status == .active else { return }
        let oldCandidates = filteredIDs
        let oldIndex = selectedID.flatMap { oldCandidates.firstIndex(of: $0) } ?? 0
        orderedIDs.removeAll { $0 == id }
        records.removeValue(forKey: id)
        if selectedID == id {
            let remaining = filteredIDs
            selectedID = remaining.isEmpty ? nil : remaining[min(oldIndex, remaining.count - 1)]
        }
    }

    public mutating func cancel() {
        guard status == .active else { return }
        status = .cancelled
    }

    /// Emits an intent only. The caller must revalidate identity and later confirm actual focus.
    public mutating func commit() -> WindowIdentity? {
        guard status == .active else { return nil }
        status = .committed
        return selectedID
    }
}
