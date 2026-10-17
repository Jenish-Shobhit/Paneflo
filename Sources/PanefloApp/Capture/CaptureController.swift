import AppKit
import PanefloCore
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreImage
import IOSurface

/// Developer-only A/B renderer selection; cadence, dimensions and capture configuration stay identical.
enum PreviewRenderer {
    static let usesReferenceRenderer = CommandLine.arguments.contains("--preview-reference-renderer")
}

/// Legacy request shape used by `DesktopController.onThumbnailViewport`.
struct WindowThumbnailRequest: Hashable, Sendable {
    let id: WindowIdentity
    let windowNumber: UInt32
    let ownerPID: pid_t
}

/// One card on a visible switching surface. Build it from the window registry:
/// `PreviewCard(id: record.id, windowNumber: service.captureWindowNumber(for: record.id), isMinimized: record.isMinimized)`.
struct PreviewCard: Hashable, Sendable {
    let id: WindowIdentity
    /// CGWindowID, or nil when the registry has none (minimized, app hidden, unresolved).
    let windowNumber: UInt32?
    let isMinimized: Bool
}

/// A live frame delivered without copying. Display it with `layer.contents = frame.surface` and
/// keep a reference to the frame while it is displayed (release it when replaced or hidden).
/// At most `LiveFrameBudget.limit` frames exist at once; a card that never releases its frame
/// stalls its own live updates rather than growing memory.
final class LiveFrame: @unchecked Sendable {
    let surface: IOSurface
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    /// System uptime when the frame reached Paneflo.
    let arrivedAt: Double
    private let budget: LiveFrameBudget

    fileprivate init?(buffer: CVPixelBuffer, budget: LiveFrameBudget, arrivedAt: Double) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer),
              let unmanaged = CVPixelBufferGetIOSurface(buffer) else { return nil }
        guard budget.acquire() else { return nil }
        surface = unsafeBitCast(unmanaged.takeUnretainedValue(), to: IOSurface.self)
        pixelBuffer = buffer
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        self.arrivedAt = arrivedAt
        self.budget = budget
    }

    deinit { budget.release() }
}

enum PreviewContent {
    case live(LiveFrame)
    /// A detached, owned raster at card size. Not animated; label it as a snapshot.
    case snapshot(CGImage)
    /// Keep the pixels currently shown (for example the last live frame) and update the label only.
    case keep
    /// Show the app icon / placeholder.
    case none
}

struct PreviewUpdate {
    let id: WindowIdentity
    let content: PreviewContent
    let presentation: PreviewPresentation
    /// "Live", "Snapshot · 4s", "Unavailable: minimized", "Paused: memory pressure"...
    func label(now: Double = ProcessInfo.processInfo.systemUptime) -> String {
        PreviewLabel.text(presentation, now: now)
    }
}

/// Capture engine for switching surfaces.
///
/// - One persistent, byte-bounded LRU of card-sized snapshots that survives dismissal.
/// - On open, 2–4 concurrent one-shot screenshots refresh every visible card, closest to the
///   selection first. Completed captures are cached even if the selection moved.
/// - One live SCStream, for the selected eligible window, started after the selection has been
///   stable for 100 ms, sized to the card, delivered as IOSurface frames. Hiding the surface
///   deactivates delivery and issues the stop at once; `liveStreamCount` reaches 0 when the
///   framework confirms the stop.
///
/// Card-layer wiring (new API):
/// - Open, Tab, scroll, filter: `updateSurface(visible: true, cards:, selected:, previewPixelSize:)`.
/// - Dismiss: `updateSurface(visible: false, cards: [], selected: nil, previewPixelSize: nil)`.
/// - Render every `onPreview` update; `preview(for:)` gives the current state synchronously.
/// - Registry change: `windowsChanged(alive:)`. Disabling previews: `stop()`.
@MainActor
final class CaptureController {
    // MARK: Public surface

    /// Card-layer delivery (new API). Called on the main thread.
    var onPreview: ((PreviewUpdate) -> Void)?
    var onScreenRecordingStatusChange: ((ScreenRecordingStatus) -> Void)?
    private(set) var screenRecordingStatus: ScreenRecordingStatus
    private(set) var status = "Previews off"
    var hasPermission: Bool { screenRecordingStatus == .granted || CGPreflightScreenCaptureAccess() }
    /// Physical live streams owned, including one whose stop has been issued but not confirmed.
    var liveStreamCount: Int { stream == nil ? 0 : 1 }
    var outstandingSnapshotCount: Int { scheduler.outstandingCount }
    var cacheBytes: Int { cache.totalBytes }
    var cacheCount: Int { cache.count }
    var pressureLevel: MemoryPressureLevel { pressure.level }

    // Legacy surface used by DesktopController/PanefloApplication until the card layer adopts `onPreview`.
    var onImage: ((CGImage?, String) -> Void)?
    var onThumbnail: ((WindowThumbnailRequest, CGImage) -> Void)?
    var onThumbnailsCleared: (() -> Void)?
    var isThumbnailCurrent: ((WindowThumbnailRequest) -> Bool)?

    // MARK: Tunables

    static let defaultPreviewPixelSize = CGSize(width: 464, height: 204)
    static let selectionStableDelay = 0.1
    static let snapshotFreshAge = 1.0
    static let contentMaxAgeOnOpen = 0.5
    static let contentMaxAge = 1.0
    static let discoveryTimeout = 2.0
    static let screenshotTimeout = 1.5
    static let liveFirstFrameTimeout = 1.5
    /// How long a listed window's SCWindow may be reused for capture without waiting for discovery.
    static let contentReuseAge = 5.0

    // MARK: State

