/// Pure admission for finite per-PID Accessibility work. Running calls are never logically
/// timed out to admit replacement work: only physical worker completion releases a slot.
public struct AXWorkAdmission: Sendable {
    public enum Priority: Sendable { case interactive, background }
    public struct Ticket: Equatable, Sendable {
        public let id: UInt64
        public let pid: Int32
        public let priority: Priority
        public init(id: UInt64, pid: Int32, priority: Priority) {
            self.id = id; self.pid = pid; self.priority = priority
        }
    }
    public private(set) var pending: [Ticket] = []
    public private(set) var active: [Ticket] = []
    public let maximumPending: Int
    public init(maximumPending: Int = 64) { self.maximumPending = max(1, maximumPending) }

    /// Coalesce each PID/priority lane. Interactive work can evict queued background work.
    /// Returned IDs must have their cancellation completions delivered by the adapter.
    @discardableResult public mutating func enqueue(_ ticket: Ticket) -> [UInt64] {
        guard !active.contains(where: { $0.id == ticket.id }), !pending.contains(where: { $0.id == ticket.id }) else { return [] }
        var dropped: [UInt64] = []
        if let index = pending.firstIndex(where: { $0.pid == ticket.pid && $0.priority == ticket.priority }) {
            dropped.append(pending.remove(at: index).id)
        }
        if pending.count >= maximumPending {
            if ticket.priority == .interactive, let index = pending.firstIndex(where: { $0.priority == .background }) {
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
        while active.count < 4 {
            let busyPIDs = Set(active.map(\.pid))
            let interactive = pending.firstIndex { $0.priority == .interactive && !busyPIDs.contains($0.pid) }
            let background = active.filter { $0.priority == .background }.count < 2
                ? pending.firstIndex { $0.priority == .background && !busyPIDs.contains($0.pid) } : nil
            guard let index = interactive ?? background else { break }
            let ticket = pending.remove(at: index)
            active.append(ticket); admitted.append(ticket)
        }
        return admitted
    }

    @discardableResult public mutating func finish(_ id: UInt64) -> Bool {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return false }
        active.remove(at: index)
        return true
    }
}
