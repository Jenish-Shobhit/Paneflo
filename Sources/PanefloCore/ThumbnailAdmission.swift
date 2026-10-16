/// Metadata accounting for detached thumbnail payloads, never live pixel-buffer leases.
public struct ThumbnailAdmission: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let id: WindowIdentity
        public let generation: UInt64
        fileprivate let serial: UInt64
    }
    private struct Entry: Sendable { var bytes: Int; var expires: Double }
    public let byteLimit: Int
    public let entryLimit: Int
    public let ttl: Double
    public private(set) var generation: UInt64 = 0
    public private(set) var outstanding: Ticket?
    private var serial: UInt64 = 0
    private var entries: [WindowIdentity: Entry] = [:]
    private var lru: [WindowIdentity] = []
    public init(byteLimit: Int = 6 * 1024 * 1024, entryLimit: Int = 12, ttl: Double = 30) {
        self.byteLimit = max(0, byteLimit); self.entryLimit = max(0, entryLimit); self.ttl = max(0, ttl)
    }
    public var identities: Set<WindowIdentity> { Set(entries.keys) }
    public var retainedBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    public mutating func invalidate(purge: Bool) {
        generation &+= 1
        if purge { entries.removeAll(); lru.removeAll() }
        // Outstanding is physical debt. Only its actual callback completion releases it.
    }
    public mutating func retainOnly(_ surviving: Set<WindowIdentity>) {
        if let outstanding, !surviving.contains(outstanding.id) { generation &+= 1 }
        entries = entries.filter { surviving.contains($0.key) }; lru.removeAll { entries[$0] == nil }
    }
    public mutating func contains(_ id: WindowIdentity, now: Double) -> Bool {
        guard let entry = entries[id] else { return false }
        guard entry.expires > now else { entries.removeValue(forKey: id); lru.removeAll { $0 == id }; return false }
        lru.removeAll { $0 == id }; lru.append(id)
        return true
    }
    public mutating func begin(_ id: WindowIdentity) -> Ticket? {
        guard outstanding == nil else { return nil }
        serial &+= 1
        let ticket = Ticket(id: id, generation: generation, serial: serial)
        outstanding = ticket
        return ticket
    }
    @discardableResult public mutating func complete(_ ticket: Ticket, rowBytes: Int?, height: Int?, now: Double) -> Bool {
        guard outstanding == ticket else { return false }
        outstanding = nil
        guard ticket.generation == generation, let rowBytes, let height, rowBytes > 0, height > 0,
              entryLimit > 0, ttl > 0 else { return false }
        let payload = rowBytes.multipliedReportingOverflow(by: height)
        guard !payload.overflow, payload.partialValue > 0, payload.partialValue <= 512 * 1024,
              payload.partialValue <= byteLimit else { return false }
        entries.removeValue(forKey: ticket.id); lru.removeAll { $0 == ticket.id }
        while entries.count >= entryLimit || retainedBytes > byteLimit - payload.partialValue {
            guard !lru.isEmpty else { return false }
            entries.removeValue(forKey: lru.removeFirst())
        }
        entries[ticket.id] = Entry(bytes: payload.partialValue, expires: now + ttl)
        lru.append(ticket.id)
        return true
    }
}