    private var cache = ThumbnailCache<CGImage>()
    private lazy var runner: SnapshotRunner<CGImage> = makeRunner()
    private var scheduler: SnapshotScheduler {
        get { runner.scheduler }
        set { runner.scheduler = newValue }
    }
    private var failedThisSession: Set<WindowIdentity> = []
    private var abandonedDiscoveries = 0
    private var liveBreaker = CaptureCircuitBreaker()
    private var liveRetryTask: Task<Void, Never>?
    private var liveWatchdog: Task<Void, Never>?
    private var liveFirstFrameSeen = false
    private var sessionLiveKey: LiveKey?
    private var gate = StableSelectionGate<LiveKey>(delay: CaptureController.selectionStableDelay)
    private var gateTask: Task<Void, Never>?
    private var pressure: PreviewPressurePolicy
    private var sleeping = false
    private var sessionInactive = false
    private var previewsRequested = false

    private var sessionVisible = false
    private var sessionOpenedAt = 0.0
    private var sessionCards: [PreviewCard] = []
    private var sessionIDs: Set<WindowIdentity> = []
    private var selectedID: WindowIdentity?
    private var pixelBox = CaptureController.defaultPreviewPixelSize
    private var unavailable: [WindowIdentity: PreviewUnavailableReason] = [:]
    private var emitted: Set<WindowIdentity> = []
    private var hiddenPIDs: [pid_t: Bool] = [:]

    private var content: [CGWindowID: SCWindow] = [:]
    private var contentAt = -Double.infinity
    private var discovery: Task<[CGWindowID: SCWindow], Error>?
    private var discoveryInFlight = false

    private struct LiveKey: Hashable, Sendable {
        let windowNumber: UInt32
        /// 0 when unknown.
        let pid: pid_t
    }
    private struct LiveTarget: Equatable {
        let key: LiveKey
        var id: WindowIdentity?
        let pixelBox: CGSize
        let framesPerSecond: Int
    }
    private var desired: LiveTarget?
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var streamGeneration: UInt64?
    private var streamFramesPerSecond = 0
    private var streamPixelSize = (width: 0, height: 0)
    private var stopUnconfirmed = false
    private var lastLiveFrame: (frame: LiveFrame, target: LiveTarget)?
    private var liveRequestedAt: Double?
    private var diagnosticState = "idle"
    private let frameBudget = LiveFrameBudget()
    private let frameQueue = DispatchQueue(label: "Paneflo.selected-preview", qos: .userInitiated)

