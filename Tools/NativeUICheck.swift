import AppKit
import PanefloCore
import Darwin

/// Own-window AppKit regression host. Never posts global input or requests permission.
@main
struct NativeUICheck {
    @MainActor static func main() {
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()
        let logPath = URL(fileURLWithPath: output).appendingPathComponent("native-ui-check.log").path
        if freopen(logPath, "w", stdout) != nil { dup2(fileno(stdout), fileno(stderr)); setbuf(stdout, nil) }
        print("START native UI check")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do {
                try await run()
                print("PASS own-window native UI checks")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL native UI: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    enum Failure: Error { case check(String) }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.check(message) }
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    @MainActor static func run() async throws {
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()
        let service = WindowService()
        let desktop = DesktopController(service: service)
        try require(!desktop.nativeCheckPreferencesConstructed, "Settings must remain lazy at controller initialization")
        desktop.enablePreviewControl()
        try require(desktop.nativeCheckPreviewControlEnabled, "Preview control must enable before Settings construction")
        service.onChange = { desktop.updateSnapshot() }
        let owner = ProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier, launchToken: 1)
        func records(_ count: Int) -> [WindowRecord] {
            (0..<count).map { index in
                WindowRecord(id: WindowIdentity(process: owner, number: UInt32(index + 1), incarnation: 1),
                    appIdentifier: "org.paneflo.native-check", appName: "Synthetic app \(index / 4 + 1)",
                    title: "Synthetic document \(index + 1)", frame: WindowRect(x: 0, y: 0, width: 440, height: 288))
            }
        }
        let input = GlobalShortcutService()
        var canceled = 0
        var deliveredStandalone = 0
        var deliveredCommit = 0
        input.onAction = { action in
            switch action {
            case .cancel:
                canceled += 1
                if desktop.isVisible { desktop.dismiss(restorePreviousApplication: false) }
            case .commit: deliveredCommit += 1
            case .overview, .tile, .restore: deliveredStandalone += 1
            default: break
            }
        }
        desktop.onPresentationChanged = { input.invalidateSelectionPresentation() }
        input.selectionContextActive = true
        input.nativeCheckQueueCancel()
        input.selectionContextActive = false
        input.selectionContextActive = true
        await settle()
        try require(canceled == 0, "Old queued cancel must not close newly owned panel")
        input.nativeCheckQueueCancel()
        await settle()
        try require(canceled == 1, "Current queued cancel must deliver once")
        input.nativeCheckQueue(.overview, ageSeconds: 1)
        input.nativeCheckQueue(.tile(.leftHalf), ageSeconds: 1)
        input.nativeCheckQueue(.restore, ageSeconds: 1)
        input.nativeCheckQueue(.commit, ageSeconds: 1)
        await settle()
        try require(deliveredStandalone == 0, "Delayed standalone actions must expire")
        try require(deliveredCommit == 1, "Held switcher commit must survive queue delay")
        input.nativeCheckQueue(.overview, ageSeconds: 0)
        await settle()
        try require(deliveredStandalone == 1, "Fresh standalone action must deliver")
        for count in [20, 100] {
            print("START cards=\(count)")
            service.nativeCheckInstall(records(count))
            await settle()
            var timings: [Double] = []
            for _ in 0..<5 {
                let begin = ProcessInfo.processInfo.systemUptime
                desktop.focusOverview()
                desktop.nativeCheckSuppressExternalRestore()
                timings.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
                await settle()
                try require(desktop.nativeCheckWindow.isKeyWindow && NSApp.isActive, "Overview must gain real key ownership")
                if count == 20 {
                    input.nativeCheckQueueCancel()
                    desktop.present(mode: .switcher, fromShortcut: true)
                    await settle()
                    try require(desktop.isVisible && canceled == 1, "Queued old Escape must not close a new picker")
                    desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
                    await settle()
                }
                let slots = desktop.nativeCheckSlots
                desktop.nativeCheckQuery("document 12")
                try require(desktop.nativeCheckSlots == slots, "Search must preserve Overview slots")
                try require(desktop.nativeCheckSelected?.number == 12, "Search must select the matching identity")
                desktop.nativeCheckQuery("a query with no synthetic match 987654")
                try require(desktop.nativeCheckSelected == nil, "No-match search must clear selection")
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                NSApp.sendEvent(enter)
                try require(desktop.isVisible, "Return with no search match must not dismiss")
                desktop.nativeCheckQuery("document 12")
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                NSApp.sendEvent(escape)
                try require(!desktop.isVisible, "Escape must close nonempty search with global input OFF")
                try require(desktop.nativeCheckPayloadCount == 0, "Dismissal must release card images")
                await settle()
            }
            desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
            await settle()
            var preparedComposition = false
            desktop.onCompositionChanged = { preparedComposition = $0 }
            if let editor = desktop.nativeCheckSearch.currentEditor() as? NSTextView {
                editor.setMarkedText("synthetic", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                await settle()
                try require(preparedComposition, "Field editor composition must update prepared input state")
                let firstEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                NSApp.sendEvent(firstEscape)
                try require(desktop.isVisible, "First Escape during composition must leave Overview open")
                editor.unmarkText()
                desktop.nativeCheckQuery("")
                await settle()
                try require(!preparedComposition, "Ending composition must restore Escape ownership")
            } else { throw Failure.check("Missing real search field editor") }
            let view = desktop.nativeCheckWindow.contentView!
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("native-overview-\(count).png"))
                }
            }
            print("cards=\(count) presentationMilliseconds=\(timings)")
            let finalEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            NSApp.sendEvent(finalEscape)
            try require(!desktop.isVisible, "Next Escape after composition must close Overview")
            await settle()
        }
        desktop.present(mode: .switcher)
        await settle()
        let view = desktop.nativeCheckWindow.contentView!
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("native-switcher.png"))
            }
        }
        desktop.present(mode: .switcher, fromShortcut: true)
        await settle()
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("native-held-command-switcher.png"))
            }
        }
        desktop.dismiss(restorePreviousApplication: false)
        var previewVisible = false
        var thumbnailsVisible = false
        var selectionOwned = false
        desktop.onPreviewSelection = { _, visible, _ in previewVisible = visible }
        desktop.onThumbnailViewport = { _, visible, _ in thumbnailsVisible = visible }
        desktop.onVisibilityChanged = { selectionOwned = $0 }
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let fixture = NSImage(size: NSSize(width: 2, height: 2))
        fixture.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        fixture.unlockFocus()
        guard let image = fixture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.check("Could not construct own synthetic preview")
        }
        desktop.nativeCheckInjectPreview(image)
        try require(desktop.nativeCheckPayloadCount > 0 && previewVisible && thumbnailsVisible && selectionOwned,
                    "Hide fixture must begin with visible panel and synthetic image")
        NSApp.hide(nil)
        await settle()
        try require(!desktop.isVisible && desktop.nativeCheckPayloadCount == 0,
                    "Hiding app must dismiss panel and release preview payload")
        try require(!previewVisible && !thumbnailsVisible && !selectionOwned,
                    "Hiding app must release preview and keyboard ownership")
        NSApp.unhideWithoutActivation()
        desktop.setStatus("Synthetic permission diagnostic")
        desktop.setShortcutsEnabled(true)
        desktop.setGestureState(enabled: true, description: "Synthetic ready")
        desktop.showPreferences()
        try require(desktop.nativeCheckPreferencesConstructed && desktop.nativeCheckPreviewControlEnabled,
                    "Opening lazy Settings must preserve enabled preview control")
        try require(desktop.nativeCheckShortcutsEnabled && desktop.nativeCheckGestureEnabled
                    && desktop.nativeCheckStatus == "Synthetic permission diagnostic",
                    "Lazy Settings must retain prepared toggle and status state")
    }
}
