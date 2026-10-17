import Testing
@testable import PanefloCore

struct ThumbnailCacheTests {
    private func id(_ n: UInt32, token: UInt64 = 1) -> WindowIdentity {
        .init(process: .init(pid: 20, launchToken: token), number: n, incarnation: 1)
    }

    @Test func byteBoundEvictsLeastRecentlyUsedFirst() {
        var cache = ThumbnailCache<Int>(byteLimit: 1_000, maximumEntryBytes: 500)
        for n: UInt32 in 1...3 {
            #expect(cache.insert(id: id(n), windowNumber: n, payload: Int(n), bytes: 300, capturedAt: 0) == .stored(evicted: []))
        }
        // Touch 1 so 2 becomes the oldest.
        #expect(cache.entry(for: id(1))?.payload == 1)
        #expect(cache.lruOrder == [id(2), id(3), id(1)])
        #expect(cache.insert(id: id(4), windowNumber: 4, payload: 4, bytes: 300, capturedAt: 1) == .stored(evicted: [id(2)]))
        #expect(cache.totalBytes == 900)
        #expect(cache.insert(id: id(5), windowNumber: 5, payload: 5, bytes: 500, capturedAt: 2) == .stored(evicted: [id(3), id(1)]))
        #expect(cache.identities == [id(4), id(5)])
        #expect(cache.totalBytes <= cache.byteLimit)
    }

    @Test func neverExceedsBudgetAcrossManyInserts() {
        var cache = ThumbnailCache<Int>(byteLimit: 10_000, maximumEntryBytes: 4_000)
        for n in 0..<500 {
            let bytes = 1 + (n * 7_919) % 4_000
            cache.insert(id: id(UInt32(n % 37)), windowNumber: UInt32(n % 37), payload: n, bytes: bytes, capturedAt: Double(n))
            #expect(cache.totalBytes <= 10_000)
        }
    }

    @Test func rejectsInvalidOversizedAndOlderCaptures() {
        var cache = ThumbnailCache<Int>(byteLimit: 1_000, maximumEntryBytes: 400)
        #expect(cache.insert(id: id(1), windowNumber: 1, payload: 1, bytes: 0, capturedAt: 0) == .rejected)
        #expect(cache.insert(id: id(1), windowNumber: 1, payload: 1, bytes: 401, capturedAt: 0) == .rejected)
        #expect(cache.insert(id: id(1), windowNumber: 1, payload: 1, bytes: 100, capturedAt: 5) == .stored(evicted: []))
        #expect(cache.insert(id: id(1), windowNumber: 1, payload: 2, bytes: 100, capturedAt: 4) == .olderThanCached)
        #expect(cache.peek(id(1))?.payload == 1)
        #expect(cache.insert(id: id(1), windowNumber: 1, payload: 3, bytes: 200, capturedAt: 6) == .stored(evicted: []))
        #expect(cache.peek(id(1))?.payload == 3 && cache.totalBytes == 200)
        #expect(ThumbnailCache<Int>.payloadBytes(bytesPerRow: Int.max, height: 2) == nil)
        #expect(ThumbnailCache<Int>.payloadBytes(bytesPerRow: 1_856, height: 204) == 378_624)
    }

    @Test func entryCarriesCaptureTimeAndMatchesWindowNumber() {
        var cache = ThumbnailCache<Int>()
        cache.insert(id: id(1), windowNumber: 77, payload: 1, bytes: 10, capturedAt: 12.5)
        #expect(cache.entry(for: id(1), windowNumber: 77)?.capturedAt == 12.5)
        // Minimized/hidden windows have no number now: the identity still finds its snapshot.
        #expect(cache.entry(for: id(1), windowNumber: nil) != nil)
        // A different CGWindowID for the same identity is a miss.
        #expect(cache.entry(for: id(1), windowNumber: 78) == nil)
        // A reused PID with a new launch token is a different identity.
        #expect(cache.entry(for: id(1, token: 2)) == nil)
    }

    @Test func survivesDismissalAndPurgesOnlyOnRequest() {
        var cache = ThumbnailCache<Int>()
        var scheduler = SnapshotScheduler()
        scheduler.beginSession()
        cache.insert(id: id(1), windowNumber: 1, payload: 1, bytes: 10, capturedAt: 0)
        cache.insert(id: id(2), windowNumber: 2, payload: 2, bytes: 10, capturedAt: 0)
        scheduler.endSession()
        #expect(cache.count == 2, "dismissal keeps snapshots")
        #expect(cache.retainOnly([id(1)]) == [id(2)], "a closed window is purged")
        #expect(cache.setByteLimit(5) == [id(1)], "a smaller budget evicts")
        cache.setByteLimit(100)
        cache.insert(id: id(3), windowNumber: 3, payload: 3, bytes: 10, capturedAt: 0)
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalBytes == 0)
    }
}