    // Legacy adapter state.
    private var legacyRequests: [WindowThumbnailRequest] = []
    private var legacyThumbnailsVisible = false
    private var legacySelection: LiveKey?
    private var legacySelectionVisible = false
    private var identityIndex: [LiveKey: WindowIdentity] = [:]

    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        pressure = PreviewPressurePolicy(level: Self.currentPressureLevel())
        screenRecordingStatus = ScreenRecordingStatus.resolve(preflight: CGPreflightScreenCaptureAccess(), contentProbe: nil)
        cache.setByteLimit(pressure.quality.thumbnailByteLimit)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else { return }
                let level: MemoryPressureLevel = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                self.applyPressure(level)
            }
        }
        source.resume()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { controller in
                switch name {
                case NSWorkspace.willSleepNotification: controller.sleeping = true; controller.pauseWork()
                case NSWorkspace.sessionDidResignActiveNotification: controller.sessionInactive = true; controller.pauseWork()
                case NSWorkspace.didWakeNotification: controller.sleeping = false; controller.resumeWork()
                default: controller.sessionInactive = false; controller.resumeWork()
                }
            }
        }
        observe(.default, NSApplication.didHideNotification) { $0.purge(reason: "appHidden") }
        observe(.default, NSApplication.didBecomeActiveNotification) { controller in
            if controller.previewsRequested, controller.screenRecordingStatus != .granted { controller.refreshScreenRecordingStatus() }
        }
    }

    /// Warms the ScreenCaptureKit connection and the shareable-content cache off the input path.
    /// The first request in a process measured ~0.8-1.0 s, so the app delegate should call this
    /// shortly after launch when previews are enabled. Idempotent; a no-op without Screen Recording
    /// access (it never prompts).
    func prewarm() {
        guard CGPreflightScreenCaptureAccess(), discovery == nil,
              ProcessInfo.processInfo.systemUptime - contentAt > Self.contentMaxAge else { return }
        Task { _ = try? await refreshContent() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor @Sendable (CaptureController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    private func makeRunner() -> SnapshotRunner<CGImage> {
        let runner = SnapshotRunner<CGImage>(scheduler: SnapshotScheduler(concurrencyLimit: 3),
                                             timeout: Self.screenshotTimeout) { [weak self] request in
            guard let self else { throw SnapshotFailure.failed }
            return try await self.screenshot(request)
        }
        runner.onOutcome = { [weak self] ticket, completion, outcome in self?.resolve(ticket, completion, outcome) }
        runner.onLate = { ticket, _ in
            // The late payload (an owned raster) is released here; nothing is stored.
            RuntimeDiagnostics.mark("thumbnail state=lateAfterTimeout serial=\(ticket.serial)")
        }
        runner.onBreakerChange = { [weak self] open in self?.snapshotBreakerChanged(open: open) }
        return runner
    }

    isolated deinit {
        memoryPressureSource?.cancel()
        gateTask?.cancel()
        liveRetryTask?.cancel()
        liveWatchdog?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        output?.deactivate()
        if let stream {
            // Keep the framework objects alive until physical stop completion, even on owner release.
            let retainedOutput = output
            stream.stopCapture { _ in withExtendedLifetime((stream, retainedOutput)) {} }
        }
    }

    // MARK: New card-layer API

    /// Call on open and whenever the visible cards, selection, or card pixel size change; call with
    /// `visible: false` on dismiss. Cheap: no capture, AX, or window-server call runs synchronously.
    /// Emits `onPreview` synchronously for each card not yet emitted in this session (cached snapshot,
    /// loading, or unavailable), then asynchronously as fresh snapshots and live frames land.
    func updateSurface(visible: Bool, cards: [PreviewCard], selected: WindowIdentity?, previewPixelSize: CGSize?) {
        if let previewPixelSize, previewPixelSize.width >= 2, previewPixelSize.height >= 2 { pixelBox = previewPixelSize }
        let selectedCard = cards.first { $0.id == selected }
        let live = selectedCard.flatMap { card in
            card.windowNumber.map { LiveKey(windowNumber: $0, pid: card.id.process.pid) }
        }
        for card in cards { if let number = card.windowNumber { identityIndex[LiveKey(windowNumber: number, pid: card.id.process.pid)] = card.id } }
        apply(visible: visible, cards: cards, selected: selected, live: selectedCard?.isMinimized == true ? nil : live)
    }

    /// Current state for building or recycling a card view.
    func preview(for card: PreviewCard) -> PreviewUpdate {
        if let last = lastLiveFrame, last.target.id == card.id, desired?.id == card.id, stream != nil {
            return PreviewUpdate(id: card.id, content: .live(last.frame), presentation: .live)
        }
        let entry = cache.entry(for: card.id, windowNumber: card.windowNumber)
        let presentation = PreviewAvailability.presentation(
            cachedAt: entry?.capturedAt, unavailable: reason(for: card), paused: pauseReason, live: false)
        return PreviewUpdate(id: card.id, content: entry.map { .snapshot($0.payload) } ?? .none, presentation: presentation)
    }

    /// Removes cached snapshots and pending work for windows that no longer exist.
    func windowsChanged(alive: Set<WindowIdentity>) {
        for id in cache.retainOnly(alive) { scheduler.windowClosed(id) }
        for id in sessionIDs where !alive.contains(id) { scheduler.windowClosed(id) }
        identityIndex = identityIndex.filter { alive.contains($0.value) }
        unavailable = unavailable.filter { alive.contains($0.key) }
    }

    /// Re-checks Screen Recording without relaunching (probes ScreenCaptureKit). Call it only after
    /// the user asked for previews (an unrequested probe can show the system prompt). Paneflo also
    /// calls it on app activation once previews were requested.
    func refreshScreenRecordingStatus() {
        Task { _ = try? await refreshContent() }
    }

    /// Call only from an explicit permission button.
    @discardableResult
    func requestPermission() -> Bool {
        previewsRequested = true
        let granted = CGRequestScreenCaptureAccess()
        if granted { setPermissionStatus(.resolve(preflight: true, contentProbe: nil)) }
        if granted, sessionVisible { resumeWork() }
        return granted
    }

    /// Previews disabled or app quitting: end the session and purge every cached snapshot.
    func stop() {
        legacyRequests = []; legacyThumbnailsVisible = false
        legacySelection = nil; legacySelectionVisible = false
        endSession()
        purge(reason: "stopped")
    }

    // MARK: Legacy adapter (DesktopController today)

    func selectVisibleThumbnails(_ requests: [WindowThumbnailRequest], visible: Bool, surviving: Set<WindowIdentity>) {
        windowsChanged(alive: surviving)
        for request in requests {
            identityIndex[LiveKey(windowNumber: request.windowNumber, pid: request.ownerPID)] = request.id
        }
        legacyRequests = visible ? requests : []
        legacyThumbnailsVisible = visible
        applyLegacy()
        guard visible else { return }
        // The legacy card layer clears thumbnails when it reassigns cards; republish cached images.
        for request in legacyRequests {
            if let entry = cache.peek(request.id), entry.windowNumber == request.windowNumber,
               isThumbnailCurrent?(request) != false {
                onThumbnail?(request, entry.payload)
            }
        }
    }

    func select(windowNumber: UInt32?, visible: Bool, ownerPID: pid_t? = nil) {
        legacySelection = visible ? windowNumber.map { LiveKey(windowNumber: $0, pid: ownerPID ?? 0) } : nil
        legacySelectionVisible = visible
        applyLegacy()
        if visible, windowNumber == nil { publishLegacy(nil, "Selected window unavailable for capture") }
    }

    private func applyLegacy() {
        // DesktopController reports both halves on open and dismiss; the session spans both.
        let visible = legacySelectionVisible && legacyThumbnailsVisible
        var cards = legacyRequests.map { PreviewCard(id: $0.id, windowNumber: $0.windowNumber, isMinimized: false) }
        var selected: WindowIdentity?
        if let key = legacySelection, let id = identityIndex[key] {
            selected = id
            if !cards.contains(where: { $0.id == id }) {
                cards.insert(PreviewCard(id: id, windowNumber: key.windowNumber, isMinimized: false), at: 0)
            }
        }
        apply(visible: visible, cards: cards, selected: selected, live: legacySelection)
    }

    private func legacyRequest(for id: WindowIdentity) -> WindowThumbnailRequest? {
        if let request = legacyRequests.first(where: { $0.id == id }) { return request }
        if let key = legacySelection, identityIndex[key] == id {
            return WindowThumbnailRequest(id: id, windowNumber: key.windowNumber, ownerPID: key.pid)
        }
        return nil
    }

    private func publishLegacy(_ image: CGImage?, _ label: String) {
        status = label
        onImage?(image, label)
    }

    // MARK: Session

    private func apply(visible: Bool, cards: [PreviewCard], selected: WindowIdentity?, live: LiveKey?) {
        guard visible else { endSession(); return }
        previewsRequested = true
        if !sessionVisible {
            sessionVisible = true
            sessionOpenedAt = ProcessInfo.processInfo.systemUptime
            emitted.removeAll(); unavailable.removeAll(); hiddenPIDs.removeAll(); failedThisSession.removeAll()
            scheduler.beginSession()
            applyPressure(Self.currentPressureLevel())
            if workPause == nil, sessionOpenedAt - contentAt > Self.contentMaxAgeOnOpen {
                // Refresh shareable content in parallel with the panel's first display.
                Task { _ = try? await refreshContent() }
            }
            RuntimeDiagnostics.mark("capture session=open cacheBytes=\(cache.totalBytes) cacheEntries=\(cache.count) pressure=\(pressure.level)")
        }
        sessionCards = cards
        sessionIDs = Set(cards.map(\.id))
        selectedID = selected
        sessionLiveKey = live
        for card in cards where !emitted.contains(card.id) {
            emitted.insert(card.id)
            emit(preview(for: card))
        }
        updateLive(live, id: selected)
        planSnapshots()
        pump()
    }

    private func endSession() {
        guard sessionVisible || desired != nil || gate.pending != nil || gate.committed != nil else { return }
        sessionVisible = false
        sessionCards = []; sessionIDs = []; selectedID = nil
        scheduler.endSession()
        updateLive(nil, id: nil)
        RuntimeDiagnostics.mark("capture session=closed liveStreams=\(liveStreamCount) outstandingSnapshots=\(scheduler.outstandingCount) cacheBytes=\(cache.totalBytes) cacheEntries=\(cache.count)")
    }

    /// Conditions that stop capture work entirely.
    private var workPause: PreviewPauseReason? {
        if !pressure.quality.snapshotsAllowed { return .memoryPressure }
        if sleeping { return .sleeping }
        if sessionInactive { return .sessionInactive }
        return nil
    }

    /// What cards show: a work pause, or the snapshot circuit breaker backing off.
    private var pauseReason: PreviewPauseReason? {
        workPause ?? (runner.isBackingOff ? .retrying : nil)
    }

    private func reason(for card: PreviewCard) -> PreviewUnavailableReason? {
        if !hasPermission { return .permissionRequired }
        var appHidden = false
        if card.windowNumber == nil, !card.isMinimized {
            // The registry withholds window numbers for hidden apps; ask once per PID per session.
            let pid = card.id.process.pid
            if let known = hiddenPIDs[pid] { appHidden = known }
            else {
                appHidden = NSRunningApplication(processIdentifier: pid)?.isHidden == true
                hiddenPIDs[pid] = appHidden
            }
        }
        if let fixed = PreviewAvailability.reason(isMinimized: card.isMinimized, appHidden: appHidden,
                                                  windowNumber: card.windowNumber, listedOnScreen: nil) {
            return fixed
        }
        return unavailable[card.id]
    }

    private func emit(_ update: PreviewUpdate) {
        onPreview?(update)
        // Legacy translation: thumbnails for non-selected cards, status text for the selected one.
        switch update.content {
        case .snapshot(let image):
            if let request = legacyRequest(for: update.id), isThumbnailCurrent?(request) != false {
                onThumbnail?(request, image)
            }
        case .live: break
        case .keep, .none:
            if let key = legacySelection, identityIndex[key] == update.id, !update.presentation.isLive {
                publishLegacy(nil, update.label())
            }
        }
    }

    private func emitState(_ id: WindowIdentity) {
        guard sessionVisible, let card = sessionCards.first(where: { $0.id == id }) else { return }
        emit(preview(for: card))
    }

    // MARK: Snapshots

    private var snapshotBox: CGSize {
        let scale = pressure.quality.pixelScale
        return CGSize(width: max(2, pixelBox.width * scale), height: max(2, pixelBox.height * scale))
    }

    private func planSnapshots() {
        guard sessionVisible, workPause == nil, pressure.quality.snapshotsAllowed, hasPermission else {
            scheduler.plan([], selectedIndex: nil); return
        }
        // Capture needs the window's SCWindow. Windows missing from content fetched in this session
        // are not on screen; others wait for the (deadline-bounded) discovery to finish.
        let age = ProcessInfo.processInfo.systemUptime - contentAt
        let freshThisSession = contentAt >= sessionOpenedAt
        var waiting = false
        let requests = sessionCards.compactMap { card -> SnapshotRequest? in
            guard !card.isMinimized, let number = card.windowNumber else { return nil }
            if content[number] != nil, age <= Self.contentReuseAge { return SnapshotRequest(id: card.id, windowNumber: number) }
            if freshThisSession {
                if unavailable[card.id] != .otherSpace { unavailable[card.id] = .otherSpace; emitState(card.id) }
            } else { waiting = true }
            return nil
        }
        if waiting, discovery == nil { Task { _ = try? await refreshContent() } }
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = Set(requests.filter { request in
            guard let entry = cache.peek(request.id) else { return false }
            return entry.windowNumber == request.windowNumber && now - entry.capturedAt < Self.snapshotFreshAge
        }.map(\.id))
        scheduler.plan(requests, selectedIndex: requests.firstIndex { $0.id == selectedID }, fresh: fresh)
    }

    private func pump() { runner.pump() }

    /// The snapshot backend: one bounded screenshot of a window already listed in shareable content.
    private func screenshot(_ request: SnapshotRequest) async throws -> CGImage {
        guard let window = content[request.windowNumber],
              window.owningApplication.map({ $0.processID == request.id.process.pid }) ?? true,
              window.isOnScreen, window.frame.width > 0, window.frame.height > 0 else { throw SnapshotFailure.notOnScreen }
        let box = snapshotBox
        let size = Self.fittedPixelSize(window.frame.size, box: box)
        let config = SCStreamConfiguration()
        config.width = size.width; config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false; config.capturesAudio = false; config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        let started = ProcessInfo.processInfo.systemUptime
        let source: CGImage
        do {
            source = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        } catch {
            throw Self.isPermissionError(error) ? SnapshotFailure.permissionDenied : SnapshotFailure.failed
        }
        RuntimeDiagnostics.mark("thumbnail screenshotMilliseconds=\((ProcessInfo.processInfo.systemUptime - started) * 1000) width=\(source.width) height=\(source.height)")
        guard let image = await Task.detached(priority: .utility, operation: { Self.detachedSnapshot(source, fitting: box) }).value
        else { throw SnapshotFailure.failed }
        return image
    }

    private func resolve(_ ticket: SnapshotTicket, _ completion: SnapshotCompletion, _ outcome: SnapshotOutcome<CGImage>) {
        RuntimeDiagnostics.mark("thumbnail state=\(completion) outstanding=\(scheduler.outstandingCount) abandoned=\(scheduler.abandonedCount) cacheBytes=\(cache.totalBytes) cacheEntries=\(cache.count)")
        switch (completion, outcome) {
        case (.store, .captured(let image)):
            store(image, id: ticket.id, windowNumber: ticket.request.windowNumber,
                  capturedAt: ProcessInfo.processInfo.systemUptime)
        case (.store, .failed(let failure)):
            switch failure {
            case .notOnScreen: unavailable[ticket.id] = .otherSpace
            case .permissionDenied: handlePermissionLoss(); unavailable[ticket.id] = .permissionRequired
            case .failed: unavailable[ticket.id] = .captureFailed; failedThisSession.insert(ticket.id)
            }
            emitState(ticket.id)
        case (.timedOut, _):
            unavailable[ticket.id] = .captureFailed
            failedThisSession.insert(ticket.id)
            emitState(ticket.id)
        default:
            break
        }
    }

    private func snapshotBreakerChanged(open: Bool) {
        RuntimeDiagnostics.mark("capture snapshotBreaker=\(open ? "open" : "retry") failures=\(runner.breaker.consecutiveFailures)")
        if !open, sessionVisible {
            // Backoff expired: retry the windows that failed or timed out in this session.
            scheduler.markForRetry(failedThisSession)
            for id in failedThisSession { unavailable[id] = nil }
            failedThisSession.removeAll()
            planSnapshots()
            pump()
        }
        if sessionVisible { for card in sessionCards { emitState(card.id) } }
    }

    private func store(_ image: CGImage, id: WindowIdentity, windowNumber: UInt32, capturedAt: Double) {
        guard pressure.quality.snapshotsAllowed,
              let bytes = ThumbnailCache<CGImage>.payloadBytes(bytesPerRow: image.bytesPerRow, height: image.height) else { return }
        guard case .stored(let evicted) = cache.insert(id: id, windowNumber: windowNumber, payload: image,
                                                       bytes: bytes, capturedAt: capturedAt) else { return }
        unavailable[id] = nil
        for gone in evicted where sessionIDs.contains(gone) { emitState(gone) }
        // A live card keeps showing live frames; the snapshot is its fallback for the next open.
        let isLiveCard = desired?.id == id && lastLiveFrame?.target.id == id && stream != nil
        if !isLiveCard { emitState(id) }
    }

    // MARK: Shareable content

    /// Uses the short-lived cache; a window missing from content fetched before this session
    /// opened triggers one fresh lookup, after which it counts as not on screen.
    private func shareableWindows(containing number: UInt32?) async throws -> [CGWindowID: SCWindow] {
        let age = ProcessInfo.processInfo.systemUptime - contentAt
        // A known window does not wait for the open-time refresh that runs in parallel.
        if let number, content[number] != nil, age <= Self.contentReuseAge { return content }
        if let discovery { return try await discovery.value }
        if age <= Self.contentMaxAge, number.map({ content[$0] != nil || contentAt >= sessionOpenedAt }) ?? true { return content }
        return try await refreshContent()
    }

    private struct DiscoveryTimeout: Error {}

    private func refreshContent() async throws -> [CGWindowID: SCWindow] {
        if let discovery { return try await discovery.value }
        guard abandonedDiscoveries < 2 else {
            // Two timed-out discoveries are still physically outstanding: do not add a third.
            runner.noteFailure()
            throw DiscoveryTimeout()
        }
        let task = Task { @MainActor [self] () throws -> [CGWindowID: SCWindow] in
            discoveryInFlight = true; transition("discovering")
            defer { discoveryInFlight = false }
            let started = ProcessInfo.processInfo.systemUptime
            let result = await Deadline.run(seconds: Self.discoveryTimeout, operation: {
                UncheckedSendable(try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
            }, late: { [weak self] late in
                Task { @MainActor in
                    guard let self else { return }
                    self.abandonedDiscoveries -= 1
                    RuntimeDiagnostics.mark("capture discovery=lateAfterTimeout")
                    // A slow (typically first-in-process) discovery still yields valid content.
                    if case .success(let boxed) = late, self.discovery == nil {
                        var windows: [CGWindowID: SCWindow] = [:]
                        for window in boxed.value.windows where windows[window.windowID] == nil { windows[window.windowID] = window }
                        self.content = windows; self.contentAt = ProcessInfo.processInfo.systemUptime
                        if self.sessionVisible { self.planSnapshots(); self.pump() }
                    }
                }
            })
            switch result {
            case .value(let boxed):
                let shareable = boxed.value
                RuntimeDiagnostics.mark("capture discoveryMilliseconds=\((ProcessInfo.processInfo.systemUptime - started) * 1000) windows=\(shareable.windows.count)")
                var windows: [CGWindowID: SCWindow] = [:]
                for window in shareable.windows where windows[window.windowID] == nil { windows[window.windowID] = window }
                content = windows; contentAt = ProcessInfo.processInfo.systemUptime
                setPermissionStatus(.resolve(preflight: CGPreflightScreenCaptureAccess(), contentProbe: true))
                transition("discoveryCompleted")
                return windows
            case .failure(let error):
                transition("discoveryFailed")
                if Self.isPermissionError(error) {
                    setPermissionStatus(.resolve(preflight: CGPreflightScreenCaptureAccess(), contentProbe: false))
                } else { runner.noteFailure() }
                throw error
            case .timedOut:
                abandonedDiscoveries += 1
                transition("discoveryTimedOut")
                runner.noteFailure()
                throw DiscoveryTimeout()
            }
        }
        discovery = task
        defer { discovery = nil }
        let windows = try await task.value
        // Requests that waited for discovery can be planned now.
        if sessionVisible { planSnapshots(); pump() }
        return windows
    }

    // MARK: Permission

    nonisolated private static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    private func setPermissionStatus(_ next: ScreenRecordingStatus) {
        guard next != screenRecordingStatus else { return }
        let wasGranted = screenRecordingStatus == .granted
        screenRecordingStatus = next
        RuntimeDiagnostics.mark("capture screenRecording=\(next)")
        if wasGranted, next != .granted { handlePermissionLoss() }
        if next == .granted, sessionVisible { resumeWork() }
        onScreenRecordingStatusChange?(next)
    }

    private func handlePermissionLoss() {
        purge(reason: "permissionRevoked")
        if sessionVisible { for card in sessionCards { emitState(card.id) } }
    }

    // MARK: Pressure, sleep, purge

    nonisolated static func currentPressureLevel() -> MemoryPressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressureLevel(kernelLevel: Int(value))
    }

    /// Driven by the memory-pressure source and re-synced from the kernel level on every open.
    /// Internal (not private) so Tools/CaptureBench can exercise the transitions.
    func applyPressure(_ level: MemoryPressureLevel) {
        let transition = pressure.apply(level)
        guard transition.qualityChanged else { return }
        RuntimeDiagnostics.mark("capture pressure=\(level) thumbnailByteLimit=\(pressure.quality.thumbnailByteLimit) liveFPS=\(pressure.quality.liveFramesPerSecond)")
        if transition.purge {
            purge(reason: "memoryCritical")
        } else {
            for gone in cache.setByteLimit(pressure.quality.thumbnailByteLimit) where sessionIDs.contains(gone) { emitState(gone) }
            updateLiveFrameRate()
        }
        if transition.resume { resumeWork() }
        if sessionVisible { for card in sessionCards { emitState(card.id) } }
    }

    /// Stops live and queued work without purging (sleep, inactive session).
    private func pauseWork() {
        convertLastLiveFrame()
        scheduler.endSession()
        gateTask?.cancel(); gate.reset()
        stopLive()
        if sessionVisible { for card in sessionCards { emitState(card.id) } }
    }

    /// Resumes refresh and live work for a visible surface once nothing pauses it.
    private func resumeWork() {
        guard sessionVisible, workPause == nil else { return }
        scheduler.beginSession()
        gate.reset()
        updateLive(sessionLiveKey, id: selectedID)
        planSnapshots()
        pump()
    }

    /// Privacy or memory purge: stop live, drop queued work, discard in-flight results, empty the cache.
    func purge(reason: String) {
        lastLiveFrame = nil
        gateTask?.cancel(); gate.reset()
        stopLive()
        scheduler.purge()
        if sessionVisible { scheduler.beginSession() }
        let hadEntries = cache.count > 0
        cache.removeAll()
        content.removeAll(); contentAt = -.infinity
        unavailable.removeAll()
        onThumbnailsCleared?()
        if hadEntries || sessionVisible {
            RuntimeDiagnostics.mark("thumbnail state=purged reason=\(reason) outstanding=\(scheduler.outstandingCount) cacheBytes=0 cacheEntries=0")
        }
    }

    // MARK: Live stream

    private func updateLive(_ key: LiveKey?, id: WindowIdentity?) {
        let now = ProcessInfo.processInfo.systemUptime
        let breakerAllows = liveBreaker.allows(now: now)
        if !breakerAllows, key != nil, sessionVisible { scheduleLiveRetry() }
        let allowed = sessionVisible && workPause == nil && pressure.quality.liveAllowed && hasPermission && breakerAllows
        let decision = gate.update(allowed ? key : nil, now: now)
        if decision.stopLive || (key == nil && desired != nil) || (desired.map { $0.key != key } ?? false) {
            convertLastLiveFrame()
            stopLive()
        }
        if let id, desired?.id == nil, desired?.key == key { desired?.id = id }
        if let fireAt = decision.fireAt {
            gateTask?.cancel()
            liveRequestedAt = liveRequestedAt ?? now
            gateTask = Task { @MainActor [weak self] in
                let delay = fireAt - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, let self else { return }
                if let key = self.gate.fire(now: ProcessInfo.processInfo.systemUptime) { self.startLive(key) }
            }
        } else if key == nil || !allowed {
            gateTask?.cancel(); gateTask = nil
        }
    }

    /// After a live-start failure backoff, retry the current selection if the surface is still up.
    private func scheduleLiveRetry() {
        guard liveRetryTask == nil, let retryAt = liveBreaker.retryAt else { return }
        liveRetryTask = Task { @MainActor [weak self] in
            let delay = retryAt - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.liveRetryTask = nil
            guard self.sessionVisible else { return }
            self.gate.reset()
            self.updateLive(self.sessionLiveKey, id: self.selectedID)
        }
    }

    /// No first frame in time, or start failed: tear down, fall back to the snapshot, back off.
    private func liveStartFailed(token: UInt64, target: LiveTarget, reason: String) {
        guard generation == token, desired?.key == target.key else { return }
        transition(reason)
        liveBreaker.recordFailure(now: ProcessInfo.processInfo.systemUptime)
        output?.deactivate()
        desired = nil
        gate.reset()
        generation &+= 1
        schedule()
        if let id = target.id { emitState(id) }
        publishLegacy(nil, "Selected preview unavailable; showing snapshot")
        if sessionVisible, liveBreaker.retryAt != nil { scheduleLiveRetry() }
    }

    private func startLive(_ key: LiveKey) {
        guard sessionVisible else { return }
        let id = sessionCards.first { card in card.windowNumber == key.windowNumber && card.id.process.pid == key.pid }?.id
            ?? identityIndex[key]
        let fps = max(1, pressure.quality.liveFramesPerSecond)
        // Warning pressure lowers the live frame rate but keeps the selected card sharp.
        desired = LiveTarget(key: key, id: id, pixelBox: pixelBox, framesPerSecond: fps)
        generation &+= 1
        schedule()
    }

    private func stopLive() {
        output?.deactivate()
        lastLiveFrame = nil
        liveRequestedAt = nil
        guard desired != nil || stream != nil else { return }
        desired = nil
        generation &+= 1
        if stream == nil, !discoveryInFlight { transition("hidden") }
        schedule()
    }

    /// Keeps the last live frame of the outgoing selection as that card's cached snapshot.
    private func convertLastLiveFrame() {
        guard let last = lastLiveFrame else { return }
        lastLiveFrame = nil
        let key = last.target.key
        let epoch = scheduler.epoch
        let box = snapshotBox
        if let id = last.target.id ?? identityIndex[key], sessionIDs.contains(id) {
            emit(PreviewUpdate(id: id, content: .keep,
                               presentation: .snapshot(capturedAt: last.frame.arrivedAt, note: nil)))
        }
        let frame = last.frame
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.detachedSnapshot(from: frame, fitting: box) }.value
            guard let self, let image, self.scheduler.epoch == epoch,
                  let id = last.target.id ?? self.identityIndex[key] else { return }
            self.store(image, id: id, windowNumber: key.windowNumber, capturedAt: frame.arrivedAt)
        }
    }

    private func updateLiveFrameRate() {
        let fps = max(1, pressure.quality.liveFramesPerSecond)
        guard let stream, streamGeneration == generation, var target = desired, fps != streamFramesPerSecond else { return }
        target = LiveTarget(key: target.key, id: target.id, pixelBox: target.pixelBox, framesPerSecond: fps)
        desired = target
        streamFramesPerSecond = fps
        let configuration = Self.streamConfiguration(size: streamPixelSize, framesPerSecond: fps)
        stream.updateConfiguration(configuration) { _ in }
    }

    private func transition(_ state: String) {
        guard diagnosticState != state else { return }
        diagnosticState = state
        RuntimeDiagnostics.mark("capture state=\(state) admittedPhysicalStreams=\(stream == nil ? 0 : 1) discoveryInFlight=\(discoveryInFlight ? 1 : 0)")
    }

    private func schedule() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.reconcile()
            self.worker = nil
        }
    }

    private func reconcile() async {
        while true {
            if let stream {
                if streamGeneration == generation { return }
                guard !stopUnconfirmed else { return }
                output?.deactivate()
                transition("stopping")
                do {
                    try await stream.stopCapture()
                    // Completion, rather than a timeout, releases the physical stream slot.
                    detach(stream)
                } catch {
                    // A thrown stop does not prove teardown. Keep ownership until delegate confirmation.
                    if self.stream === stream {
                        stopUnconfirmed = true
                        transition("teardownUnconfirmed")
                        publishLegacy(nil, "Preview teardown unconfirmed; further capture paused")
                        return
                    }
                }
                continue
            }
            guard let target = desired else { return }
            let token = generation
            guard hasPermission else {
                transition("permissionUnavailable")
                if let id = target.id { emitState(id) }
                publishLegacy(nil, "Screen Recording permission required for previews")
                return
            }
            let windows: [CGWindowID: SCWindow]
            do {
                windows = try await shareableWindows(containing: target.key.windowNumber)
            } catch {
                guard generation == token else { continue }
                if Self.isPermissionError(error) { handlePermissionLoss() }
                publishLegacy(nil, "Selected preview unavailable")
                return
            }
            guard generation == token, desired == target else { continue }
            guard let window = windows[target.key.windowNumber],
                  target.key.pid == 0 || window.owningApplication?.processID == target.key.pid,
                  window.isOnScreen, window.frame.width > 0, window.frame.height > 0 else {
                transition("selectedUnavailable")
                if let id = target.id { unavailable[id] = .otherSpace; emitState(id) }
                publishLegacy(nil, "Selected window unavailable for capture")
                return
            }
            streamPixelSize = Self.fittedPixelSize(window.frame.size, box: target.pixelBox)
            let configuration = Self.streamConfiguration(size: streamPixelSize, framesPerSecond: target.framesPerSecond)
            let output = CaptureOutput(budget: frameBudget, onFrame: { [weak self] frame in
                guard let self, self.generation == token, let target = self.desired else { return }
                self.deliverLive(frame, target: target)
            }, onStop: { [weak self] error in
                guard let self, self.streamGeneration == token else { return }
                if let stream = self.stream { self.detach(stream) }
                self.stopUnconfirmed = false
                if let error, Self.isPermissionError(error) { self.handlePermissionLoss() }
                if self.generation == token {
                    self.convertLastLiveFrame()
                    self.desired = nil
                    self.gate.reset()
                    if let id = target.id { self.emitState(id) }
                    self.publishLegacy(nil, "Selected preview stopped or unavailable")
                } else { self.schedule() }
            })
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                  configuration: configuration, delegate: output)
            self.output = output; self.stream = stream; streamGeneration = token
            streamFramesPerSecond = target.framesPerSecond
            transition("starting")
            liveFirstFrameSeen = false
            liveWatchdog?.cancel()
            liveWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.liveFirstFrameTimeout))
                guard !Task.isCancelled, let self, self.streamGeneration == token, !self.liveFirstFrameSeen else { return }
                self.liveStartFailed(token: token, target: target, reason: "liveFirstFrameTimeout")
            }
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
                try await stream.startCapture()
                if self.stream === stream { transition("live") }
            } catch {
                // A completed failed start does not reserve another live stream.
                output.deactivate()
                if self.stream === stream { detach(stream, reason: "startFailed") }
                liveWatchdog?.cancel()
                if generation == token {
                    if Self.isPermissionError(error) { handlePermissionLoss() }
                    else { liveStartFailed(token: token, target: target, reason: "liveStartFailed") }
                    return
                }
            }
            // If the selection changed during start, the next iteration awaits stop before replacement.
        }
    }

    private func deliverLive(_ frame: LiveFrame, target: LiveTarget) {
        if !liveFirstFrameSeen {
            liveFirstFrameSeen = true
            liveWatchdog?.cancel(); liveWatchdog = nil
            liveBreaker.recordSuccess()
        }
        if lastLiveFrame == nil, let requested = liveRequestedAt {
            RuntimeDiagnostics.mark("capture firstLiveFrameMilliseconds=\((frame.arrivedAt - requested) * 1000) width=\(frame.width) height=\(frame.height)")
        }
        lastLiveFrame = (frame, target)
        if let id = target.id, sessionIDs.contains(id) {
            onPreview?(PreviewUpdate(id: id, content: .live(frame), presentation: .live))
        }
        if let onImage, legacySelection == target.key, let image = Self.legacyImage(from: frame) {
            status = "Live selected preview"
            onImage(image, status)
        }
    }

    private func detach(_ stopped: SCStream, reason: String = "confirmedStop") {
        output?.deactivate()
        if let output {
            try? stopped.removeStreamOutput(output, type: .screen)
            output.reportCounters()
        }
        if stream === stopped {
            stream = nil; output = nil; streamGeneration = nil; streamFramesPerSecond = 0
            liveWatchdog?.cancel(); liveWatchdog = nil
            transition(reason)
        }
    }

    // MARK: Pixel helpers (nonisolated, shared with the ownership check)

    /// Aspect-fits a window (points, assumed up to 2× backing) into a pixel box without upscaling.
    nonisolated static func fittedPixelSize(_ points: CGSize, box: CGSize) -> (width: Int, height: Int) {
        guard points.width > 0, points.height > 0 else { return (2, 2) }
        let native = CGSize(width: points.width * 2, height: points.height * 2)
        let scale = min(1, box.width / native.width, box.height / native.height)
        return (max(2, Int((native.width * scale).rounded())), max(2, Int((native.height * scale).rounded())))
    }

    nonisolated private static func streamConfiguration(size: (width: Int, height: Int), framesPerSecond: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, size.width)
        configuration.height = max(2, size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        return configuration
    }

    /// An owned raster copy, aspect-fitted into `box` (never upscaled). Holds no framework surface.
    nonisolated static func detachedSnapshot(_ source: CGImage, fitting box: CGSize) -> CGImage? {
        guard source.width > 0, source.height > 0, box.width >= 1, box.height >= 1 else { return nil }
        let scale = min(1, box.width / CGFloat(source.width), box.height / CGFloat(source.height))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Converts a live frame to an owned snapshot; the frame's surface is not retained afterwards.
    nonisolated static func detachedSnapshot(from frame: LiveFrame, fitting box: CGSize) -> CGImage? {
        guard let image = legacyImage(from: frame) else { return nil }
        return detachedSnapshot(image, fitting: box)
    }

    /// Legacy CGImage view of a live frame (no copy at creation). The image's data provider holds the
    /// frame and its read lock until the last consumer releases it.
    nonisolated static func legacyImage(from frame: LiveFrame) -> CGImage? {
        let buffer = frame.pixelBuffer
        if PreviewRenderer.usesReferenceRenderer {
            let source = CIImage(cvPixelBuffer: buffer)
            return CIContext(options: [.cacheIntermediates: false]).createCGImage(source, from: source.extent)
        }
        guard let lock = FrameReadLock(frame: frame), let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let size = ThumbnailCache<CGImage>.payloadBytes(bytesPerRow: rowBytes, height: height) else { return nil }
        let retained = Unmanaged.passRetained(lock)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: address, size: size, releaseData: { info, _, _ in
            if let info { Unmanaged<FrameReadLock>.fromOpaque(info).release() }
        }) else { retained.release(); return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: frame.width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Caps live frames held anywhere in the process (pending delivery or displayed by a card).
/// Only frame deinit releases a slot; no timeout does.
final class LiveFrameBudget: @unchecked Sendable {
    static let limit = 3
    private let lock = NSLock()
    private var count = 0
    private var peak = 0
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < Self.limit else { return false }
        count += 1; peak = max(peak, count)
        return true
    }
    func release() { lock.lock(); count -= 1; lock.unlock() }
    var counts: (current: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }; return (count, peak)
    }
}

