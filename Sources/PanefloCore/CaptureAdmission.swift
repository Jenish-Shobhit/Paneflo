import Foundation

public struct SnapshotTicket: Hashable, Sendable {
    public let id: UUID
    public let window: WindowIdentity
    public let generation: UInt64
    fileprivate init(window: WindowIdentity, generation: UInt64) {
        self.id = UUID(); self.window = window; self.generation = generation
    }
}

public struct LivePreviewLease: Equatable, Sendable {
    public let id: UUID
    public let window: WindowIdentity
    fileprivate init(window: WindowIdentity) { self.id = UUID(); self.window = window }
}

public enum CaptureCompletion: Equatable, Sendable { case deliver, discard }

/// Admission contracts only. Logical cancellation never pretends an OS callback completed.
public struct CaptureAdmission: Sendable {
    public let snapshotLimit: Int
    private var snapshots: [UUID: Outstanding] = [:]
    public private(set) var liveLease: LivePreviewLease?
    public private(set) var isLiveStopping = false

    private struct Outstanding: Sendable {
        let ticket: SnapshotTicket
        var obsolete = false
        var timedOut = false
    }

    public init(snapshotLimit: Int = 2) { self.snapshotLimit = max(0, snapshotLimit) }
    public var physicallyOutstandingCount: Int { snapshots.count }
    public var logicallyCancelledCount: Int { snapshots.values.filter(\.obsolete).count }
    public var circuitIsOpen: Bool { snapshots.values.contains { $0.timedOut } }
    public var activeLiveCount: Int { liveLease == nil || isLiveStopping ? 0 : 1 }
    public var physicallyOutstandingLiveCount: Int { liveLease == nil ? 0 : 1 }

    public mutating func beginSnapshot(window: WindowIdentity, generation: UInt64) -> SnapshotTicket? {
        guard !circuitIsOpen, snapshots.count < snapshotLimit else { return nil }
        let ticket = SnapshotTicket(window: window, generation: generation)
        snapshots[ticket.id] = Outstanding(ticket: ticket)
        return ticket
    }

    public mutating func cancel(_ ticket: SnapshotTicket) {
        guard var item = snapshots[ticket.id], item.ticket == ticket else { return }
        item.obsolete = true
        snapshots[ticket.id] = item
    }

    public mutating func timeout(_ ticket: SnapshotTicket) {
        guard var item = snapshots[ticket.id], item.ticket == ticket else { return }
        item.obsolete = true
        item.timedOut = true
        snapshots[ticket.id] = item
    }

    /// Completion or certain teardown must be established by the platform owner.
    public mutating func complete(_ ticket: SnapshotTicket) -> CaptureCompletion? {
        guard let item = snapshots[ticket.id], item.ticket == ticket else { return nil }
        snapshots.removeValue(forKey: ticket.id)
        return item.obsolete ? .discard : .deliver
    }

    public mutating func beginLive(window: WindowIdentity, surfaceVisible: Bool, eligible: Bool = true) -> LivePreviewLease? {
        guard surfaceVisible, eligible, !circuitIsOpen, liveLease == nil else { return nil }
        let lease = LivePreviewLease(window: window)
        liveLease = lease
        isLiveStopping = false
        return lease
    }

    /// The caller must issue stop immediately; the lease remains held while actual teardown is pending.
    public mutating func stopLive() { if liveLease != nil { isLiveStopping = true } }

    @discardableResult
    public mutating func completeLiveStop(_ lease: LivePreviewLease) -> Bool {
        guard liveLease == lease, isLiveStopping else { return false }
        liveLease = nil
        isLiveStopping = false
        return true
    }

    public mutating func hideSurfaces() {
        for ticket in snapshots.values.map(\.ticket) { cancel(ticket) }
        stopLive()
    }
}
