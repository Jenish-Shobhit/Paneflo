import AppKit
import PanefloCore

struct TrackpadGestureDiagnostics: Sendable {
    var frames: UInt64 = 0
    var contacts: UInt64 = 0
    var rejectedFrames: UInt64 = 0
    var gestures: UInt64 = 0
    var upGestures: UInt64 = 0
    var downGestures: UInt64 = 0
    var palmOrRimContacts: UInt64 = 0
}

struct TrackpadGestureEvent: Sendable {
    let direction: ThreeFingerSwipeDirection
    let recognizedAtUptimeNanoseconds: UInt64
}

/// Optional private-API adapter. Scope: the default built-in trackpad on macOS 26 or later,
/// Apple silicon. The contact layout is checked at runtime (`TrackpadFrameSanity`) instead of
/// matching an exact framework version. Conflicting system gestures must be changed by the user;
/// `systemGestureConflict` reports whether they still appear to be on.
@MainActor
final class TrackpadGestureService {
    static let shared = TrackpadGestureService()
    private init() {}
    enum State: Equatable { case disabled, starting, active, stopping, paused, unavailable(String), failed(String) }
    enum Availability: Equatable { case experimental, unavailable(String) }
    private(set) var state: State = .disabled { didSet { onStateChange?(state) } }
    var onGesture: ((ThreeFingerSwipeDirection) -> Void)?
    var onGestureEvent: ((TrackpadGestureEvent) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// Counters contain no contact positions, identifiers, application or window data.
    var onDiagnostics: ((TrackpadGestureDiagnostics) -> Void)?
    var diagnosticCountsOnStop = false
    var availability: Availability {
        #if arch(arm64)
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? .experimental : .unavailable("Native trackpad gestures require macOS 26 or later.")
        #else
        return .unavailable("Native trackpad gestures have only been validated on Apple silicon.")
        #endif
    }
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var lifecycle = TrackpadLifecycleGate()
    private var lastFailure: String?
    private var permissionRevoked = false
    /// Cached Input Monitoring state, so gesture delivery never makes a TCC query.
    /// Refreshed on start and whenever any application (including Paneflo) activates,
    /// which is when the user returns from System Settings.
    private var inputMonitoringGranted = false
    /// User intent remains enabled while physical observation is paused for sleep/session changes.
    var isEnabled: Bool { lifecycle.isEnabled }
    /// A transient start failure (no built-in trackpad yet, closed lid) is retried on wake or when Paneflo
    /// becomes active, spaced and bounded; the user's toggle always retries and resets the bound.
    private var transientRetry = BoundedRetryGate(minimumSpacing: 10, maximumAttempts: 5)
    private var retryPending = false
    private var retryObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The next backend start comes from the user's toggle, which may re-probe the device at once.
    private var nextStartIsManual = false

    /// Read-only CFPreferences lookup of the conflicting system swipes. Not for the gesture path:
    /// call it when Settings opens or Paneflo activates.
    var systemGestureConflict: SystemGestureConflict { SystemGestureSettings.current().conflict }

    isolated deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for (center, observer) in retryObservers { center.removeObserver(observer) }
        TrackpadBackend.shared.cancel()
        TrackpadBackend.shared.stop { _ in }
    }

    /// True means user enable intent was accepted; .active confirms hardware observation.
    @discardableResult
    func start() -> Bool {
        if isEnabled { return true }
        cancelTransientRetry()
        transientRetry.reset()
        nextStartIsManual = true
        return enable()
    }

    private func enable() -> Bool {
        guard validateEnvironment() else { return false }
        permissionRevoked = false
        lastFailure = nil
        observeLifecycle()
        apply(lifecycle.send(.enable))
        return true
    }

    /// User disable clears intent and prevents any pending automatic resume.
    func stop() {
        cancelTransientRetry()
        permissionRevoked = false
        removeLifecycleObservers()
        apply(lifecycle.send(.disable))
    }

    private func stopAfterPermissionRevocation() {
        permissionRevoked = true
        removeLifecycleObservers()
        apply(lifecycle.send(.disable))
        publishState()
    }

    func suspendForLifecycleChange(_ reason: TrackpadLifecycleGate.Reason = .sessionInactive) {
        apply(lifecycle.send(.pause(reason)))
    }

    private func wake(_ reason: TrackpadLifecycleGate.Reason) {
        apply(lifecycle.send(.wake(reason)))
    }

    private func apply(_ effect: TrackpadLifecycleGate.Effect?) {
        publishState()
        switch effect {
        case .start: beginObservation()
        case .stop: endObservation()
        case nil: break
        }
    }