/// Keeps a frame and its CPU read lock alive for a provider-backed CGImage.
private final class FrameReadLock {
    let frame: LiveFrame
    init?(frame: LiveFrame) {
        guard CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        self.frame = frame
    }
    deinit { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
}

/// Validates frames on the stream queue and keeps a one-frame mailbox: slow UI delivery never queues.
final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maximumDimension = 2048

    private let lock = NSLock()
    private var active = true
    private var pending: LiveFrame?
    private var deliveryScheduled = false
    private let budget: LiveFrameBudget
    private var received: UInt64 = 0
    private var delivered: UInt64 = 0
    private var capacityDropped: UInt64 = 0
    private let onFrame: @MainActor @Sendable (LiveFrame) -> Void
    private let onStop: @MainActor @Sendable ((any Error)?) -> Void

    init(budget: LiveFrameBudget, onFrame: @escaping @MainActor @Sendable (LiveFrame) -> Void,
         onStop: @escaping @MainActor @Sendable ((any Error)?) -> Void) {
        self.budget = budget; self.onFrame = onFrame; self.onStop = onStop
    }

    var counters: (received: UInt64, delivered: UInt64, capacityDropped: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (received, delivered, capacityDropped)
    }

    func reportCounters() {
        let values = counters
        let frames = budget.counts
        RuntimeDiagnostics.mark("capture renderer=\(PreviewRenderer.usesReferenceRenderer ? "reference" : "iosurface") framesReceived=\(values.received) framesDelivered=\(values.delivered) capacityDropped=\(values.capacityDropped) retainedLiveFrames=\(frames.current) peakLiveFrames=\(frames.peak)")
    }

