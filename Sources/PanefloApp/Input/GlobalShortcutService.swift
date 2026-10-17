import AppKit
import PanefloCore

/// Owned main-runloop event tap. Creation never prompts or changes native shortcut preferences.
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
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var router = ShortcutSession(configuration: .init())
    private var generation: UInt64 = 0
    private var ownershipGeneration: UInt64 = 0
    func invalidateSelectionPresentation() { ownershipGeneration &+= 1 }
    var compositionActive: Bool {
        get { router.compositionActive }
        set {
            if router.compositionActive != newValue { ownershipGeneration &+= 1 }
            router.compositionActive = newValue
        }
    }
    var selectionContextActive: Bool {
        get { router.selectionContextActive }
        set {
            if router.selectionContextActive != newValue { ownershipGeneration &+= 1 }
            router.selectionContextActive = newValue
        }
    }

    isolated deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    @discardableResult
    func start(configuration: Configuration) -> Bool {
        stop()
        guard !configuration.isEmpty else { return true }
        state = .arming
        guard CGPreflightListenEventAccess() else {
            state = .failed("Input Monitoring permission is required. Enable it in System Settings, then enable shortcuts again.")
            return false
        }
        router = ShortcutSession(configuration: configuration)
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // The source is installed only on the main run loop.
            let suppress = MainActor.assumeIsolated {
                Unmanaged<GlobalShortcutService>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }
        var installed: CFMachPort?
        for (location, label) in [(CGEventTapLocation.cghidEventTap, "HID / head insert"),
                                  (.cgSessionEventTap, "Session / head insert")] {
            if let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                installed = port; installedTapDescription = label; break
            }
        }
        guard let port = installed else {
            router.reset()
            state = .failed("macOS could not install a shortcut tap. Check Accessibility/Input Monitoring permissions and conflicting tools.")
            return false
        }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            state = .failed("Could not create the shortcut run-loop source.")
            return false
        }
        tap = port; source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            stop(); state = .failed("macOS did not enable the shortcut tap."); return false
        }
        // Active means installed, not proof of precedence over other taps/native UI.
        state = .active
        return true
    }

    func stop() {
        let wasSwitching = router.switching
        generation &+= 1
        if tap != nil { state = .releasing }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; installedTapDescription = nil; router.reset(); state = .disabled
        if wasSwitching { onAction?(.cancel) }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // No automatic re-enable loop: relinquish ownership immediately.
            let reason = type == .tapDisabledByTimeout ? "Shortcut tap timed out" : "Shortcut tap was disabled by macOS"
            stop()
            state = .failed(reason + ". Enable shortcuts again to retry.")
            return false
        }
        guard state == .active else { return false }
        let kind: ShortcutEventKind = type == .keyDown ? .down : type == .keyUp ? .up : .modifiersChanged
        let flags = event.flags
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        let wasSwitching = router.switching
        let result = router.route(kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: modifiers, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        if keyCodeForDiagnostics(type, event) {
            RuntimeDiagnostics.mark("input escape owned=\(result.suppress) switching=\(router.switching) selectionOwned=\(router.selectionContextActive)")
        }
        if let action = result.action { enqueue(action, wasSwitching: wasSwitching) }
        return result.suppress
    }

    private func enqueue(_ action: ShortcutAction, wasSwitching: Bool, queuedAt: Double = ProcessInfo.processInfo.systemUptime) {
        let token = generation
        let ownershipToken = ownershipGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            let age = ProcessInfo.processInfo.systemUptime - queuedAt
            switch action {
            case .switchForward, .switchBackward, .commit, .cancel: break
            case .navigate, .overview, .tile, .tileSelected, .restore:
                if age > 0.25 {
                    RuntimeDiagnostics.mark("input action discarded=expired ageMilliseconds=\(age * 1000)")
                    return
                }
            }
            if case .cancel = action, !wasSwitching, self.ownershipGeneration != ownershipToken {
                RuntimeDiagnostics.mark("input cancel discarded=ownershipChanged")
                return
            }
            if RuntimeDiagnostics.isEnabled {
                RuntimeDiagnostics.mark("input action queuedMilliseconds=\(age * 1000)")
            }
            self.onAction?(action)
        }
    }

    #if PANEFLO_NATIVE_CHECK
    func nativeCheckQueueCancel() { enqueue(.cancel, wasSwitching: false) }
    func nativeCheckQueue(_ action: ShortcutAction, ageSeconds: Double) {
        enqueue(action, wasSwitching: false, queuedAt: ProcessInfo.processInfo.systemUptime - ageSeconds)
    }
    #endif

    private func keyCodeForDiagnostics(_ type: CGEventType, _ event: CGEvent) -> Bool {
        RuntimeDiagnostics.isEnabled && type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
    }
}