    private func beginObservation() {
        // Every automatic attempt revalidates permission, platform and the framework below.
        guard validateEnvironment() else {
            lastFailure = "Native trackpad gestures could not resume because permission or platform support changed."
            _ = lifecycle.send(.startFailed)
            removeLifecycleObservers(); publishState()
            return
        }
        generation &+= 1
        let token = generation
        let manual = nextStartIsManual
        nextStartIsManual = false
        TrackpadBackend.shared.start(manual: manual, onGesture: { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                // No age limit: a late gesture is still delivered. Its handlers check the
                // Overview's current state, so a stale up or down cannot misfire.
                guard let self, self.generation == token, self.state == .active, self.isEnabled else { return }
                guard self.inputMonitoringGranted else {
                    self.stopAfterPermissionRevocation()
                    return
                }
                if let onGestureEvent = self.onGestureEvent { onGestureEvent(event) }
                else { self.onGesture?(event.direction) }
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                switch result {
                case .active:
                    self.transientRetry.reset()
                    self.apply(self.lifecycle.send(.started))
                case .failed(let reason, let transient):
                    let retries = transient && !self.transientRetry.isExhausted
                    self.lastFailure = retries ? reason + " Paneflo will try again when the Mac wakes or when you return to Paneflo." : reason
                    _ = self.lifecycle.send(.startFailed)
                    self.removeLifecycleObservers()
                    if retries { self.scheduleTransientRetry() }
                    self.publishState()
                }
            }
        })
    }

    private func endObservation() {
        generation &+= 1
        let token = generation
        TrackpadBackend.shared.cancel()
        let report = diagnosticCountsOnStop
        TrackpadBackend.shared.stop { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                if report { self.onDiagnostics?(result.diagnostics) }
                if let reason = result.failure { self.lastFailure = reason }
                let effect = self.lifecycle.send(.stopped(clean: result.failure == nil))
                if !self.isEnabled { self.removeLifecycleObservers() }
                self.apply(effect)
            }
        }
    }

    private func validateEnvironment() -> Bool {
        guard availability == .experimental else {
            if case .unavailable(let reason) = availability { state = .unavailable(reason) }
            return false
        }
        inputMonitoringGranted = CGPreflightListenEventAccess()
        guard inputMonitoringGranted else {
            state = .unavailable("Input Monitoring permission is required for native trackpad gestures.")
            return false
        }
        return true
    }

    private func refreshInputMonitoring() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
        if !inputMonitoringGranted, isEnabled { stopAfterPermissionRevocation() }
    }

    private func publishState() {
        switch lifecycle.phase {
        case .disabled:
            state = permissionRevoked
                ? .unavailable("Input Monitoring permission is required for native trackpad gestures.") : .disabled
        case .starting: state = .starting
        case .active: state = .active
        case .stopping: state = .stopping
        case .paused: state = .paused
        case .failed: state = .failed(lastFailure ?? "Native trackpad observation could not be confirmed.")
        }
    }

    private func observeLifecycle() {
        removeLifecycleObservers()
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, TrackpadLifecycleGate.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, false),
            (NSWorkspace.didWakeNotification, .systemSleep, true),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, false),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, true),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, true)
        ]
        for (name, reason, waking) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if waking { self?.wake(reason) } else { self?.suspendForLifecycleChange(reason) }
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputMonitoring() }
        })
    }
    // MARK: Transient failure retry

    private func scheduleTransientRetry() {
        cancelTransientRetry()
        retryPending = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            retryObservers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryAfterTransientFailure(trigger: "wake") }
            }))
        }
        retryObservers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryAfterTransientFailure(trigger: "activation") }
        }))
    }

    private func cancelTransientRetry() {
        retryPending = false
        for (center, observer) in retryObservers { center.removeObserver(observer) }
        retryObservers.removeAll()
    }

    private func retryAfterTransientFailure(trigger: String) {
        guard retryPending, !isEnabled, lifecycle.phase == .failed,
              transientRetry.permit(now: ProcessInfo.processInfo.systemUptime) else { return }
        cancelTransientRetry()
        RuntimeDiagnostics.mark("gesture transientRetry trigger=\(trigger) attempt=\(transientRetry.attempts)")
        _ = enable()
    }

    private func removeLifecycleObservers() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

}

private enum TrackpadStartResult: Sendable {
    case active
    /// `transient`: the device may appear later (none yet, lid closed, start refused); a retry may succeed.
    case failed(String, transient: Bool)
}
private struct TrackpadStopResult: Sendable {
    var diagnostics: TrackpadGestureDiagnostics
    var failure: String?
}
private typealias ContactCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32
) -> Void
nonisolated(unsafe) private let trackpadContactCallback: ContactCallback = { _, bytes, count, time, _ in
    TrackpadBackend.shared.receive(bytes: bytes, count: count, timestamp: time)
}

