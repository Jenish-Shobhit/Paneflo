import Foundation

public struct GeometryChange: Equatable, Sendable {
    public let id: WindowIdentity
    public let before: WindowRect
    public let after: WindowRect

    public init(id: WindowIdentity, before: WindowRect, after: WindowRect) {
        self.id = id; self.before = before; self.after = after
    }
}

public struct GeometryUndoPlan: Equatable, Sendable {
    public let changes: [GeometryChange]
    public let skipped: [WindowIdentity]
    /// Tile pairs the operation ended: formed again once `changes` are back in place.
    public let pairs: [TilePairMembers]

    public init(changes: [GeometryChange], skipped: [WindowIdentity], pairs: [TilePairMembers] = []) {
        self.changes = changes; self.skipped = skipped; self.pairs = pairs
    }
}

/// Metadata only. A plan is not a claim that any application accepted a geometry write.
///
/// One user action is one operation, even when it moved several windows (a tile that replaced or swapped a pair
/// member moves the displaced member or the partner too): follow-up placements join the operation by its identifier,
/// and an undo puts every window of the operation back and re-forms the pairs it ended.
public struct GeometryUndoHistory: Sendable {
    public static let capacity = 20

    private struct Operation: Sendable {
        var id: UInt64?
        var changes: [GeometryChange]
        var pairs: [TilePairMembers]
    }

    private var operations: [Operation] = []
    /// Pairs attached to operations that have no change yet (bounded): they join the operation when it records one,
    /// so an arrangement that moved nothing never takes an undo step.
    private var pendingPairs: [(operation: UInt64, pairs: [TilePairMembers])] = []
    public var count: Int { operations.count }

    public init() {}

    /// Records changes. With `operation`, they join that operation when it is still in the history: a window
    /// already in it keeps its first `before` and takes the new `after`.
    public mutating func record(_ changes: [GeometryChange], operation: UInt64? = nil) {
        var seen = Set<WindowIdentity>()
        let effective = changes.filter {
            $0.before.isValid && $0.after.isValid && $0.before != $0.after && seen.insert($0.id).inserted
        }
        if let operation, let index = operations.lastIndex(where: { $0.id == operation }) {
            for change in effective {
                if let existing = operations[index].changes.firstIndex(where: { $0.id == change.id }) {
                    let first = operations[index].changes[existing].before
                    operations[index].changes[existing] = GeometryChange(id: change.id, before: first, after: change.after)
                } else {
                    operations[index].changes.append(change)
                }
            }
            return
        }
        guard !effective.isEmpty else { return }
        var pairs: [TilePairMembers] = []
        if let operation, let index = pendingPairs.firstIndex(where: { $0.operation == operation }) {
            pairs = pendingPairs.remove(at: index).pairs
        }
        append(Operation(id: operation, changes: effective, pairs: pairs))
    }

    /// Pairs `operation` ends, to form again when it is undone. Held aside until the operation records a change.
    public mutating func attach(pairs: [TilePairMembers], to operation: UInt64) {
        guard !pairs.isEmpty else { return }
        if let index = operations.lastIndex(where: { $0.id == operation }) {
            for pair in pairs where !operations[index].pairs.contains(pair) { operations[index].pairs.append(pair) }
        } else if let index = pendingPairs.firstIndex(where: { $0.operation == operation }) {
            for pair in pairs where !pendingPairs[index].pairs.contains(pair) { pendingPairs[index].pairs.append(pair) }
        } else {
            pendingPairs.append((operation, pairs))
            if pendingPairs.count > Self.capacity { pendingPairs.removeFirst() }
        }
    }

    public mutating func undo(surviving identities: Set<WindowIdentity>) -> GeometryUndoPlan? {
        operations.popLast().map { plan($0, surviving: identities) }
    }

    /// Undoes the most recent operation that changed `window`, leaving other operations untouched. Every window of
    /// that operation returns to its exact recorded frame from before it.
    public mutating func undo(window: WindowIdentity, surviving identities: Set<WindowIdentity>) -> GeometryUndoPlan? {
        guard let index = operations.lastIndex(where: { $0.changes.contains { $0.id == window } }) else { return nil }
        return plan(operations.remove(at: index), surviving: identities)
    }

    public func hasHistory(for window: WindowIdentity) -> Bool {
        operations.contains { $0.changes.contains { $0.id == window } }
    }

    private mutating func append(_ operation: Operation) {
        operations.append(operation)
        if operations.count > Self.capacity { operations.removeFirst() }
    }

    private func plan(_ operation: Operation, surviving identities: Set<WindowIdentity>) -> GeometryUndoPlan {
        GeometryUndoPlan(changes: operation.changes.filter { identities.contains($0.id) },
                         skipped: operation.changes.filter { !identities.contains($0.id) }.map(\.id),
                         pairs: operation.pairs)
    }
}
