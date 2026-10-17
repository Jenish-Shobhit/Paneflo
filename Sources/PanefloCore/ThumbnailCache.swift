/// Byte-bounded LRU of detached preview snapshots that survives surface dismissal.
///
/// Entries are keyed by `WindowIdentity` (a window incarnation, so a reused PID or window number
/// never matches an old image) and record the CGWindowID they were captured from plus the capture
/// time, so cards can say "Snapshot · 4s". The cache owns accounting only; the payload is whatever
/// the platform layer stores (a detached `CGImage` in the app, an `Int` in tests).
///
/// Purge only for privacy or memory reasons: critical pressure, app hide/quit, Screen Recording
/// revocation, or the window closing. Dismissing a surface must not purge.
public struct ThumbnailCache<Payload> {
    public struct Entry {
        public let id: WindowIdentity
        public let windowNumber: UInt32
        public let payload: Payload
        public let bytes: Int
        /// Monotonic seconds (system uptime) when the pixels were captured.
        public let capturedAt: Double
        fileprivate var lastUse: UInt64
    }

    public enum InsertResult: Equatable, Sendable {
        /// Stored; the listed identities were evicted (least recently used first) to make room.
        case stored(evicted: [WindowIdentity])
        /// An entry captured later than this one is already cached; the older capture is dropped.
        case olderThanCached
        /// Byte count invalid, above the per-entry ceiling, or above the whole budget.
        case rejected
    }

    public private(set) var byteLimit: Int
    public let maximumEntryBytes: Int
    public private(set) var totalBytes = 0
    private var entries: [WindowIdentity: Entry] = [:]
    private var clock: UInt64 = 0

    public init(byteLimit: Int = 24 * 1024 * 1024, maximumEntryBytes: Int = 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
        self.maximumEntryBytes = max(0, maximumEntryBytes)
    }

    public var count: Int { entries.count }
    public var identities: Set<WindowIdentity> { Set(entries.keys) }
    /// Least recently used first; for diagnostics and tests.
    public var lruOrder: [WindowIdentity] { entries.values.sorted { $0.lastUse < $1.lastUse }.map(\.id) }

    /// Checked multiplication of the actual row stride and pixel height.
    public static func payloadBytes(bytesPerRow: Int, height: Int) -> Int? {
        guard bytesPerRow > 0, height > 0 else { return nil }
        let result = bytesPerRow.multipliedReportingOverflow(by: height)
        return result.overflow ? nil : result.partialValue
    }

    @discardableResult
    public mutating func insert(id: WindowIdentity, windowNumber: UInt32, payload: Payload,
                                bytes: Int, capturedAt: Double) -> InsertResult {
        guard bytes > 0, bytes <= maximumEntryBytes, bytes <= byteLimit else { return .rejected }
        if let existing = entries[id], existing.windowNumber == windowNumber, existing.capturedAt > capturedAt {
            return .olderThanCached
        }
        if let existing = entries.removeValue(forKey: id) { totalBytes -= existing.bytes }
        let evicted = evict(toFit: bytes)
        clock &+= 1
        entries[id] = Entry(id: id, windowNumber: windowNumber, payload: payload, bytes: bytes,
                            capturedAt: capturedAt, lastUse: clock)
        totalBytes += bytes
        return .stored(evicted: evicted)
    }

    /// Returns and marks used. A `windowNumber` that differs from the captured one is a miss;
    /// `nil` (the window is minimized or its app hidden, so it has no capturable number now)
    /// matches any entry for this identity.
    public mutating func entry(for id: WindowIdentity, windowNumber: UInt32? = nil) -> Entry? {
        guard var entry = entries[id], windowNumber == nil || windowNumber == entry.windowNumber else { return nil }
        clock &+= 1
        entry.lastUse = clock
        entries[id] = entry
        return entry
    }

    /// Reads without changing LRU order.
    public func peek(_ id: WindowIdentity) -> Entry? { entries[id] }

    @discardableResult
    public mutating func remove(_ id: WindowIdentity) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        totalBytes -= entry.bytes
        return true
    }

    /// Drops entries for windows that no longer exist. Returns the removed identities.
    @discardableResult
    public mutating func retainOnly(_ alive: Set<WindowIdentity>) -> [WindowIdentity] {
        let removed = entries.keys.filter { !alive.contains($0) }
        for id in removed { remove(id) }
        return removed
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    /// Lowering the limit evicts least recently used entries immediately.
    @discardableResult
    public mutating func setByteLimit(_ limit: Int) -> [WindowIdentity] {
        byteLimit = max(0, limit)
        return evict(toFit: 0)
    }

    private mutating func evict(toFit incoming: Int) -> [WindowIdentity] {
        var evicted: [WindowIdentity] = []
        while totalBytes > byteLimit - incoming,
              let oldest = entries.values.min(by: { $0.lastUse < $1.lastUse }) {
            remove(oldest.id)
            evicted.append(oldest.id)
        }
        return evicted
    }
}

extension ThumbnailCache.Entry: Sendable where Payload: Sendable {}
extension ThumbnailCache: Sendable where Payload: Sendable {}
