// MARK: - Memory pressure

public enum MemoryPressureLevel: Int, Comparable, Sendable {
    case normal, warning, critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2, 3: self = .warning
        default: self = .normal
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PreviewQuality: Equatable, Sendable {
    public var thumbnailByteLimit: Int
    /// Multiplies the card's pixel size for snapshots and the live stream.
    public var pixelScale: Double
    public var liveFramesPerSecond: Int
    public var snapshotsAllowed: Bool
    public var liveAllowed: Bool
}

/// Warning degrades, critical stops and purges, normal resumes. Previews are never left paused
/// once pressure returns to normal.
public struct PreviewPressurePolicy: Sendable {
    public struct Transition: Equatable, Sendable {
        public var qualityChanged = false
        public var stopLive = false
        public var purge = false
        /// Restart refresh and live work for a visible surface.
        public var resume = false
    }

    public let baseByteLimit: Int
    public let baseFramesPerSecond: Int
    public let degradedFramesPerSecond: Int
    public private(set) var level: MemoryPressureLevel

    public init(level: MemoryPressureLevel = .normal, baseByteLimit: Int = 24 * 1024 * 1024,
                baseFramesPerSecond: Int = 30, degradedFramesPerSecond: Int = 15) {
        self.level = level
        self.baseByteLimit = max(0, baseByteLimit)
        self.baseFramesPerSecond = max(1, baseFramesPerSecond)
        self.degradedFramesPerSecond = max(1, min(baseFramesPerSecond, degradedFramesPerSecond))
    }

    public var quality: PreviewQuality { Self.quality(level, self) }

    public mutating func apply(_ next: MemoryPressureLevel) -> Transition {
        guard next != level else { return Transition() }
        let previous = level
        level = next
        var transition = Transition(qualityChanged: true)
        switch next {
        case .critical:
            transition.stopLive = true
            transition.purge = true
        case .warning:
            transition.resume = previous == .critical
        case .normal:
            transition.resume = true
        }
        return transition
    }

    private static func quality(_ level: MemoryPressureLevel, _ policy: Self) -> PreviewQuality {
        switch level {
        case .normal:
            PreviewQuality(thumbnailByteLimit: policy.baseByteLimit, pixelScale: 1,
                           liveFramesPerSecond: policy.baseFramesPerSecond, snapshotsAllowed: true, liveAllowed: true)
        case .warning:
            PreviewQuality(thumbnailByteLimit: policy.baseByteLimit / 2, pixelScale: 0.5,
                           liveFramesPerSecond: policy.degradedFramesPerSecond, snapshotsAllowed: true, liveAllowed: true)
        case .critical:
            PreviewQuality(thumbnailByteLimit: 0, pixelScale: 0.5, liveFramesPerSecond: 0,
                           snapshotsAllowed: false, liveAllowed: false)
        }
    }
}

// MARK: - Card presentation

public enum PreviewUnavailableReason: Equatable, Sendable {
    case minimized
    /// Has a window number but ScreenCaptureKit does not list it on screen: another Space,
    /// fully covered by a full-screen app, or not yet composited.
    case otherSpace
    case appHidden
    /// No window number could be resolved for this window.
    case noWindowNumber
    case permissionRequired
    case captureFailed
}

public enum PreviewPauseReason: Equatable, Sendable {
    case memoryPressure, sleeping, sessionInactive, previewsOff
}

/// What a card should show, independent of pixels.
public enum PreviewPresentation: Equatable, Sendable {
    case live
    /// `note` explains why the snapshot cannot be refreshed right now (minimized, other Space...).
    case snapshot(capturedAt: Double, note: PreviewUnavailableReason?)
    case loading
    case unavailable(PreviewUnavailableReason)
    case paused(PreviewPauseReason)

    public var isLive: Bool { self == .live }
}

public enum PreviewLabel {
    public static func text(_ presentation: PreviewPresentation, now: Double) -> String {
        switch presentation {
        case .live: return "Live"
        case let .snapshot(capturedAt, note):
            let base = "Snapshot · " + age(now - capturedAt)
            return note.map { base + " · " + short($0) } ?? base
        case .loading: return "Loading preview…"
        case .unavailable(let reason): return "Unavailable: " + short(reason)
        case .paused(let reason): return "Paused: " + pause(reason)
        }
    }

    /// "0s"..."59s", "1m"..."59m", then hours.
    public static func age(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m" }
        return "\(value / 3600)h"
    }

    public static func short(_ reason: PreviewUnavailableReason) -> String {
        switch reason {
        case .minimized: "minimized"
        case .otherSpace: "not on this Space"
        case .appHidden: "app hidden"
        case .noWindowNumber: "window not identified"
        case .permissionRequired: "Screen Recording off"
        case .captureFailed: "capture failed"
        }
    }

    private static func pause(_ reason: PreviewPauseReason) -> String {
        switch reason {
        case .memoryPressure: "memory pressure"
        case .sleeping: "sleep"
        case .sessionInactive: "session inactive"
        case .previewsOff: "previews off"
        }
    }
}

public enum PreviewAvailability {
    /// Why a window cannot be captured now, or nil if it can be tried.
    /// `listedOnScreen` is nil until shareable content has been discovered.
    public static func reason(isMinimized: Bool, appHidden: Bool, windowNumber: UInt32?,
                              listedOnScreen: Bool?) -> PreviewUnavailableReason? {
        if isMinimized { return .minimized }
        if appHidden { return .appHidden }
        guard windowNumber != nil else { return .noWindowNumber }
        if listedOnScreen == false { return .otherSpace }
        return nil
    }

    /// Combines a cached snapshot (if any) with the current capture state.
    public static func presentation(cachedAt: Double?, unavailable: PreviewUnavailableReason?,
                                    paused: PreviewPauseReason?, live: Bool) -> PreviewPresentation {
        if live, paused == nil, unavailable == nil { return .live }
        if let cachedAt { return .snapshot(capturedAt: cachedAt, note: paused == nil ? unavailable : nil) }
        if let paused { return .paused(paused) }
        if let unavailable { return .unavailable(unavailable) }
        return .loading
    }
}

// MARK: - Screen Recording

public enum ScreenRecordingStatus: Equatable, Sendable {
    case unknown
    case granted
    case denied
    /// TCC reports access but ScreenCaptureKit still refuses: a relaunch is needed.
    case restartRequired

    /// `preflight`: CGPreflightScreenCaptureAccess. `contentProbe`: whether an
    /// SCShareableContent request succeeded (nil when not probed). A successful probe is
    /// authoritative because preflight can stay false until relaunch.
    public static func resolve(preflight: Bool, contentProbe: Bool?) -> Self {
        switch (preflight, contentProbe) {
        case (_, true?): .granted
        case (true, false?): .restartRequired
        case (true, nil): .granted
        case (false, false?): .denied
        case (false, nil): .unknown
        }
    }

    public var settingsMessage: String? {
        switch self {
        case .granted: nil
        case .unknown, .denied: "Allow Paneflo under Privacy & Security › Screen Recording to show window previews."
        case .restartRequired: "Restart Paneflo to finish enabling previews."
        }
    }
}
