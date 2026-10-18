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

/// What to do with the stored slot metadata before the Overview loads it.
public enum SlotMetadataAssessment: Equatable, Sendable {
    case usable
    /// Unreadable here (corrupt, wrong type, or a schema this version does not know, such as newer data after a
    /// downgrade). Copy it to a backup key and start fresh, so the first save cannot destroy it.
    case quarantine(tag: String)

    public static func assess(_ stored: Any) -> SlotMetadataAssessment {
        guard let data = stored as? Data else { return .quarantine(tag: "invalid") }
        do {
            _ = try OverviewSlotStore(metadata: data)
            return .usable
        } catch SlotPersistenceError.unsupportedSchema(let version) {
            return .quarantine(tag: "schema\(version)")
        } catch {
            return .quarantine(tag: "corrupt")
        }
    }

    /// `<key>.backup-<tag>`, or a numbered variant when that backup already holds different data. Never overwrites.
    public static func backupKey(for key: String, tag: String, isTaken: (String) -> Bool) -> String {
        let base = "\(key).backup-\(tag)"
        guard isTaken(base) else { return base }
        var index = 2
        while isTaken("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// Moves unreadable metadata at `key` to a backup key and removes it, so the Overview starts fresh and its first
    /// save cannot overwrite it. Returns the backup key, or nil when the stored value is usable or absent.
    @discardableResult
    public static func quarantineIfUnreadable(in defaults: UserDefaults, key: String) -> String? {
        guard let stored = defaults.object(forKey: key), case .quarantine(let tag) = assess(stored) else { return nil }
        let backup = backupKey(for: key, tag: tag) { candidate in
            guard let existing = defaults.object(forKey: candidate) else { return false }
            return !(existing as AnyObject).isEqual(stored)
        }
        defaults.set(stored, forKey: backup)
        defaults.removeObject(forKey: key)
        return backup
    }
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

    /// A free slot: unbound, unpinned and without a matching rule. The next new window takes it.
    public static func isFree(_ slot: OverviewSlot) -> Bool { slot.binding == nil && !slot.isPinned && slot.matchingRule == nil }

    /// Exchanges the positions of two slots; every other slot stays where it is. Dropping a window on another
    /// window's slot swaps them.
    @discardableResult
    public mutating func swap(_ first: UUID, _ second: UUID) -> Bool {
        guard first != second, let a = slots.firstIndex(where: { $0.id == first }),
              let b = slots.firstIndex(where: { $0.id == second }) else { return false }
        slots.swapAt(a, b)
        return true
    }

    /// Moves a slot into an unbound slot's position without shifting others: its old position now holds that
    /// vacancy. Refused when the target holds a window.
    @discardableResult
    public mutating func place(slotID: UUID, into vacancyID: UUID) -> Bool {
        guard let target = slots.first(where: { $0.id == vacancyID }), target.binding == nil else { return false }
        return swap(slotID, vacancyID)
    }

    /// Removes one unbound slot (free or kept). Refused for a slot holding a window.
    @discardableResult
    public mutating func remove(slotID: UUID) -> Bool {
        guard let index = slots.firstIndex(where: { $0.id == slotID }), slots[index].binding == nil else { return false }
        slots.remove(at: index)
        return true
    }

    /// Removes every free slot; kept (pinned) vacancies stay. Returns how many were removed.
    @discardableResult
    public mutating func removeFreeSlots() -> Int {
        let before = slots.count
        slots.removeAll(where: Self.isFree)
        return before - slots.count
    }

    /// Clears slots and pins, then places `records` in their current order.
    public mutating func reset(_ records: [WindowRecord]) {
        slots.removeAll()
        reconcile(records)
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
