import AppKit
import PanefloCore
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Developer-only A/B renderer selection; cadence, dimensions and capture configuration stay identical.
enum PreviewRenderer {
    static let usesReferenceRenderer = CommandLine.arguments.contains("--preview-reference-renderer")
}

struct WindowThumbnailRequest: Hashable, Sendable {
    let id: WindowIdentity
    let windowNumber: UInt32
    let ownerPID: pid_t
}

/// One selected live stream and one serial screenshot worker share a content broker.
/// Neither worker logically releases outstanding framework calls before actual completion.
@MainActor
final class CaptureController {
    var onImage: ((CGImage?, String) -> Void)?
    var onThumbnail: ((WindowThumbnailRequest, CGImage) -> Void)?
    var onThumbnailsCleared: (() -> Void)?
    var isThumbnailCurrent: ((WindowThumbnailRequest) -> Bool)?
    private var thumbnailAdmission = ThumbnailAdmission()
    private var thumbnailPayloads: [WindowIdentity: CGImage] = [:]
    private var thumbnailRequests: [WindowThumbnailRequest] = []
    private var thumbnailAttempted: Set<WindowIdentity> = []
    private var thumbnailVisible = false
    private var thumbnailForcedRefresh: UInt64?
    private var thumbnailWorker: Task<Void, Never>?
    private var contentDiscovery: Task<[SCWindow], Error>?

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    private(set) var status = "Previews off"
    private struct Selection: Equatable {
        var windowNumber: UInt32
        var ownerPID: pid_t?
    }
    private var desired: Selection?
    private var pausedSelection: Selection?
    private var pressureActive = false
    private var sleeping = false
    private var sessionInactive = false
    private var pauseLabel: String?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memoryPressureSource = pressure
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.memoryPressureSource else { return }
                let event = source.data
                if event.contains(.warning) || event.contains(.critical) {
                    self.pressureActive = true
                    self.pause("Previews paused for memory pressure; reselect after pressure clears")
                } else if event.contains(.normal) {
                    self.pressureActive = false
                }
            }
        }
        pressure.resume()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification {
                        self.sleeping = true
                        self.pause("Previews paused for sleep; reopen or reselect after waking")
                    } else if name == NSWorkspace.sessionDidResignActiveNotification {
                        self.sessionInactive = true
                        self.pause("Previews paused while session inactive; reopen or reselect to resume")
                    } else if name == NSWorkspace.didWakeNotification {
                        self.sleeping = false
                    } else { self.sessionInactive = false }
                }
            })
        }
    }

    private func pause(_ label: String) {
        if let desired { pausedSelection = desired }
        desired = nil; generation &+= 1
        invalidateThumbnails(purge: true)
        pauseLabel = label
        output?.deactivate()
        cachedWindows.removeAll(); cacheDate = .distantPast
        publish(nil, label)
        transition("paused")
        schedule()
    }
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var streamGeneration: UInt64?
    private var stopUnconfirmed = false
    private var cachedWindows: [SCWindow] = []
    private var cacheDate = Date.distantPast
    private var forcedRefreshGeneration: UInt64?
    private var nextDiscoveryUptime: TimeInterval = 0
    private var discoveryInFlight = false
    private var diagnosticState = "idle"

    private func transition(_ state: String) {
        guard diagnosticState != state else { return }
        diagnosticState = state
        RuntimeDiagnostics.mark("capture state=\(state) admittedPhysicalStreams=\(stream == nil ? 0 : 1) discoveryInFlight=\(discoveryInFlight ? 1 : 0)")
    }

    /// Both stream and screenshot workers join one physical discovery, including its cooldown.
    private func shareableWindows() async throws -> [SCWindow] {
        if let contentDiscovery { return try await contentDiscovery.value }
        let task = Task { @MainActor [self] () throws -> [SCWindow] in
            let delay = nextDiscoveryUptime - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            guard (desired != nil || thumbnailVisible), hasPermission,
                  !pressureActive, !sleeping, !sessionInactive, !stopUnconfirmed else { throw CancellationError() }
            nextDiscoveryUptime = ProcessInfo.processInfo.systemUptime + 0.25
            discoveryInFlight = true; transition("discovering")
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                discoveryInFlight = false
                transition("discoveryCompleted")
                guard (desired != nil || thumbnailVisible), hasPermission,
                      !pressureActive, !sleeping, !sessionInactive, !stopUnconfirmed else { throw CancellationError() }
                cachedWindows = content.windows; cacheDate = Date()
                return content.windows
            } catch {
                discoveryInFlight = false
                if error is CancellationError { transition("discoveryCancelled") }
                else {
                    nextDiscoveryUptime = ProcessInfo.processInfo.systemUptime + 1
                    transition("discoveryFailed")
                }
                throw error
            }
        }
        contentDiscovery = task
        defer { contentDiscovery = nil }
        return try await task.value
    }

    private func discover(generation token: UInt64) async throws -> [SCWindow]? {
        let windows = try await shareableWindows()
        return generation == token && desired != nil ? windows : nil
    }

    private func invalidateThumbnails(purge: Bool) {
        let hadPayloads = thumbnailVisible || !thumbnailPayloads.isEmpty
        thumbnailAdmission.invalidate(purge: purge)
        thumbnailAttempted.removeAll()
        if purge {
            thumbnailVisible = false; thumbnailRequests.removeAll(); thumbnailPayloads.removeAll()
            onThumbnailsCleared?()
            if hadPayloads {
                RuntimeDiagnostics.mark("thumbnail state=purged physicalRequests=\(thumbnailAdmission.outstanding == nil ? 0 : 1) cacheBytes=0 cacheEntries=0")
            }
        }
    }

    func selectVisibleThumbnails(_ requests: [WindowThumbnailRequest], visible: Bool,
                                 surviving: Set<WindowIdentity>) {
        thumbnailAdmission.retainOnly(surviving)
        pruneThumbnailPayloads()
        guard visible, hasPermission, !pressureActive, !sleeping, !sessionInactive, !stopUnconfirmed,
              pauseLabel == nil else { invalidateThumbnails(purge: true); return }
        var unique: Set<WindowIdentity> = []
        let bounded = Array(requests.filter { unique.insert($0.id).inserted }.prefix(12))
        if !thumbnailVisible || Set(thumbnailRequests) != Set(bounded) {
            invalidateThumbnails(purge: false)
        }
        thumbnailRequests = bounded; thumbnailVisible = true
        for request in bounded {
            if thumbnailAdmission.contains(request.id, now: ProcessInfo.processInfo.systemUptime),
               let image = thumbnailPayloads[request.id], isThumbnailCurrent?(request) == true {
                onThumbnail?(request, image)
            }
        }
        pruneThumbnailPayloads()
        scheduleThumbnails()
    }

    private func pruneThumbnailPayloads() {
        let retained = thumbnailAdmission.identities
        if thumbnailPayloads.keys.contains(where: { !retained.contains($0) }) {
            thumbnailPayloads = thumbnailPayloads.filter { retained.contains($0.key) }
            // Consumers must release evicted images too; republish only currently admitted payloads.
            onThumbnailsCleared?()
            for request in thumbnailRequests {
                if let image = thumbnailPayloads[request.id], isThumbnailCurrent?(request) == true { onThumbnail?(request, image) }
            }
        }
    }

    private func scheduleThumbnails() {
        guard thumbnailWorker == nil else { return }
        thumbnailWorker = Task { [weak self] in
            guard let self else { return }
            // First presentation prioritizes starting the selected live stream.
            if let worker = self.worker { await worker.value }
            await self.captureThumbnails()
            self.thumbnailWorker = nil
        }
    }

    private func captureThumbnails() async {
        while thumbnailVisible && hasPermission && !pressureActive && !sleeping && !sessionInactive && !stopUnconfirmed {
            guard let request = thumbnailRequests.first(where: {
                !thumbnailAttempted.contains($0.id) && thumbnailPayloads[$0.id] == nil
            }) else { return }
            thumbnailAttempted.insert(request.id)
            let epoch = thumbnailAdmission.generation
            let windows: [SCWindow]
            do {
                windows = Date().timeIntervalSince(cacheDate) < 2 ? cachedWindows : try await shareableWindows()
            } catch { return }
            guard epoch == thumbnailAdmission.generation else { continue }
            let match = windows.first { $0.windowID == request.windowNumber && $0.owningApplication?.processID == request.ownerPID }
            if match == nil, Date().timeIntervalSince(cacheDate) < 2, thumbnailForcedRefresh != epoch {
                thumbnailForcedRefresh = epoch; cacheDate = .distantPast
                thumbnailAttempted.remove(request.id)
                continue
            }
            guard thumbnailRequests.contains(request), isThumbnailCurrent?(request) == true,
                  let window = match,
                  window.isOnScreen, window.frame.width > 0, window.frame.height > 0,
                  let ticket = thumbnailAdmission.begin(request.id) else { continue }
            let config = SCStreamConfiguration()
            let scale = min(1, 400 / window.frame.width, 250 / window.frame.height)
            config.width = max(2, Int(window.frame.width * scale)); config.height = max(2, Int(window.frame.height * scale))
            config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false; config.capturesAudio = false; config.scalesToFit = true
            config.ignoreShadowsSingleWindow = true
            RuntimeDiagnostics.mark("thumbnail state=requesting physicalRequests=1 cacheBytes=\(thumbnailAdmission.retainedBytes)")
            var detached: CGImage?
            var sourceDimensions = (width: 0, height: 0)
            do {
                let source = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                sourceDimensions = (source.width, source.height)
                if ticket.generation == thumbnailAdmission.generation, thumbnailVisible, !stopUnconfirmed,
                   thumbnailRequests.contains(request), hasPermission, isThumbnailCurrent?(request) == true {
                    detached = await Task.detached(priority: .utility) { Self.detachedThumbnail(source) }.value
                }
            } catch { /* A completed failed request frees its one physical slot, never a timeout. */ }
            let valid = thumbnailVisible && hasPermission && !stopUnconfirmed && thumbnailRequests.contains(request) && isThumbnailCurrent?(request) == true
            let accepted = thumbnailAdmission.complete(ticket, rowBytes: valid ? detached?.bytesPerRow : nil,
                                                       height: valid ? detached?.height : nil,
                                                       now: ProcessInfo.processInfo.systemUptime)
            if accepted, let detached { thumbnailPayloads[request.id] = detached }
            pruneThumbnailPayloads()
            if accepted, let detached { onThumbnail?(request, detached) }
            RuntimeDiagnostics.mark("thumbnail state=completed physicalRequests=0 sourceWidth=\(sourceDimensions.width) sourceHeight=\(sourceDimensions.height) cachedWidth=\(accepted ? detached?.width ?? 0 : 0) cachedHeight=\(accepted ? detached?.height ?? 0 : 0) cacheBytes=\(thumbnailAdmission.retainedBytes) cacheEntries=\(thumbnailAdmission.identities.count)")
        }
        if !hasPermission { invalidateThumbnails(purge: true) }
    }

    /// A raster copy detaches screenshot/provider storage; this never caches live stream leases.
    nonisolated fileprivate static func detachedThumbnail(_ source: CGImage) -> CGImage? {
        guard source.width > 0, source.height > 0, source.width <= 400, source.height <= 250,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()
    }

    private let bufferBudget = CaptureBufferBudget()
    private let frameQueue = DispatchQueue(label: "Paneflo.selected-preview", qos: .userInitiated)

    isolated deinit {
        memoryPressureSource?.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        output?.deactivate()
        if let stream {
            // Keep the framework objects alive until physical stop completion, even on owner release.
            let retainedOutput = output
            stream.stopCapture { _ in
                withExtendedLifetime((stream, retainedOutput)) {}
            }
        }
    }

    /// Call only from an explicit permission button.
    @discardableResult
    func requestPermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if granted, !pressureActive, !sleeping, !sessionInactive {
            pausedSelection = nil; pauseLabel = nil
        }
        if granted, desired != nil, stream == nil {
            generation &+= 1
            schedule()
        }
        return granted
    }

    func select(windowNumber: UInt32?, visible: Bool, ownerPID: pid_t? = nil) {
        let next = visible ? windowNumber.map { Selection(windowNumber: $0, ownerPID: ownerPID) } : nil
        if !visible { pausedSelection = nil }
        if let next {
            guard !pressureActive, !sleeping, !sessionInactive,
                  pausedSelection != next else {
                publish(nil, pauseLabel ?? "Previews paused; reopen or reselect to resume")
                return
            }
            pauseLabel = nil; pausedSelection = nil
        }
        guard desired != next else { return }
        desired = next; generation &+= 1
        invalidateThumbnails(purge: !visible)
        output?.deactivate()
        publish(nil, next == nil ? "Previews off" : "Preparing selected preview")
        if next == nil {
            cachedWindows.removeAll(); cacheDate = .distantPast
            if stream == nil, !discoveryInFlight { transition("hidden") }
        }
        schedule()
    }

    func stop() {
        pauseLabel = nil
        invalidateThumbnails(purge: true)
        select(windowNumber: nil, visible: false)
    }

    private func publish(_ image: CGImage?, _ label: String) {
        status = label; onImage?(image, label)
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
                        invalidateThumbnails(purge: true)
                        transition("teardownUnconfirmed")
                        publish(nil, "Preview teardown unconfirmed; further capture paused")
                        return
                    }
                }
                continue
            }
            guard let selected = desired else { return }
            let token = generation
            guard hasPermission else {
                transition("permissionUnavailable")
                publish(nil, "Screen Recording permission required for previews")
                return
            }
            let windows: [SCWindow]
            let usedCache = Date().timeIntervalSince(cacheDate) < 2
            do {
                if usedCache {
                    windows = cachedWindows
                } else {
                    guard let discovered = try await discover(generation: token) else { continue }
                    windows = discovered
                }
            } catch {
                guard generation == token else { continue }
                publish(nil, "Selected preview unavailable")
                return
            }
            guard generation == token, desired == selected else { continue }
            guard let window = windows.first(where: {
                $0.windowID == selected.windowNumber &&
                (selected.ownerPID == nil || $0.owningApplication?.processID == selected.ownerPID)
            }), window.isOnScreen, window.frame.width > 0, window.frame.height > 0 else {
                if usedCache, forcedRefreshGeneration != token {
                    // A newly created/unminimized selected window may not exist in the short cache.
                    // Admit one fresh lookup for this generation, never a repeating retry loop.
                    forcedRefreshGeneration = token
                    cacheDate = .distantPast
                    continue
                }
                transition("selectedUnavailable")
                publish(nil, "Selected window unavailable for capture")
                return
            }
            let configuration = SCStreamConfiguration()
            let scale = min(1, 960 / window.frame.width, 600 / window.frame.height)
            configuration.width = max(2, Int(window.frame.width * scale))
            configuration.height = max(2, Int(window.frame.height * scale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.scalesToFit = true
            let output = CaptureOutput(budget: bufferBudget, onImage: { [weak self] image in
                guard let self, self.generation == token, self.desired != nil else { return }
                self.publish(image, "Live selected preview")
            }, onStop: { [weak self] in
                guard let self, self.streamGeneration == token else { return }
                if let stream = self.stream { self.detach(stream) }
                self.stopUnconfirmed = false
                if !self.hasPermission { self.invalidateThumbnails(purge: true) }
                if self.generation == token {
                    self.desired = nil
                    self.publish(nil, "Selected preview stopped or unavailable")
                } else { self.schedule() }
            })
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                  configuration: configuration, delegate: output)
            self.output = output; self.stream = stream; streamGeneration = token
            transition("starting")
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
                try await stream.startCapture()
                if self.stream === stream { transition("live") }
            } catch {
                // A completed failed start does not reserve another live stream.
                output.deactivate()
                if self.stream === stream { detach(stream, reason: "startFailed") }
                if generation == token {
                    publish(nil, "Selected preview could not start")
                    return
                }
            }
            // If the selection changed during start, the next iteration awaits stop before replacement.
        }
    }

    private func detach(_ stopped: SCStream, reason: String = "confirmedStop") {
        output?.deactivate()
        if let output {
            try? stopped.removeStreamOutput(output, type: .screen)
            output.reportCounters()
        }
        if stream === stopped {
            stream = nil; output = nil; streamGeneration = nil
            transition(reason)
        }
    }
}

