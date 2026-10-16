import Foundation

/// Explicit user-authored matching metadata, never inferred from a mutable window title.
public struct SlotMatchingRule: Equatable, Codable, Sendable {
    public var appIdentifier: String
    public var documentKey: String?

    public init(appIdentifier: String, documentKey: String? = nil) {
        self.appIdentifier = appIdentifier
        self.documentKey = documentKey
    }

    fileprivate func matches(_ record: WindowRecord) -> Bool {
        appIdentifier == record.appIdentifier && (documentKey == nil || documentKey == record.documentKey)
    }
}

public struct OverviewSlot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public fileprivate(set) var binding: WindowIdentity?
    public fileprivate(set) var isPinned: Bool
    public fileprivate(set) var matchingRule: SlotMatchingRule?

    fileprivate init(id: UUID = UUID(), binding: WindowIdentity? = nil,
                     isPinned: Bool = false, matchingRule: SlotMatchingRule? = nil) {
        self.id = id
        self.binding = binding
        self.isPinned = isPinned
        self.matchingRule = matchingRule
    }
}

public enum SlotPersistenceError: Error, Equatable {
    case unsupportedSchema(Int)
    case duplicateSlotID
}

public struct OverviewSlotStore: Sendable {
    public private(set) var slots: [OverviewSlot] = []

    public init() {}

    /// Existing positions are never compacted or sorted by incoming focus order.
    public mutating func reconcile(_ records: [WindowRecord]) {
        var seen = Set<WindowIdentity>()
        let unique = records.filter { seen.insert($0.id).inserted }
        for index in slots.indices where slots[index].binding.map({ !seen.contains($0) }) == true {
            slots[index].binding = nil
        }
        var bound = Set(slots.compactMap(\.binding))
        // Resolve explicit rules only when both sides have a single unambiguous claim.
        let vacancies = slots.indices.filter { slots[$0].binding == nil && slots[$0].matchingRule != nil }
        let candidates = unique.filter { !bound.contains($0.id) }
        let claims = Dictionary(uniqueKeysWithValues: vacancies.map { index in
            (index, candidates.filter { slots[index].matchingRule!.matches($0) }.map(\.id))
        })
        for index in vacancies {
            guard let matches = claims[index], matches.count == 1, let id = matches.first,
                  claims.values.filter({ $0.contains(id) }).count == 1 else { continue }
            slots[index].binding = id
            bound.insert(id)
        }
        for record in unique where !bound.contains(record.id) {
            if let vacancy = slots.firstIndex(where: { $0.binding == nil && !$0.isPinned && $0.matchingRule == nil }) {
                slots[vacancy].binding = record.id
            } else {
                slots.append(OverviewSlot(binding: record.id))
            }
        }
    }

    public mutating func pin(slotID: UUID, matchingRule: SlotMatchingRule? = nil) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].isPinned = true
        slots[index].matchingRule = matchingRule
    }

    public mutating func unpin(slotID: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].isPinned = false
        slots[index].matchingRule = nil
    }

    public mutating func move(slotID: UUID, to index: Int) {
        guard let source = slots.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = slots.remove(at: source)
        slots.insert(slot, at: min(max(0, index), slots.count))
    }

    /// Matching IDs dim cards in place; no ordering or bindings change.
    public func matches(query: String, records: [WindowRecord]) -> Set<UUID> {
        let matchingWindows = Set(records.filter { WindowSearch.matches(query, record: $0) }.map(\.id))
        return Set(slots.filter { $0.binding.map { matchingWindows.contains($0) } ?? false }.map(\.id))
    }

    /// Query-eligible window keys remain in their user-assigned slot order.
    public func matchingWindowIDs(query: String, records: [WindowRecord]) -> [WindowIdentity] {
        let matchingSlots = matches(query: query, records: records)
        return slots.filter { matchingSlots.contains($0.id) }.compactMap(\.binding)
    }

    public func encodedMetadata() throws -> Data {
        let envelope = Envelope(schemaVersion: 1, slots: slots.map {
            Metadata(id: $0.id, isPinned: $0.isPinned, matchingRule: $0.matchingRule)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Decoding never changes a caller's last usable store; the caller owns atomic disk writes.
    public init(metadata: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: metadata)
        guard envelope.schemaVersion == 1 else { throw SlotPersistenceError.unsupportedSchema(envelope.schemaVersion) }
        guard Set(envelope.slots.map(\.id)).count == envelope.slots.count else { throw SlotPersistenceError.duplicateSlotID }
        slots = envelope.slots.map { OverviewSlot(id: $0.id, isPinned: $0.isPinned, matchingRule: $0.matchingRule) }
    }

    private struct Envelope: Codable { let schemaVersion: Int; let slots: [Metadata] }
    private struct Metadata: Codable {
        let id: UUID
        let isPinned: Bool
        let matchingRule: SlotMatchingRule?
    }
}