/// Process-lifetime singleton: one device/library lease, no per-enable retain leak.
/// Lifecycle API calls belong exclusively to queue. The callback state belongs to lock.
/// Callback code and its context stay valid even if the framework calls back late.
private final class TrackpadBackend: @unchecked Sendable {
    static let shared = TrackpadBackend()
    private let queue = DispatchQueue(label: "Paneflo.trackpad.lifecycle", qos: .userInitiated)
    private let lock = NSLock()
    private var observing = false
    private var activationEpoch: UInt64 = 0
    private var recognizer = ThreeFingerSwipe()
    private var freshContacts = FreshContactGate()
    private var layoutCheck = TrackpadFrameSanity()
    private var diagnostics = TrackpadGestureDiagnostics()
    private var gestureHandler: (@Sendable (TrackpadGestureEvent) -> Void)?
    private var failureHandler: (@Sendable (TrackpadStartResult) -> Void)?
    private var lastTimestamp: Double?
    // Queue-confined state. The resource is never released or dlclosed during the process.
    private var symbols: Symbols?
    private var permanentFailure: String?
    private var resources: Resources?
    private var failureReason: String?
    /// Device probes after the framework loaded: spaced and bounded, so a missing device never spins.
    private var deviceProbes = BoundedRetryGate(minimumSpacing: 5, maximumAttempts: 6)
    private var registered = false
    private var poisoned = false

    private struct Symbols {
        let library: UnsafeMutableRawPointer
        let create: @convention(c) () -> UnsafeMutableRawPointer?
        let builtIn: @convention(c) (UnsafeMutableRawPointer) -> Bool
        let register: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Bool
        let unregister: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Bool
        let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let running: @convention(c) (UnsafeMutableRawPointer) -> Bool
    }

    private struct Resources {
        let library: UnsafeMutableRawPointer
        let device: UnsafeMutableRawPointer
        let register: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Bool
        let unregister: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Bool
        let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let running: @convention(c) (UnsafeMutableRawPointer) -> Bool
    }

    func start(manual: Bool, onGesture: @escaping @Sendable (TrackpadGestureEvent) -> Void,
               completion: @escaping @Sendable (TrackpadStartResult) -> Void) {
        lock.lock(); let requestEpoch = activationEpoch; lock.unlock()
        queue.async { [self] in
            guard !registered, !poisoned else {
                completion(.failed("Trackpad shutdown has not completed safely. Restart Paneflo before trying again.", transient: false)); return
            }
            guard let resource = prepare(manual: manual) else {
                completion(.failed(failureReason ?? "The default built-in trackpad is unavailable.", transient: permanentFailure == nil)); return
            }
            lock.lock()
            guard activationEpoch == requestEpoch else {
                lock.unlock(); completion(.failed("Trackpad start was canceled.", transient: false)); return
            }
            diagnostics = .init(); recognizer = ThreeFingerSwipe(); freshContacts.reset(); lastTimestamp = nil
            layoutCheck = TrackpadFrameSanity()
            gestureHandler = onGesture; failureHandler = completion
            observing = true
            lock.unlock()
            guard resource.register(resource.device, trackpadContactCallback) else {
                cancel(); completion(.failed("macOS declined the trackpad contact callback.", transient: true)); return
            }
            registered = true
            let result = resource.start(resource.device, 0)
            guard result == 0 else {
                cancel()
                let stopped = stopPhysical()
                completion(.failed(stopped.failure ?? "Could not start the built-in trackpad (status \(result)).",
                                   transient: stopped.failure == nil))
                return
            }
            guard resource.running(resource.device) else {
                cancel()
                let stopped = stopPhysical()
                completion(.failed(stopped.failure ?? "The built-in trackpad did not begin observation.", transient: stopped.failure == nil)); return
            }
            completion(.active)
        }
    }

    func cancel() {
        lock.lock()
        activationEpoch &+= 1
        observing = false; recognizer.reset(); freshContacts.reset(); gestureHandler = nil; failureHandler = nil
        lock.unlock()
    }
    func stop(completion: @escaping @Sendable (TrackpadStopResult) -> Void) {
        queue.async { [self] in completion(stopPhysical()) }
    }
    private func stopPhysical() -> TrackpadStopResult {
        var failure: String?
        if registered, let resource = resources {
            // Stop drains the device worker on this tested host. Unregister alone does not.
            let result = resource.running(resource.device) ? resource.stop(resource.device) : 0
            if result != 0 || resource.running(resource.device) {
                poisoned = true
                failure = "Trackpad observation could not stop cleanly. Restart Paneflo before enabling it again."
            } else if !resource.unregister(resource.device, trackpadContactCallback) {
                poisoned = true
                failure = "Trackpad callback cleanup could not be confirmed. Restart Paneflo before enabling it again."
            } else { registered = false }
        }
        lock.lock(); let counts = diagnostics; lock.unlock()
        return .init(diagnostics: counts, failure: failure)
    }