/// At most two retained pixel buffers across all capture generations. The framework's
/// own stream queue is separate; no timeout can release an outstanding provider lease.
private final class CaptureBufferBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var peak = 0
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < 2 else { return false }
        count += 1; peak = max(peak, count)
        return true
    }
    func release() { lock.lock(); count -= 1; lock.unlock() }
    var counts: (current: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }; return (count, peak)
    }
}

/// Provider ownership keeps both the pixel buffer and its read lock alive until the last
/// CGImage/data-provider consumer actually releases it, including a deferred draw.
private final class CaptureBufferLease {
    let buffer: CVPixelBuffer
    let budget: CaptureBufferBudget
    init?(buffer: CVPixelBuffer, budget: CaptureBufferBudget) {
        guard budget.acquire() else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            budget.release(); return nil
        }
        self.buffer = buffer; self.budget = budget
    }
    deinit {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        budget.release()
    }
}

/// Serial image wrapping plus a one-image mailbox: slow UI delivery never queues payloads.
private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // A per-payload ownership limit, not a bound on framework surfaces or total process RAM.
    private static let maximumImageBytes = 4 * 1024 * 1024
    private static func admitsPayload(rowBytes: Int, height: Int) -> Bool {
        guard rowBytes > 0, height > 0 else { return false }
        let bytes = rowBytes.multipliedReportingOverflow(by: height)
        return !bytes.overflow && bytes.partialValue <= maximumImageBytes
    }

    private let lock = NSLock()
    private var active = true
    private var pending: CGImage?
    private var deliveryScheduled = false
    private let budget: CaptureBufferBudget
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let referenceContext: CIContext? = PreviewRenderer.usesReferenceRenderer
        ? CIContext(options: [.cacheIntermediates: false]) : nil
    private var received: UInt64 = 0
    private var delivered: UInt64 = 0
    private var capacityDropped: UInt64 = 0
    private var firstPresentationSeconds: Double?
    private var lastPresentationSeconds: Double?
    private let onImage: @MainActor @Sendable (CGImage) -> Void
    private let onStop: @MainActor @Sendable () -> Void

    init(budget: CaptureBufferBudget, onImage: @escaping @MainActor @Sendable (CGImage) -> Void,
         onStop: @escaping @MainActor @Sendable () -> Void) {
        self.budget = budget; self.onImage = onImage; self.onStop = onStop
    }

    func reportCounters() {
        lock.lock()
        let values = (received, delivered, capacityDropped)
        let span = (lastPresentationSeconds ?? 0) - (firstPresentationSeconds ?? 0)
        lock.unlock()
        let leases = budget.counts
        RuntimeDiagnostics.mark("capture renderer=\(PreviewRenderer.usesReferenceRenderer ? "reference" : "provider") framesReceived=\(values.0) framesDelivered=\(values.1) capacityDropped=\(values.2) frameSpanSeconds=\(span) retainedBufferLeases=\(leases.current) peakBufferLeases=\(leases.peak)")
    }

    func deactivate() {
        lock.lock(); active = false; pending = nil; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        deactivate()
        Task { @MainActor [onStop] in onStop() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        lock.lock(); let enabled = active; lock.unlock()
        guard enabled,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer,
              CVPixelBufferGetWidth(buffer) <= 960,
              CVPixelBufferGetHeight(buffer) <= 600,
              Self.admitsPayload(rowBytes: CVPixelBufferGetBytesPerRow(buffer), height: CVPixelBufferGetHeight(buffer)) else { return }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer) else { return }
        lock.lock()
        received &+= 1
        let presentation = sampleBuffer.presentationTimeStamp.seconds
        if presentation.isFinite {
            if firstPresentationSeconds == nil { firstPresentationSeconds = presentation }
            lastPresentationSeconds = presentation
        }
        // Release an undelivered image before admitting its replacement, preserving the lease cap.
        pending = nil
        lock.unlock()
        guard let image = makeImage(from: buffer) else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        pending = image
        let needsDelivery = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if needsDelivery {
            DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
        }
    }

    /// Shared by actual frame delivery and the local synthetic ownership/pixel-format check.
    fileprivate func makeImage(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer),
              CVPixelBufferGetWidth(buffer) > 0, CVPixelBufferGetWidth(buffer) <= 960,
              CVPixelBufferGetHeight(buffer) > 0, CVPixelBufferGetHeight(buffer) <= 600,
              Self.admitsPayload(rowBytes: CVPixelBufferGetBytesPerRow(buffer), height: CVPixelBufferGetHeight(buffer)) else { return nil }
        if let referenceContext {
            let source = CIImage(cvPixelBuffer: buffer)
            guard let image = referenceContext.createCGImage(source, from: source.extent),
                  Self.admitsPayload(rowBytes: image.bytesPerRow, height: image.height) else { return nil }
            return image
        }
        guard let lease = CaptureBufferLease(buffer: buffer, budget: budget) else {
            lock.lock(); capacityDropped &+= 1; lock.unlock(); return nil
        }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // Admission above checked multiplication and the actual row-stride payload cap.
        let retained = Unmanaged.passRetained(lease)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: address,
                                           size: rowBytes * height, releaseData: { info, _, _ in
            if let info { Unmanaged<CaptureBufferLease>.fromOpaque(info).release() }
        }) else { retained.release(); return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(width: CVPixelBufferGetWidth(buffer), height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? colorSpace,
                                  bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return image
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        let image = active ? pending : nil
        pending = nil; deliveryScheduled = false
        if image != nil { delivered &+= 1 }
        lock.unlock()
        if let image { onImage(image) }
    }
}
