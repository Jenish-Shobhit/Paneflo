import AppKit
import PanefloCore
import Synchronization

/// Owned event tap. Creation never prompts or changes native shortcut preferences.
///
/// The tap runs on its own high-priority thread so system-wide typing never waits for
/// Paneflo's main thread. Routing reads a small lock-protected state; only actions hop to main.
@MainActor
final class GlobalShortcutService {
    typealias Configuration = ShortcutConfiguration
    enum State: Equatable {
        case disabled, arming, active, releasing, failed(String)
    }
    private(set) var state: State = .disabled { didSet { onStateChange?(state) } }
    var onAction: ((ShortcutAction) -> Void)?
    var onStateChange: ((State) -> Void)?
    private(set) var installedTapDescription: String?
    private var engine: ShortcutTapEngine?
    private var context = ShortcutTapEngine.Context()

    /// A switcher or Overview surface is on screen: Escape belongs to Paneflo.
    var surfaceVisible: Bool {
        get { context.surfaceVisible }
        set { context.surfaceVisible = newValue; engine?.update(context) }
    }
    /// The Overview holds real keyboard focus: Command–arrows arrange its selection.
    var selectionContextActive: Bool {
        get { context.selectionContextActive }
        set { context.selectionContextActive = newValue; engine?.update(context) }
    }
    /// Marked IME text is being edited in a Paneflo field: Escape goes to the input method.
    var compositionActive: Bool {
        get { context.compositionActive }
        set { context.compositionActive = newValue; engine?.update(context) }
    }

    isolated deinit { engine?.stop() }

    @discardableResult
    func start(configuration: Configuration) -> Bool {
        stop()
        guard !configuration.isEmpty else { return true }
        state = .arming
        guard CGPreflightListenEventAccess() else {
            state = .failed("Input Monitoring permission is required. Enable it in System Settings, then enable shortcuts again.")
            return false
        }
        let engine = makeEngine(configuration: configuration)
        switch engine.install() {
        case .failure(let failure):
            state = .failed(failure.message)
            return false
        case .success(let description):
            self.engine = engine
            installedTapDescription = description
            // Active means installed, not proof of precedence over other taps/native UI.
            state = .active
            return true
        }
    }

    func stop() {
        guard let engine else { state = .disabled; return }
        state = .releasing
        let wasSwitching = engine.stop()
        self.engine = nil
        installedTapDescription = nil
        state = .disabled
        if wasSwitching { onAction?(.cancel) }
    }

    private func makeEngine(configuration: Configuration) -> ShortcutTapEngine {
        ShortcutTapEngine(configuration: configuration, context: context) { [weak self] event in
            let queuedAt = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(event, queuedAt: queuedAt) }
            }
        }
    }

    private func receive(_ event: ShortcutTapEngine.Event, queuedAt: UInt64) {
        switch event {
        case .action(let action, let source):
            // Only a superseded tap session is stale. A suppressed key is always acted on;
            // the action handler drops it only if the target surface is gone.
            guard engine === source else { return }
            if RuntimeDiagnostics.isEnabled {
                let waited = Double(DispatchTime.now().uptimeNanoseconds &- queuedAt) / 1_000_000
                RuntimeDiagnostics.mark("input action queuedMilliseconds=\(waited)")
            }
            onAction?(action)
        case .failed(let reason, let source):
            guard engine === source else { return }
            stop()
            state = .failed(reason + " Enable shortcuts again to retry.")
        }
    }

    #if PANEFLO_NATIVE_CHECK
    /// Routes synthetic, never-posted events through the real callback path without installing a tap.
    func nativeCheckAttach(configuration: Configuration) {
        stop()
        let engine = makeEngine(configuration: configuration)
        self.engine = engine
        state = .active
    }
    @discardableResult
    func nativeCheckRoute(keyCode: UInt16, down: Bool = true, flags: CGEventFlags = []) -> Bool {
        guard let engine, let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return false }
        event.flags = flags
        return engine.handle(down ? .keyDown : .keyUp, event)
    }
    func nativeCheckFlags(_ flags: CGEventFlags) {
        guard let engine, let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false) else { return }
        event.type = .flagsChanged
        event.flags = flags
        _ = engine.handle(.flagsChanged, event)
    }
    func nativeCheckSimulateTapDisabled() {
        guard let engine, let event = CGEvent(source: nil) else { return }
        _ = engine.handle(.tapDisabledByTimeout, event)
    }
    #endif
}