    /// Loads the framework and its functions once; a missing library or function is permanent. The default
    /// built-in device is probed again on later starts if it was missing (no device at first enable, lid closed):
    /// a manual start probes at once, automatic ones are spaced and bounded by `deviceProbes`. No polling or
    /// external-device enumeration. Any framework revision that exports the required functions is accepted here;
    /// `receive` then refuses contact data that fails the hard range checks or the runtime layout check.
    private func prepare(manual: Bool) -> Resources? {
        if let resources { return resources }
        if let permanentFailure { failureReason = permanentFailure; return nil }
        if symbols == nil {
            guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL) else {
                permanentFailure = "Native trackpad support is unavailable on this system."
                failureReason = permanentFailure; return nil
            }
            // Failure paths retain only this one library handle; no callback is registered.
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                guard let address = dlsym(library, name) else { return nil }
                return unsafeBitCast(address, to: T.self)
            }
            typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
            typealias BuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
            typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Bool
            typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
            typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32
            guard let create = symbol("MTDeviceCreateDefault", Create.self),
                  let builtIn = symbol("MTDeviceIsBuiltIn", BuiltIn.self),
                  let register = symbol("MTRegisterContactFrameCallback", Register.self),
                  let unregister = symbol("MTUnregisterContactFrameCallback", Register.self),
                  let start = symbol("MTDeviceStart", Start.self),
                  let stop = symbol("MTDeviceStop", Stop.self),
                  let running = symbol("MTDeviceIsRunning", BuiltIn.self) else {
                permanentFailure = "Required native trackpad functions are unavailable."
                failureReason = permanentFailure; return nil
            }
            symbols = Symbols(library: library, create: create, builtIn: builtIn, register: register,
                              unregister: unregister, start: start, stop: stop, running: running)
        }
        guard let symbols else { return nil }
        if manual { deviceProbes.reset() }
        guard deviceProbes.permit(now: ProcessInfo.processInfo.systemUptime) else {
            failureReason = "The built-in trackpad is still unavailable. Turn the gesture on again to retry."
            return nil
        }
        // A device that is not the built-in trackpad is not released (its ownership is undocumented); the probe
        // bound keeps that to a few objects.
        guard let device = symbols.create(), symbols.builtIn(device) else {
            failureReason = "The built-in trackpad is not available right now (for example, the lid is closed). Only the default built-in trackpad is supported by this experimental adapter."
            return nil
        }
        deviceProbes.reset()
        let resource = Resources(library: symbols.library, device: device, register: symbols.register, unregister: symbols.unregister,
                                 start: symbols.start, stop: symbols.stop, running: symbols.running)
        resources = resource
        return resource
    }

    /// 96-byte contact layout (timestamp 8, identifier 16, state 20, normalized x/y 32/36, size 48,
    /// major/minor axis 60/64), confirmed on a macOS 27 host and checked at runtime by layoutCheck.
    /// Decode only bounded counts; never retain the framework's borrowed buffer.
    func receive(bytes: UnsafeRawPointer?, count: Int32, timestamp: Double) {
        lock.lock()
        guard observing else { lock.unlock(); return }
        diagnostics.frames &+= 1
        guard (0...32).contains(count), timestamp.isFinite, count == 0 || bytes != nil else {
            rejectFrame(); return
        }
        if let previous = lastTimestamp, timestamp <= previous {
            diagnostics.rejectedFrames &+= 1
            recognizer.reset(); lastTimestamp = timestamp
            lock.unlock(); return
        }
        lastTimestamp = timestamp
        var contacts = ContactFrame()
        var evidence = ContactEvidenceFrame()
        layoutCheck.beginFrame()
        if let bytes {
            for index in 0..<Int(count) {
                let sample = bytes.advanced(by: index * 96)
                let time = sample.loadUnaligned(fromByteOffset: 8, as: Double.self)
                let state = sample.loadUnaligned(fromByteOffset: 20, as: Int32.self)
                let x = sample.loadUnaligned(fromByteOffset: 32, as: Float.self)
                let y = sample.loadUnaligned(fromByteOffset: 36, as: Float.self)
                let size = sample.loadUnaligned(fromByteOffset: 48, as: Float.self)
                let major = sample.loadUnaligned(fromByteOffset: 60, as: Float.self)
                let minor = sample.loadUnaligned(fromByteOffset: 64, as: Float.self)
                guard time.isFinite, (0...7).contains(state), x.isFinite, y.isFinite,
                      (-0.1...1.1).contains(x), (-0.1...1.1).contains(y), size.isFinite,
                      major.isFinite, minor.isFinite, major >= 0, minor >= 0 else {
                    rejectFrame(); return
                }
                let id = sample.loadUnaligned(fromByteOffset: 16, as: Int32.self)
                layoutCheck.observe(.init(id: id, state: state, x: x, y: y, size: size, majorAxis: major, minorAxis: minor))
                guard (3...5).contains(state) else { continue }
                evidence.append(.init(id: id, phase: state == 3 ? .began : .continuing))
                // An oversized contact cancels the stroke rather than hiding a fourth finger.
                // Edge contacts are ordinary: a finger may start a swipe at the bottom edge, and a
                // resting edge contact cannot pass the recognizer's per-finger travel agreement.
                let palm = size > 1.5
                if palm || x < 0.035 || x > 0.965 || y < 0.035 { diagnostics.palmOrRimContacts &+= 1 }
                contacts.append(.init(id: id, x: Double(x), y: Double(y), isPalm: palm))
                diagnostics.contacts &+= 1
            }
        }
        let layout = layoutCheck.endFrame()
        if case .implausible(let reason) = layout {
            rejectFrame(reason: "Native trackpad gestures were turned off because this Mac's trackpad data did not look as expected (" + reason + ").")
            return
        }
        let isFresh = freshContacts.accepts(evidence)
        if !isFresh { recognizer.reset() }
        else if contacts.isEmpty { _ = recognizer.update(timestamp: timestamp, contacts: contacts) }
        let direction = isFresh && !contacts.isEmpty
            ? recognizer.update(timestamp: timestamp, contacts: contacts) : nil
        // Until the layout check passes, recognition runs but nothing is delivered.
        let handler = direction == nil || layout != .plausible ? nil : gestureHandler
        let recognizedAt = direction == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        if let direction, handler != nil {
            diagnostics.gestures &+= 1
            switch direction {
            case .up: diagnostics.upGestures &+= 1
            case .down: diagnostics.downGestures &+= 1
            }
        }
        lock.unlock()
        if let direction, let handler {
            handler(.init(direction: direction, recognizedAtUptimeNanoseconds: recognizedAt))
        }
    }

    /// Called with lock held. Quarantine corrupt ABI data and shut down on lifecycle queue.
    private func rejectFrame(reason: String = "Unexpected trackpad contact data. Native gestures have been stopped; restart Paneflo before trying again.") {
        diagnostics.rejectedFrames &+= 1
        observing = false; recognizer.reset(); freshContacts.reset()
        let handler = failureHandler
        gestureHandler = nil; failureHandler = nil
        lock.unlock()
        queue.async { [self] in
            _ = stopPhysical()
            poisoned = true
            handler?(.failed(reason, transient: false))
        }
    }
}

