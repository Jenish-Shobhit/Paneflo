import Testing
@testable import PanefloCore

struct SnapshotSchedulerTests {
    private func id(_ n: UInt32) -> WindowIdentity {
        .init(process: .init(pid: 30, launchToken: 1), number: n, incarnation: 1)
    }
    private func requests(_ count: UInt32) -> [SnapshotRequest] {
        (0..<count).map { SnapshotRequest(id: id($0), windowNumber: 100 + $0) }
    }

    @Test func concurrencyIsClampedAndCapped() {
        #expect(SnapshotScheduler(concurrencyLimit: 1).concurrencyLimit == 2)
        #expect(SnapshotScheduler(concurrencyLimit: 9).concurrencyLimit == 4)
        var scheduler = SnapshotScheduler(concurrencyLimit: 3)
        scheduler.beginSession()
        scheduler.plan(requests(8), selectedIndex: 0)
        let first = scheduler.nextTickets()
        #expect(first.count == 3 && scheduler.outstandingCount == 3)
        #expect(scheduler.nextTickets().isEmpty, "no fourth request while three are physically outstanding")
        #expect(scheduler.complete(first[0]) == .store)
        #expect(scheduler.nextTickets().count == 1)
        #expect(scheduler.outstandingCount == 3)
    }

    @Test func priorityRadiatesFromSelection() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 4)
        scheduler.beginSession()
        scheduler.plan(requests(7), selectedIndex: 3)
        #expect(scheduler.queue.map(\.id) == [3, 4, 2, 5, 1, 6, 0].map { id($0) })
        scheduler.plan(requests(4), selectedIndex: nil)
        #expect(scheduler.queue.map(\.id) == [0, 1, 2, 3].map { id($0) })
    }

    @Test func completedCapturesSurviveSelectionAndRequestChanges() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 2)
        scheduler.beginSession()
        scheduler.plan(requests(6), selectedIndex: 0)
        let tickets = scheduler.nextTickets()
        // The user tabs away and scrolls: the visible set no longer includes the in-flight windows.
        scheduler.plan(Array(requests(6).suffix(2)), selectedIndex: 1)
        #expect(scheduler.complete(tickets[0]) == .store)
        // Even after dismissal, an in-flight capture is stored when it lands.
        scheduler.endSession()
        #expect(scheduler.complete(tickets[1]) == .store)
        #expect(scheduler.complete(tickets[1]) == .unknownTicket, "duplicate completion is rejected")
    }

    @Test func onlyClosedWindowsAndPurgesDiscard() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 3)
        scheduler.beginSession()
        scheduler.plan(requests(3), selectedIndex: 0)
        let tickets = scheduler.nextTickets()
        scheduler.windowClosed(id(1))
        #expect(scheduler.complete(tickets[0]) == .store)
        #expect(scheduler.complete(tickets[1]) == .discardClosed)
        scheduler.purge()
        #expect(scheduler.complete(tickets[2]) == .discardPurged)
        #expect(scheduler.outstandingCount == 0)
    }

    @Test func eachSessionRefreshesOnceAndOutstandingWorkSpansSessions() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 2)
        scheduler.beginSession()
        scheduler.plan(requests(3), selectedIndex: 0)
        let first = scheduler.nextTickets()
        #expect(scheduler.complete(first[0]) == .store)
        _ = scheduler.nextTickets()
        // Re-planning within the session never re-requests refreshed windows.
        scheduler.plan(requests(3), selectedIndex: 2)
        #expect(scheduler.queue.isEmpty)
        scheduler.endSession()
        #expect(scheduler.queue.isEmpty && scheduler.outstandingCount == 2)
        // Next open: windows are eligible again, but in-flight ones are not duplicated and the cap holds.
        scheduler.beginSession()
        scheduler.plan(requests(3), selectedIndex: 0, fresh: [id(0)])
        #expect(scheduler.queue.isEmpty, "0 is fresh; 1 and 2 are still in flight")
        #expect(scheduler.nextTickets().isEmpty)
    }

    @Test func withheldCallbacksCannotAccumulateRequests() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 4)
        for _ in 0..<200 {
            scheduler.beginSession()
            scheduler.plan(requests(20), selectedIndex: 5)
            _ = scheduler.nextTickets()
            scheduler.endSession()
            #expect(scheduler.outstandingCount <= 4)
        }
        scheduler.purge()
        for ticket in scheduler.outstandingTickets { #expect(scheduler.complete(ticket) == .discardPurged) }
        #expect(scheduler.outstandingCount == 0)
    }
}

struct StableSelectionGateTests {
    @Test func startsOnlyAfterStableDelay() {
        var gate = StableSelectionGate<Int>(delay: 0.1)
        #expect(gate.update(1, now: 0) == .init(stopLive: false, fireAt: 0.1))
        #expect(gate.fire(now: 0.05) == nil)
        #expect(gate.fire(now: 0.1) == 1)
        #expect(gate.committed == 1)
        #expect(gate.update(1, now: 0.2) == .init(stopLive: false, fireAt: nil))
    }

    @Test func rapidTabbingNeverStartsAndChangeStopsImmediately() {
        var gate = StableSelectionGate<Int>(delay: 0.1)
        var t = 0.0
        for key in 1...10 {
            _ = gate.update(key, now: t)
            t += 0.03
            #expect(gate.fire(now: t) == nil)
        }
        #expect(gate.fire(now: t + 0.1) == 10)
        let change = gate.update(11, now: t + 0.2)
        #expect(change.stopLive && abs((change.fireAt ?? 0) - (t + 0.3)) < 1e-9)
        #expect(gate.committed == nil)
    }

    @Test func hideStopsAndResetRestarts() {
        var gate = StableSelectionGate<Int>(delay: 0.1)
        _ = gate.update(1, now: 0)
        _ = gate.fire(now: 0.1)
        #expect(gate.update(nil, now: 0.2) == .init(stopLive: true, fireAt: nil))
        #expect(gate.fire(now: 1) == nil)
        _ = gate.update(1, now: 1)
        _ = gate.fire(now: 1.1)
        gate.reset()
        #expect(abs((gate.update(1, now: 2).fireAt ?? 0) - 2.1) < 1e-9, "after a pause the same selection restarts")
    }
}