/// CoreFoundation tap objects are thread-safe to enable, invalidate, stop and wake.
struct Handle<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Tap-thread state. Everything the callback touches is either immutable or behind `shared`.
final class ShortcutTapEngine: Sendable {
    struct Context: Sendable, Equatable {
        var surfaceVisible = false
        var selectionContextActive = false
        var compositionActive = false
    }
    enum Event: Sendable {
        case action(ShortcutAction, ShortcutTapEngine)
        case failed(String, ShortcutTapEngine)
    }
    private struct Shared {
        var router: ShortcutSession
        var budget = TapReenableBudget()
        var latency = CallbackLatencyWindow()
        var port: Handle<CFMachPort>?
        var runLoop: Handle<CFRunLoop>?
        var stopped = false
    }
    private let shared: Mutex<Shared>
    private let emit: @Sendable (Event) -> Void
    private let measuresLatency = RuntimeDiagnostics.isEnabled

    init(configuration: ShortcutConfiguration, context: Context, emit: @escaping @Sendable (Event) -> Void) {
        var router = ShortcutSession(configuration: configuration)
        router.surfaceVisible = context.surfaceVisible
        router.selectionContextActive = context.selectionContextActive
        router.compositionActive = context.compositionActive
        shared = Mutex(Shared(router: router))
        self.emit = emit
    }

    func update(_ context: Context) {
        shared.withLock {
            $0.router.surfaceVisible = context.surfaceVisible
            $0.router.selectionContextActive = context.selectionContextActive
            $0.router.compositionActive = context.compositionActive
        }
    }

