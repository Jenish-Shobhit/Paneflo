import Foundation

public enum PreviewKind: Hashable, Sendable { case thumbnail, liveFrame }
public enum PreviewBudgetMode: Equatable, Sendable { case balanced, memoryPressure, iconsOnly }

public struct PreviewReservation: Hashable, Sendable {
    public let id: UUID
    public let estimatedBytes: Int
    public let kind: PreviewKind
    fileprivate init(estimatedBytes: Int, kind: PreviewKind) {
        self.id = UUID(); self.estimatedBytes = estimatedBytes; self.kind = kind
    }
}

public struct PreviewAllocation: Equatable, Sendable {
    public let id: UUID
    public let bytes: Int
    public let kind: PreviewKind
}

public enum PreviewRejection: Equatable, Sendable { case unknownReservation, notSubmitted, invalidByteCount, capacity }
public enum PreviewReconciliation: Equatable, Sendable {
    case admitted(PreviewAllocation)
    case discarded
    case rejected(PreviewRejection)
}

/// Payload bookkeeping only: no images, OS requests, framework pools or total-RAM claims.
public struct PreviewBudget: Sendable {
    public private(set) var mode: PreviewBudgetMode
    public let reservationLimit: Int
    public let allocationLimit: Int
    private var pending: [UUID: Pending] = [:]
    private var retained: [UUID: PreviewAllocation] = [:]
    private var lru: [UUID] = []

    private struct Pending: Sendable {
        let reservation: PreviewReservation
        var submitted = false
        var obsolete = false
    }

    public init(mode: PreviewBudgetMode = .balanced, reservationLimit: Int = 64, allocationLimit: Int = 256) {
        self.mode = mode
        self.reservationLimit = max(0, reservationLimit)
        self.allocationLimit = max(0, allocationLimit)
    }
    public var retainedBytes: Int { retained.values.reduce(0) { $0 + $1.bytes } }
    public var reservedBytes: Int { pending.values.reduce(0) { $0 + $1.reservation.estimatedBytes } }
    public var accountedBytes: Int { retainedBytes + reservedBytes }
    public var reservationCount: Int { pending.count }
    public var allocations: [PreviewAllocation] { lru.compactMap { retained[$0] } }
    public var isOverLimit: Bool { accountedBytes > combinedLimit || thumbnailBytes > thumbnailLimit }

    public var combinedLimit: Int {
        switch mode { case .balanced: 32 * 1_024 * 1_024; case .memoryPressure: 6 * 1_024 * 1_024; case .iconsOnly: 0 }
    }
    public var thumbnailLimit: Int {
        switch mode { case .balanced: 24 * 1_024 * 1_024; case .memoryPressure: 6 * 1_024 * 1_024; case .iconsOnly: 0 }
    }

    public mutating func reserve(estimatedBytes: Int, kind: PreviewKind = .thumbnail) -> PreviewReservation? {
        guard estimatedBytes > 0, pending.count < reservationLimit, allocationLimit > 0,
              allowed(kind), makeRoom(bytes: estimatedBytes, kind: kind) else { return nil }
        let reservation = PreviewReservation(estimatedBytes: estimatedBytes, kind: kind)
        pending[reservation.id] = Pending(reservation: reservation)
        return reservation
    }

    @discardableResult
    public mutating func submit(_ reservation: PreviewReservation) -> Bool {
        guard var item = pending[reservation.id], item.reservation == reservation, !item.submitted else { return false }
        item.submitted = true
        pending[reservation.id] = item
        return true
    }

    /// Unstarted work releases immediately; issued work stays charged until real completion/teardown.
    public mutating func cancel(_ reservation: PreviewReservation) {
        guard var item = pending[reservation.id], item.reservation == reservation else { return }
        if item.submitted { item.obsolete = true; pending[reservation.id] = item }
        else { pending.removeValue(forKey: reservation.id) }
    }

    public mutating func timeout(_ reservation: PreviewReservation) { cancel(reservation) }

    public mutating func reconcile(_ reservation: PreviewReservation, actualBytes: Int) -> PreviewReconciliation {
        guard let item = pending[reservation.id], item.reservation == reservation else { return .rejected(.unknownReservation) }
        guard item.submitted else { return .rejected(.notSubmitted) }
        pending.removeValue(forKey: reservation.id)
        guard !item.obsolete, allowed(reservation.kind) else { return .discarded }
        guard actualBytes > 0 else { return .rejected(.invalidByteCount) }
        guard makeRoom(bytes: actualBytes, kind: reservation.kind) else { return .rejected(.capacity) }
        while retained.count >= allocationLimit, let oldest = allocations.first { release(oldest) }
        let allocation = PreviewAllocation(id: reservation.id, bytes: actualBytes, kind: reservation.kind)
        retained[allocation.id] = allocation
        lru.append(allocation.id)
        return .admitted(allocation)
    }

    /// Call only after the request really failed/completed, or teardown is confirmed.
    public mutating func finishWithoutPayload(_ reservation: PreviewReservation) {
        guard pending[reservation.id]?.reservation == reservation else { return }
        pending.removeValue(forKey: reservation.id)
    }

    public mutating func release(_ allocation: PreviewAllocation) {
        guard retained[allocation.id] == allocation else { return }
        retained.removeValue(forKey: allocation.id)
        lru.removeAll { $0 == allocation.id }
    }

    public mutating func touch(_ allocation: PreviewAllocation) {
        guard retained[allocation.id] == allocation else { return }
        lru.removeAll { $0 == allocation.id }
        lru.append(allocation.id)
    }

    /// In-flight reservations may temporarily exceed a reduced limit; that debt is visible and blocks admission.
    public mutating func setMode(_ mode: PreviewBudgetMode) {
        self.mode = mode
        for reservation in pending.values.map(\.reservation) { cancel(reservation) }
        for allocation in allocations where !allowed(allocation.kind) { release(allocation) }
        while isOverLimit, let oldest = allocations.first { release(oldest) }
    }

    /// Checked multiplication for actual image row-stride accounting.
    public static func payloadBytes(bytesPerRow: Int, height: Int) -> Int? {
        guard bytesPerRow > 0, height > 0 else { return nil }
        let result = bytesPerRow.multipliedReportingOverflow(by: height)
        return result.overflow ? nil : result.partialValue
    }

    private var thumbnailBytes: Int {
        retained.values.filter { $0.kind == .thumbnail }.reduce(0) { $0 + $1.bytes }
            + pending.values.filter { $0.reservation.kind == .thumbnail }.reduce(0) { $0 + $1.reservation.estimatedBytes }
    }

    private func allowed(_ kind: PreviewKind) -> Bool {
        mode != .iconsOnly && (kind == .thumbnail || mode == .balanced)
    }

    private func fits(bytes: Int, kind: PreviewKind) -> Bool {
        // Subtraction avoids overflowing on hostile Int.max byte requests.
        guard bytes <= combinedLimit, accountedBytes <= combinedLimit - bytes else { return false }
        return kind != .thumbnail || (bytes <= thumbnailLimit && thumbnailBytes <= thumbnailLimit - bytes)
    }

    private mutating func makeRoom(bytes: Int, kind: PreviewKind) -> Bool {
        guard bytes <= combinedLimit, kind != .thumbnail || bytes <= thumbnailLimit else { return false }
        while !fits(bytes: bytes, kind: kind), let oldest = allocations.first { release(oldest) }
        return fits(bytes: bytes, kind: kind)
    }
}
