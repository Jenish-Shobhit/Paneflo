import Testing
@testable import PanefloCore

/// ST-03: SnapshotScheduler and ThumbnailCache under withheld, late, duplicate and forged callbacks.
struct StressSnapshotPipelineTests {
    private func wid(_ n: UInt32) -> WindowIdentity {
        .init(process: .init(pid: 77, launchToken: 1), number: n, incarnation: 1)
    }

    private enum Expected { case store, closed, purged }
    private struct Held {
        var ticket: SnapshotTicket
        var closed = false
        var timedOut = false
        var timedOutAt = 0.0
    }

    @Test func schedulerHoldsInvariantsUnderRandomCallbackOrder() {
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            let limit = rng.int(2...4)
            let grace = Double(rng.int(1...20))
            var scheduler = SnapshotScheduler(concurrencyLimit: limit, abandonedGrace: grace)
            var pool = (0..<14).map { UInt32($0) }
            var held: [UInt64: Held] = [:]        // by serial: tickets whose callbacks are pending (or abandoned)
            var finished: Set<UInt64> = []        // serials whose completion was already consumed or forgotten
            var issuedSerials: Set<UInt64> = []
            var now = 0.0
            var knownLost: [UInt64] = []          // serials released from grace, oldest first
            for step in 0..<400 {
                let ctx: Comment = "seed \(seed) step \(step)"
                now += rng.double(0...3)
                switch rng.int(0...99) {
                case 0..<8: scheduler.beginSession()
                case 8..<14: scheduler.endSession()
                case 14..<34:
                    let n = rng.int(0...pool.count + 3)
                    let requests = (0..<n).map { _ in SnapshotRequest(id: wid(rng.pick(pool)), windowNumber: 5) }
                    let fresh = Set((0..<rng.int(0...2)).map { _ in wid(rng.pick(pool)) })
                    scheduler.plan(requests, selectedIndex: rng.chance(0.2) ? nil : rng.int(-2...n + 2), fresh: fresh)
                    let ids = scheduler.queue.map(\.id)
                    #expect(ids.count == Set(ids).count, "duplicate queue entries; \(ctx)")
                    #expect(ids.allSatisfy { id in pool.contains(id.number) }, "closed window queued; \(ctx)")
                    if !scheduler.sessionActive { #expect(ids.isEmpty, ctx) }
                case 34..<52:
                    let abandonedBefore = scheduler.abandonedCount
                    let active = scheduler.sessionActive
                    let tickets = scheduler.nextTickets(maximum: rng.chance(0.3) ? rng.int(0...2) : Int.max)
                    if !tickets.isEmpty {
                        #expect(active, "ticket issued outside a session; \(ctx)")
                        #expect(abandonedBefore < scheduler.abandonedLimit, "ticket issued with abandoned capacity full; \(ctx)")
                    }
                    for t in tickets {
                        #expect(issuedSerials.insert(t.serial).inserted, "serial reused; \(ctx)")
                        held[t.serial] = Held(ticket: t)
                    }
                case 52..<72: // deliver a random pending callback
                    guard let serial = held.keys.sorted().randomElement(using: &rng), let entry = held[serial] else { break }
                    held[serial] = nil; knownLost.removeAll { $0 == serial }
                    let result = scheduler.complete(entry.ticket)
                    if entry.timedOut {
                        if finished.contains(serial) { #expect(result == .unknownTicket, "forgotten late callback; \(ctx)") }
                        else { #expect(result == .lateAfterTimeout, "late callback must be dropped; \(ctx)") }
                    } else if entry.ticket.epoch != scheduler.epoch {
                        #expect(result == .discardPurged, "purged result stored; \(ctx)")
                    } else if entry.closed {
                        #expect(result == .discardClosed, "closed window result stored; \(ctx)")
                    } else {
                        #expect(result == .store, "result lost; \(ctx)")
                    }
                    finished.insert(serial)
                    // The exact same completion again is never accepted.
                    #expect(scheduler.complete(entry.ticket) == .unknownTicket, "duplicate accepted; \(ctx)")
                case 72..<80: // time out a random not-yet-timed-out ticket
                    let live = held.values.filter { !$0.timedOut }.map(\.ticket.serial).sorted()
                    guard let serial = live.randomElement(using: &rng), var entry = held[serial] else { break }
                    #expect(scheduler.timeout(entry.ticket, now: now) == .timedOut, ctx)
                    entry.timedOut = true; entry.timedOutAt = now
                    held[serial] = entry
                    #expect(scheduler.timeout(entry.ticket, now: now) == .unknownTicket, "double timeout; \(ctx)")
                case 80..<84: // forged ticket
                    let forged = SnapshotTicket(request: .init(id: wid(rng.pick(pool)), windowNumber: 5),
                                                serial: UInt64(10_000 + rng.int(0...1000)), epoch: scheduler.epoch)
                    #expect(scheduler.complete(forged) == .unknownTicket, "forged ticket accepted; \(ctx)")
                    #expect(scheduler.timeout(forged, now: now) == .unknownTicket, ctx)
                case 84..<90:
                    scheduler.releaseExpiredAbandoned(now: now)
                    for (serial, entry) in held.sorted(by: { $0.key < $1.key }) where entry.timedOut && !finished.contains(serial)
                        && !knownLost.contains(serial) && now - entry.timedOutAt >= grace {
                        knownLost.append(serial)
                    }
                    while knownLost.count > SnapshotScheduler.forgottenLimit { finished.insert(knownLost.removeFirst()) }
                case 90..<94 where pool.count > 3:
                    let id = rng.pick(pool)
                    scheduler.windowClosed(wid(id))
                    pool.removeAll { $0 == id }
                    for serial in held.keys where held[serial]?.ticket.id == wid(id) && held[serial]?.timedOut == false {
                        held[serial]?.closed = true
                    }
                    #expect(!scheduler.queue.contains { $0.id == wid(id) }, "closed window still queued; \(ctx)")
                case 94..<96: scheduler.purge()
                case 96..<98: scheduler.markForRetry(Set((0..<3).map { _ in wid(rng.pick(pool)) }))
                default: break
                }
                #expect(scheduler.outstandingCount <= scheduler.concurrencyLimit, "concurrency cap exceeded; \(ctx)")
                #expect(scheduler.abandonedCount <= scheduler.concurrencyLimit + scheduler.abandonedLimit, "abandoned unbounded; \(ctx)")
                #expect(scheduler.lostCount <= SnapshotScheduler.forgottenLimit, "lost set unbounded; \(ctx)")
                #expect(scheduler.outstandingCount == held.values.filter { !$0.timedOut }.count, "outstanding drift; \(ctx)")
            }
            // Liveness: deliver everything, expire grace, and the queue must drain.
            now += 1_000
            scheduler.releaseExpiredAbandoned(now: now)
            for entry in held.values.sorted(by: { $0.ticket.serial < $1.ticket.serial }) { _ = scheduler.complete(entry.ticket) }
            #expect(scheduler.outstandingCount == 0 && scheduler.abandonedCount == 0, "seed \(seed): capacity leaked after all callbacks")
            scheduler.beginSession()
            scheduler.plan(pool.map { SnapshotRequest(id: wid($0), windowNumber: 5) }, selectedIndex: 0)
            var served = Set<WindowIdentity>()
            for _ in 0..<(pool.count + 2) {
                let tickets = scheduler.nextTickets()
                for t in tickets { served.insert(t.id); #expect(scheduler.complete(t) == .store, "seed \(seed): drain result lost") }
                if tickets.isEmpty { break }
            }
            #expect(scheduler.queue.isEmpty && served.count == pool.count, "seed \(seed): queue starved (\(served.count)/\(pool.count))")
        }
    }

    @Test func abandonedCapacityRecoversAfterGraceInsteadOfStarvingForever() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 2, abandonedGrace: 10)
        let requests = (0..<40).map { SnapshotRequest(id: wid(UInt32($0)), windowNumber: 1) }
        scheduler.beginSession()
        scheduler.plan(requests, selectedIndex: 0)
        var tickets: [SnapshotTicket] = []
        var now = 0.0
        // Callbacks never arrive: every issued ticket times out.
        for _ in 0..<10 {
            for t in scheduler.nextTickets() { tickets.append(t); #expect(scheduler.timeout(t, now: now) == .timedOut) }
            now += 1
        }
        #expect(tickets.count <= scheduler.abandonedLimit + scheduler.concurrencyLimit, "abandoned requests accumulate unbounded")
        #expect(scheduler.nextTickets().isEmpty, "blocked while abandoned capacity is full")
        now += 11
        scheduler.releaseExpiredAbandoned(now: now)
        #expect(!scheduler.nextTickets().isEmpty, "starved permanently after lost callbacks")
        for t in tickets.prefix(1) { #expect(scheduler.complete(t) == .lateAfterTimeout) }
    }

    @Test func cacheMatchesNaiveLRUModelAndByteBound() {
        struct Row { var id: WindowIdentity; var wn: UInt32; var bytes: Int; var at: Double }
        for seed in UInt64(0)..<300 {
            var rng = FuzzRandom(seed: seed)
            var limit = rng.int(0...4000)
            let maxEntry = rng.int(0...1500)
            var cache = ThumbnailCache<Int>(byteLimit: limit, maximumEntryBytes: maxEntry)
            var model: [Row] = []      // LRU first
            let sizes = [Int.min, -1, 0, 1, 7, 100, 700, 1024, 1500, 4000, Int.max]
            for step in 0..<300 {
                let ctx: Comment = "seed \(seed) step \(step)"
                let id = wid(UInt32(rng.int(0...11)))
                switch rng.int(0...99) {
                case 0..<55:
                    let bytes = rng.pick(sizes), wn = UInt32(rng.int(1...2)), at = rng.double(0...50)
                    let result = cache.insert(id: id, windowNumber: wn, payload: step, bytes: bytes, capturedAt: at)
                    let mlimit = max(0, limit)
                    if !(bytes > 0 && bytes <= max(0, maxEntry) && bytes <= mlimit) {
                        #expect(result == .rejected, ctx)
                    } else if let e = model.first(where: { $0.id == id }), e.wn == wn, e.at > at {
                        #expect(result == .olderThanCached, ctx)
                    } else {
                        model.removeAll { $0.id == id }
                        var evicted: [WindowIdentity] = []
                        while model.reduce(0, { $0 + $1.bytes }) > mlimit - bytes { evicted.append(model.removeFirst().id) }
                        model.append(Row(id: id, wn: wn, bytes: bytes, at: at))
                        #expect(result == .stored(evicted: evicted), "eviction order differs; \(ctx)")
                    }
                case 55..<75:
                    let wn: UInt32? = rng.chance(0.4) ? nil : UInt32(rng.int(1...2))
                    let hit = cache.entry(for: id, windowNumber: wn)
                    if let i = model.firstIndex(where: { $0.id == id }), wn == nil || wn == model[i].wn {
                        #expect(hit != nil, ctx)
                        model.append(model.remove(at: i))
                    } else { #expect(hit == nil, ctx) }
                case 75..<80:
                    let before = cache.lruOrder
                    _ = cache.peek(id)
                    #expect(cache.lruOrder == before, "peek reordered; \(ctx)")
                case 80..<87:
                    #expect(cache.remove(id) == model.contains { $0.id == id }, ctx)
                    model.removeAll { $0.id == id }
                case 87..<91:
                    let alive = Set((0..<12).filter { _ in rng.chance(0.6) }.map { wid(UInt32($0)) })
                    cache.retainOnly(alive)
                    model.removeAll { !alive.contains($0.id) }
                case 91..<96:
                    limit = rng.int(-10...4000)
                    cache.setByteLimit(limit)
                    while model.reduce(0, { $0 + $1.bytes }) > max(0, limit) { model.removeFirst() }
                case 96..<98:
                    cache.removeAll(); model.removeAll()
                default: break
                }
                #expect(cache.totalBytes == model.reduce(0) { $0 + $1.bytes }, "totalBytes drift; \(ctx)")
                #expect(cache.totalBytes <= max(0, limit), "byte bound exceeded; \(ctx)")
                #expect(cache.lruOrder == model.map(\.id), "LRU order differs; \(ctx)")
                #expect(cache.count == model.count, ctx)
            }
        }
    }

    @Test func cacheStaysBoundedAndFastOverTenThousandOperations() {
        var cache = ThumbnailCache<Int>(byteLimit: 800, maximumEntryBytes: 8)
        var rng = FuzzRandom(seed: 4242)
        let start = ContinuousClock.now
        for i in 0..<10_000 {
            let id = WindowIdentity(process: .init(pid: Int32(i % 500), launchToken: 1), number: UInt32(i), incarnation: 1)
            cache.insert(id: id, windowNumber: 1, payload: i, bytes: rng.int(1...8), capturedAt: Double(i))
            if i % 7 == 0 { _ = cache.entry(for: id) }
            #expect(cache.totalBytes <= 800 && cache.count <= 800)
        }
        #expect(ContinuousClock.now - start < .seconds(5), "cache operations too slow (linear eviction scan?)")
        #expect(cache.count <= 800)
    }
}