    /// Stops delivery at once and releases the undelivered frame.
    func deactivate() {
        lock.lock(); active = false; let dropped = pending; pending = nil; lock.unlock()
        _ = dropped
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        deactivate()
        Task { @MainActor [onStop] in onStop(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        ingest(buffer)
    }

    /// Shared by stream delivery and the synthetic ownership check.
    func ingest(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard active else { lock.unlock(); return }
        received &+= 1
        // Release an undelivered frame before admitting its replacement, preserving the frame cap.
        let replaced = pending
        pending = nil
        lock.unlock()
        _ = replaced
        guard CVPixelBufferGetWidth(buffer) <= Self.maximumDimension, CVPixelBufferGetHeight(buffer) <= Self.maximumDimension,
              let frame = LiveFrame(buffer: buffer, budget: budget, arrivedAt: ProcessInfo.processInfo.systemUptime) else {
            lock.lock(); capacityDropped &+= 1; lock.unlock(); return
        }
        lock.lock()
        guard active else { lock.unlock(); return }
        pending = frame
        let needsDelivery = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if needsDelivery {
            DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
        }
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        let frame = active ? pending : nil
        pending = nil; deliveryScheduled = false
        if frame != nil { delivered &+= 1 }
        lock.unlock()
        if let frame { onFrame(frame) }
    }
}

/// Carries a non-Sendable framework result across the deadline race; only touched on the main actor.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
