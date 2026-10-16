import Foundation
import Testing
@testable import PanefloCore

struct CaptureAdmissionTests {
    @Test
    func testWithheldCallbacksCannotAccumulateReplacementWork() throws {
        var admission = CaptureAdmission(snapshotLimit: 2)
        let optionalValue9 = admission.beginSnapshot(window: windowID(1), generation: 1)
        let first = try #require(optionalValue9)
        let optionalValue10 = admission.beginSnapshot(window: windowID(2), generation: 1)
        let second = try #require(optionalValue10)
        admission.timeout(first)
        admission.cancel(second)
        for _ in 0..<200 {
            let outcome14 = admission.beginSnapshot(window: windowID(3), generation: 2) == nil
            #expect(outcome14)
        }
        #expect(admission.physicallyOutstandingCount == 2)
        #expect(admission.logicallyCancelledCount == 2)
        #expect(admission.circuitIsOpen)
        let outcome19 = admission.complete(second) == .discard
        #expect(outcome19)
        let outcome20 = admission.beginSnapshot(window: windowID(3), generation: 2) == nil
        #expect(outcome20)
        let outcome21 = admission.complete(first) == .discard
        #expect(outcome21)
        #expect(!(admission.circuitIsOpen))
        let outcome23 = admission.beginSnapshot(window: windowID(3), generation: 2) != nil
        #expect(outcome23)
        let outcome24 = admission.complete(first) == nil
        #expect(outcome24)
    }

    @Test
    func testSingleLiveLeaseWaitsForRealTeardownAndHiddenIsNotActive() throws {
        var admission = CaptureAdmission()
        let outcome30 = admission.beginLive(window: windowID(1), surfaceVisible: false) == nil
        #expect(outcome30)
        let optionalValue31 = admission.beginLive(window: windowID(1), surfaceVisible: true)
        let lease = try #require(optionalValue31)
        #expect(admission.activeLiveCount == 1)
        let outcome33 = admission.beginLive(window: windowID(2), surfaceVisible: true) == nil
        #expect(outcome33)
        admission.hideSurfaces()
        #expect(admission.activeLiveCount == 0)
        #expect(admission.physicallyOutstandingLiveCount == 1)
        let outcome37 = admission.beginLive(window: windowID(2), surfaceVisible: true) == nil
        #expect(outcome37)
        let outcome38 = admission.completeLiveStop(lease)
        #expect(outcome38)
        let outcome39 = !(admission.completeLiveStop(lease))
        #expect(outcome39)
        #expect(admission.physicallyOutstandingLiveCount == 0)
        let outcome41 = admission.beginLive(window: windowID(2), surfaceVisible: true) != nil
        #expect(outcome41)
    }

    @Test
    func testRepeatedSessionsSettleWithoutOutstandingWork() throws {
        var admission = CaptureAdmission()
        var budget = PreviewBudget()
        for generation in UInt64(1)...200 {
            let optionalValue49 = admission.beginSnapshot(window: windowID(1), generation: generation)
            let ticket = try #require(optionalValue49)
            let optionalValue50 = budget.reserve(estimatedBytes: 640 * 400 * 4)
            let reservation = try #require(optionalValue50)
            budget.submit(reservation)
            admission.hideSurfaces()
            budget.cancel(reservation)
            let outcome54 = admission.complete(ticket) == .discard
            #expect(outcome54)
            let outcome55 = budget.reconcile(reservation, actualBytes: 640 * 400 * 4) == .discarded
            #expect(outcome55)
        }
        #expect(admission.physicallyOutstandingCount == 0)
        #expect(budget.accountedBytes == 0)
        #expect(budget.reservationCount == 0)
    }
}