/// Stores no more than three identifiers; a fourth increments count and is
/// rejected by FreshContactGate before any indexed read.
private struct ContactEvidenceFrame: RandomAccessCollection {
    typealias Index = Int
    private var first: SwipeContactEvidence?
    private var second: SwipeContactEvidence?
    private var third: SwipeContactEvidence?
    private(set) var endIndex = 0
    var startIndex: Int { 0 }
    mutating func append(_ contact: SwipeContactEvidence) {
        switch endIndex { case 0: first = contact; case 1: second = contact; case 2: third = contact; default: break }
        endIndex += 1
    }
    subscript(index: Int) -> SwipeContactEvidence {
        switch index { case 0: return first!; case 1: return second!; case 2: return third!; default: preconditionFailure("Only three contacts may be inspected") }
    }
}

/// At most three stored samples; four or more contacts reject before indexing.
private struct ContactFrame: RandomAccessCollection {
    typealias Index = Int
    private var first: SwipeContact?
    private var second: SwipeContact?
    private var third: SwipeContact?
    private(set) var endIndex = 0
    var startIndex: Int { 0 }
    mutating func append(_ contact: SwipeContact) {
        switch endIndex { case 0: first = contact; case 1: second = contact; case 2: third = contact; default: break }
        endIndex += 1
    }
    subscript(index: Int) -> SwipeContact {
        switch index { case 0: return first!; case 1: return second!; case 2: return third!; default: preconditionFailure("Only three contacts may be inspected") }
    }
}