    /// Creates the tap, starts its thread and enables it. Returns the installed tap's description.
    func install() -> Result<String, InstallFailure> {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ShortcutTapEngine>.fromOpaque(info).takeUnretainedValue()
            return engine.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        // The tap's thread owns one retain; it is released after the run loop exits,
        // when no further callback can run.
        let info = Unmanaged.passRetained(self)
        var installed: (CFMachPort, String)?
        for (location, label) in [(CGEventTapLocation.cghidEventTap, "HID / head insert"),
                                  (.cgSessionEventTap, "Session / head insert")] {
            if let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: mask, callback: callback, userInfo: info.toOpaque()) {
                installed = (port, label); break
            }
        }
        guard let (port, label) = installed else {
            info.release()
            return .failure(.init("macOS could not install a shortcut tap. Check Accessibility/Input Monitoring permissions and conflicting tools."))
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port); info.release()
            return .failure(.init("Could not create the shortcut run-loop source."))
        }
        let portHandle = Handle(port)
        shared.withLock { $0.port = portHandle }
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let threadSource = source
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, threadSource, .commonModes)
            let loopHandle = Handle(loop)
            let proceed = shared.withLock { state -> Bool in
                guard !state.stopped else { return false }
                state.runLoop = loopHandle
                return true
            }
            ready.signal()
            if proceed { CFRunLoopRun() }
            CFRunLoopRemoveSource(loop, threadSource, .commonModes)
            info.release()
        }
        thread.name = "Paneflo shortcut tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            _ = stop()
            return .failure(.init("macOS did not enable the shortcut tap."))
        }
        RuntimeDiagnostics.mark("input tap installed=\(label) thread=dedicated")
        return .success(label)
    }

    struct InstallFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    /// Disables the tap and ends its thread. Returns whether a switch session was in progress.
    @discardableResult
    func stop() -> Bool {
        let (port, loop, wasSwitching, summary) = shared.withLock { state in
            state.stopped = true
            let result = (state.port, state.runLoop, state.router.switching, state.latency.summary)
            state.port = nil; state.runLoop = nil
            state.router.reset()
            return result
        }
        if let port = port?.value { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop = loop?.value { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
        Self.log(summary, reason: "stop")
        return wasSwitching
    }

    /// Tap-thread entry point. Must stay short: every key press on the system waits for it.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let started = measuresLatency ? DispatchTime.now().uptimeNanoseconds : 0
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverFromDisable(type)
            return false
        }
        let kind: ShortcutEventKind
        switch type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .modifiersChanged
        default: return false
        }
        let flags = event.flags
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let (result, sessionEnded, escapeState) = shared.withLock { state in
            guard !state.stopped else { return (ShortcutRoute(), false, "") }
            let wasSwitching = state.router.switching
            let result = state.router.route(kind: kind, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
            let escape = measuresLatency && kind == .down && keyCode == 53
                ? "switching=\(state.router.switching) surfaceVisible=\(state.router.surfaceVisible) composing=\(state.router.compositionActive)" : ""
            return (result, wasSwitching && !state.router.switching, escape)
        }
        if let action = result.action { emit(.action(action, self)) }
        if measuresLatency {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            let summary = shared.withLock { state in
                state.latency.record(elapsed)
                return sessionEnded ? state.latency.summary : nil
            }
            if !escapeState.isEmpty {
                let line = "input escape owned=\(result.suppress) \(escapeState)"
                DispatchQueue.global(qos: .utility).async { RuntimeDiagnostics.mark(line) }
            }
            Self.log(summary, reason: "switchSessionEnded")
        }
        return result.suppress
    }

    private func recoverFromDisable(_ type: CGEventType) {
        let now = DispatchTime.now().uptimeNanoseconds
        let commandHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
        let (handle, reenable, recovery) = shared.withLock { state -> (Handle<CFMachPort>?, Bool, ShortcutAction?) in
            guard !state.stopped else { return (nil, false, nil) }
            let reenable = state.budget.shouldReenable(at: now)
            let recovery = reenable ? state.router.recoverAfterTapInterruption(commandHeld: commandHeld) : nil
            return (state.port, reenable, recovery)
        }
        guard let port = handle?.value else { return }
        if reenable {
            CGEvent.tapEnable(tap: port, enable: true)
            let enabled = CGEvent.tapIsEnabled(tap: port)
            DispatchQueue.global(qos: .utility).async {
                RuntimeDiagnostics.mark("input tap disabled=\(reason) reenabled=\(enabled) recoveredSwitch=\(recovery != nil)")
            }
            if let recovery { emit(.action(recovery, self)) }
            if enabled { return }
        }
        DispatchQueue.global(qos: .utility).async {
            RuntimeDiagnostics.mark("input tap disabled=\(reason) reenabled=false budgetExhausted=\(!reenable)")
        }
        let message = type == .tapDisabledByTimeout ? "Shortcut tap kept timing out" : "Shortcut tap kept being disabled by macOS"
        emit(.failed(message + ".", self))
    }

    private static func log(_ summary: CallbackLatencyWindow.Summary?, reason: String) {
        guard RuntimeDiagnostics.isEnabled, let summary else { return }
        let line = "input tapLatency reason=\(reason) callbacks=\(summary.callbacks) samples=\(summary.samples) "
            + "p50Microseconds=\(Double(summary.p50Nanoseconds) / 1000) p95Microseconds=\(Double(summary.p95Nanoseconds) / 1000) "
            + "maxMicroseconds=\(Double(summary.maxNanoseconds) / 1000)"
        DispatchQueue.global(qos: .utility).async { RuntimeDiagnostics.mark(line) }
    }
}
