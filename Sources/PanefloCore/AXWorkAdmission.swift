/// Pure admission for finite per-PID Accessibility work. Running calls are never logically
/// timed out to admit replacement work: only physical worker completion releases a slot.
///
/// Three lanes share one coordinator:
/// - `interactive` (focus, placement, minimize) has its own worker slots and is serialized only
///   against other interactive work for the same PID. It never waits behind a scan or an update.
/// - `background` (full per-PID window scans) is serialized per PID against scans and updates.
/// - `update` (coalesced single-record refreshes and focused-window queries driven by AX
///   notifications) is serialized per PID like scans, with its own slots.
public struct AXWorkAdmission: Sendable {
    public enum Priority: Sendable { case interactive, background, update }
    public struct Ticket: Equatable, Sendable {
        public let id: UInt64
        public let pid: Int32
        public let priority: Priority
        /// Interactive work of different lanes (focus, placement) neither coalesces nor serializes
        /// against each other for one PID; within a lane the PID is serialized and coalesced.
        public let lane: UInt8
        public init(id: UInt64, pid: Int32, priority: Priority, lane: UInt8 = 0) {
            self.id = id; self.pid = pid; self.priority = priority; self.lane = lane
        }
    }
    public private(set) var pending: [Ticket] = []
    public private(set) var active: [Ticket] = []
    public let maximumPending: Int
    public static let interactiveSlots = 2
    public static let backgroundSlots = 2
    public static let updateSlots = 2
    public init(maximumPending: Int = 64) { self.maximumPending = max(1, maximumPending) }

    /// Coalesce each PID/priority lane. Interactive work can evict queued non-interactive work.
    /// Returned IDs must have their cancellation completions delivered by the adapter.
    @discardableResult public mutating func enqueue(_ ticket: Ticket) -> [UInt64] {
        guard !active.contains(where: { $0.id == ticket.id }), !pending.contains(where: { $0.id == ticket.id }) else { return [] }
        var dropped: [UInt64] = []
        if let index = pending.firstIndex(where: { $0.pid == ticket.pid && $0.priority == ticket.priority && $0.lane == ticket.lane }) {
            dropped.append(pending.remove(at: index).id)
        }
        if pending.count >= maximumPending {
            if ticket.priority == .interactive, let index = pending.firstIndex(where: { $0.priority != .interactive }) {
                dropped.append(pending.remove(at: index).id)
            } else {
                dropped.append(ticket.id)
                return dropped
            }
        }
        pending.append(ticket)
        return dropped
    }

    public mutating func takeReady() -> [Ticket] {
        var admitted: [Ticket] = []
        while let index = nextReadyIndex() {
            let ticket = pending.remove(at: index)
            active.append(ticket); admitted.append(ticket)
        }
        return admitted
    }

    /// Interactive first, then scans, then notification-driven updates.
    private func nextReadyIndex() -> Int? {
        let interactiveLanes = Set(active.filter { $0.priority == .interactive }.map { Lane(pid: $0.pid, lane: $0.lane) })
        let scanningPIDs = Set(active.filter { $0.priority != .interactive }.map(\.pid))
        if count(.interactive) < Self.interactiveSlots,
           let index = pending.firstIndex(where: { $0.priority == .interactive && !interactiveLanes.contains(Lane(pid: $0.pid, lane: $0.lane)) }) {
            return index
        }
        if count(.background) < Self.backgroundSlots,
           let index = pending.firstIndex(where: { $0.priority == .background && !scanningPIDs.contains($0.pid) }) {
            return index
        }
        if count(.update) < Self.updateSlots,
           let index = pending.firstIndex(where: { $0.priority == .update && !scanningPIDs.contains($0.pid) }) {
            return index
        }
        return nil
    }

    private struct Lane: Hashable { let pid: Int32; let lane: UInt8 }

    private func count(_ priority: Priority) -> Int { active.lazy.filter { $0.priority == priority }.count }

    @discardableResult public mutating func finish(_ id: UInt64) -> Bool {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return false }
        active.remove(at: index)
        return true
    }
}
