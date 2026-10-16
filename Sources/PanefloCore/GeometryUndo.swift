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
}

/// Metadata only. A plan is not a claim that any application accepted a geometry write.
public struct GeometryUndoHistory: Sendable {
    public static let capacity = 20
    private var operations: [[GeometryChange]] = []
    public var count: Int { operations.count }

    public init() {}

    public mutating func record(_ changes: [GeometryChange]) {
        var seen = Set<WindowIdentity>()
        let effective = changes.filter {
            $0.before.isValid && $0.after.isValid && $0.before != $0.after && seen.insert($0.id).inserted
        }
        guard !effective.isEmpty else { return }
        operations.append(effective)
        if operations.count > Self.capacity { operations.removeFirst() }
    }

    public mutating func undo(surviving identities: Set<WindowIdentity>) -> GeometryUndoPlan? {
        guard let changes = operations.popLast() else { return nil }
        return GeometryUndoPlan(changes: changes.filter { identities.contains($0.id) },
                                skipped: changes.filter { !identities.contains($0.id) }.map(\.id))
    }
}
