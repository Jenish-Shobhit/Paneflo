import Testing
@testable import PanefloCore

struct PreviewPressurePolicyTests {
    @Test func kernelLevelsMap() {
        #expect(MemoryPressureLevel(kernelLevel: 1) == .normal)
        #expect(MemoryPressureLevel(kernelLevel: 2) == .warning)
        #expect(MemoryPressureLevel(kernelLevel: 4) == .critical)
        #expect(MemoryPressureLevel(kernelLevel: 0) == .normal)
    }

    @Test func warningDegradesWithoutStopping() {
        var policy = PreviewPressurePolicy(baseByteLimit: 24 * 1024 * 1024)
        let transition = policy.apply(.warning)
        #expect(transition == .init(qualityChanged: true, stopLive: false, purge: false, resume: false))
        #expect(policy.quality.thumbnailByteLimit == 12 * 1024 * 1024)
        #expect(policy.quality.pixelScale == 0.5)
        #expect(policy.quality.liveFramesPerSecond == 15)
        #expect(policy.quality.liveAllowed && policy.quality.snapshotsAllowed)
    }

    @Test func criticalStopsAndPurgesThenNormalResumes() {
        var policy = PreviewPressurePolicy()
        let critical = policy.apply(.critical)
        #expect(critical.stopLive && critical.purge)
        #expect(!policy.quality.liveAllowed && !policy.quality.snapshotsAllowed && policy.quality.thumbnailByteLimit == 0)
        let warning = policy.apply(.warning)
        #expect(warning.resume && !warning.purge, "leaving critical resumes in degraded mode")
        let normal = policy.apply(.normal)
        #expect(normal.resume)
        #expect(policy.quality == PreviewQuality(thumbnailByteLimit: 24 * 1024 * 1024, pixelScale: 1,
                                                 liveFramesPerSecond: 30, snapshotsAllowed: true, liveAllowed: true))
        #expect(policy.apply(.normal) == .init(), "repeated level is a no-op")
    }
}

struct PreviewPresentationTests {
    @Test func unavailableReasons() {
        #expect(PreviewAvailability.reason(isMinimized: true, appHidden: false, windowNumber: nil, listedOnScreen: nil) == .minimized)
        #expect(PreviewAvailability.reason(isMinimized: false, appHidden: true, windowNumber: nil, listedOnScreen: nil) == .appHidden)
        #expect(PreviewAvailability.reason(isMinimized: false, appHidden: false, windowNumber: nil, listedOnScreen: nil) == .noWindowNumber)
        #expect(PreviewAvailability.reason(isMinimized: false, appHidden: false, windowNumber: 4, listedOnScreen: false) == .otherSpace)
        #expect(PreviewAvailability.reason(isMinimized: false, appHidden: false, windowNumber: 4, listedOnScreen: true) == nil)
        #expect(PreviewAvailability.reason(isMinimized: false, appHidden: false, windowNumber: 4, listedOnScreen: nil) == nil)
    }

    @Test func cachedSnapshotWinsOverUnavailableButIsLabelledHonestly() {
        let minimizedWithCache = PreviewAvailability.presentation(cachedAt: 10, unavailable: .minimized, paused: nil, live: false)
        #expect(minimizedWithCache == .snapshot(capturedAt: 10, note: .minimized))
        #expect(PreviewLabel.text(minimizedWithCache, now: 14.9) == "Snapshot · 4s · minimized")
        #expect(PreviewAvailability.presentation(cachedAt: nil, unavailable: .otherSpace, paused: nil, live: false) == .unavailable(.otherSpace))
        #expect(PreviewAvailability.presentation(cachedAt: nil, unavailable: nil, paused: .memoryPressure, live: false) == .paused(.memoryPressure))
        #expect(PreviewAvailability.presentation(cachedAt: 1, unavailable: nil, paused: .sleeping, live: true) == .snapshot(capturedAt: 1, note: nil))
        #expect(PreviewAvailability.presentation(cachedAt: 1, unavailable: nil, paused: nil, live: true) == .live)
        #expect(PreviewAvailability.presentation(cachedAt: nil, unavailable: nil, paused: nil, live: false) == .loading)
    }

    @Test func labels() {
        #expect(PreviewLabel.text(.live, now: 0) == "Live")
        #expect(PreviewLabel.text(.snapshot(capturedAt: 0, note: nil), now: 75) == "Snapshot · 1m")
        #expect(PreviewLabel.text(.unavailable(.otherSpace), now: 0) == "Unavailable: not on this Space")
        #expect(PreviewLabel.text(.paused(.memoryPressure), now: 0) == "Paused: memory pressure")
        #expect(PreviewLabel.age(-3) == "0s" && PreviewLabel.age(7_300) == "2h" && PreviewLabel.age(.nan) == "0s")
    }
}

struct ScreenRecordingStatusTests {
    @Test func probeIsAuthoritativeAndRestartOnlyWhenNeeded() {
        #expect(ScreenRecordingStatus.resolve(preflight: false, contentProbe: true) == .granted, "granted without relaunch")
        #expect(ScreenRecordingStatus.resolve(preflight: true, contentProbe: nil) == .granted)
        #expect(ScreenRecordingStatus.resolve(preflight: true, contentProbe: false) == .restartRequired)
        #expect(ScreenRecordingStatus.resolve(preflight: false, contentProbe: false) == .denied)
        #expect(ScreenRecordingStatus.resolve(preflight: false, contentProbe: nil) == .unknown)
        #expect(ScreenRecordingStatus.granted.settingsMessage == nil)
        #expect(ScreenRecordingStatus.restartRequired.settingsMessage == "Restart Paneflo to finish enabling previews.")
    }
}
