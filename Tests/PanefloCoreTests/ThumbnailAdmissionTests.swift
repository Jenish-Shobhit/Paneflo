import Testing
@testable import PanefloCore
struct ThumbnailAdmissionTests {
    private func id(_ n: UInt32, token: UInt64 = 1) -> WindowIdentity {
        .init(process: .init(pid: 20, launchToken: token), number: n, incarnation: 1)
    }
    @Test func actualStrideBudgetLRUEvictionAndTTL() {
        var cache = ThumbnailAdmission(byteLimit: 800, entryLimit: 2, ttl: 10)
        for n: UInt32 in 1...2 {
            let ticket = cache.begin(id(n))!
            let result1 = cache.complete(ticket, rowBytes: 40, height: 10, now: 0)
            #expect(result1)
        }
        let result2 = cache.contains(id(1), now: 1)
        #expect(result2)
        let ticket = cache.begin(id(3))!
        let result3 = cache.complete(ticket, rowBytes: 40, height: 10, now: 2)
        #expect(result3)
        #expect(cache.identities == Set([id(1), id(3)]))
        #expect(cache.retainedBytes == 800)
        let result4 = !cache.contains(id(1), now: 11)
        #expect(result4)
        #expect(cache.retainedBytes == 400)
    }
    @Test func staleCompletionCannotReleasePhysicalSlotEarlyOrAttachToReusedPID() {
        var cache = ThumbnailAdmission()
        let old = cache.begin(id(1))!
        for _ in 0..<200 { cache.invalidate(purge: true) }
        let result5 = cache.begin(id(1, token: 2)) == nil
        #expect(result5)
        let result6 = !cache.complete(old, rowBytes: 1600, height: 250, now: 0)
        #expect(result6)
        #expect(cache.outstanding == nil && cache.identities.isEmpty)
        let current = cache.begin(id(1, token: 2))!
        let result7 = !cache.complete(old, rowBytes: 1600, height: 250, now: 0)
        #expect(result7)
        #expect(cache.outstanding == current)
        let result8 = cache.complete(current, rowBytes: 1600, height: 250, now: 0)
        #expect(result8)
        #expect(cache.identities == Set([id(1, token: 2)]))
    }
    @Test func rejectsOverflowOversizeAndPurgesDeadIdentities() {
        var cache = ThumbnailAdmission()
        let overflow = cache.begin(id(1))!
        let result9 = !cache.complete(overflow, rowBytes: Int.max, height: 2, now: 0)
        #expect(result9)
        let large = cache.begin(id(2))!
        let result10 = !cache.complete(large, rowBytes: 4096, height: 250, now: 0)
        #expect(result10)
        let valid = cache.begin(id(3))!
        let result11 = cache.complete(valid, rowBytes: 1600, height: 250, now: 0)
        #expect(result11)
        cache.retainOnly([])
        #expect(cache.retainedBytes == 0)
    }
    @Test func removedIdentityInvalidatesResultButRetainsOutstandingSlot() {
        var cache = ThumbnailAdmission()
        let ticket = cache.begin(id(1))!
        cache.retainOnly([])
        let replacement = cache.begin(id(2))
        #expect(replacement == nil)
        let accepted = cache.complete(ticket, rowBytes: 1600, height: 250, now: 0)
        #expect(!accepted && cache.outstanding == nil && cache.identities.isEmpty)
    }

}
