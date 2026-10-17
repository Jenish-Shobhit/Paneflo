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
    @MainActor static var outsideClick: (@MainActor (NSPoint) -> Void)?
    @MainActor static var outsideMonitors = 0
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.check(message) }
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    @MainActor static func run() async throws {
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()
        let service = WindowService()
        let desktop = DesktopController(service: service)
        // Never install a real global mouse monitor during checks; record install/remove instead.
        desktop.nativeCheckReplaceOutsideClickMonitor(install: { handler in
            outsideClick = handler; outsideMonitors += 1; return NSObject()
        }, remove: { _ in outsideMonitors -= 1; outsideClick = nil })
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
        // LaunchServices may still be delivering the launch activation; let it land first.
        try? await Task.sleep(for: .milliseconds(600))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        func panefloFrontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID }
        print("launch appActive=\(NSApp.isActive) frontmost=\(panefloFrontmost())")
        for count in [20, 100] {
            print("START cards=\(count)")
            service.nativeCheckInstall(records(count))
            await settle()
            var timings: [Double] = []
            for _ in 0..<5 {
                let wasFrontmost = panefloFrontmost()
                let begin = ProcessInfo.processInfo.systemUptime
                desktop.focusOverview()
                desktop.nativeCheckSuppressExternalRestore()
                timings.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
                await settle()
                try require(desktop.nativeCheckWindow.isKeyWindow, "Overview must gain real key ownership")
                // A key non-activating panel reports NSApp.isActive, but the frontmost application must not change.
                try require(wasFrontmost || !panefloFrontmost(), "Overview must not activate Paneflo")
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
        try await checkFastSurfaces(desktop, service: service, records: records)
        try await checkInputRouting(desktop)
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
        try require(desktop.nativeCheckGestureGuidanceStatus == GestureGuidance.status(for: SystemGestureSettings.current().conflict),
                    "Settings must show the live system-gesture status when opened")
        try require(outsideMonitors == 0, "No outside-click monitor may remain while surfaces are hidden")
    }

    /// Two pre-created panels, diff-based cards, no hidden rebuilds, two-card selection redraws,
    /// lazy menus, and Overview dismissal when another application activates.
    @MainActor static func checkFastSurfaces(_ desktop: DesktopController, service: WindowService,
                                             records: (Int) -> [WindowRecord]) async throws {
        print("START fast surfaces")
        try require(desktop.nativeCheckSwitcherWindow !== desktop.nativeCheckOverviewWindow, "Switcher and Overview must use separate panels")
        service.nativeCheckInstall(records(20))
        await settle()
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let overviewFrame = desktop.nativeCheckOverviewWindow.frame
        desktop.dismiss(restorePreviousApplication: false)
        await settle()
        desktop.present(mode: .switcher, fromShortcut: true)
        await settle()
        let switcherFrame = desktop.nativeCheckSwitcherWindow.frame
        try require(!desktop.nativeCheckSwitcherWindow.isKeyWindow, "The held switcher must not take key focus")
        try require(switcherFrame.size != overviewFrame.size, "Switcher must keep its own size")
        try require(desktop.nativeCheckOverviewWindow.frame == overviewFrame, "Presenting the switcher must not touch the Overview panel")

        // Selection redraws only the previous and the new card.
        CardView.invalidations = 0
        desktop.switchStep(backwards: false)
        try require(CardView.invalidations == 2, "A Tab step must redraw exactly two cards, redrew \(CardView.invalidations)")
        guard let reusedID = desktop.nativeCheckSelected, let reusedCard = desktop.nativeCheckCard(for: reusedID) else {
            throw Failure.check("Missing selected switcher card")
        }

        // Dismissal schedules no hidden rebuild; registry churn while hidden is coalesced.
        let appliedBeforeDismiss = desktop.nativeCheckOverviewApplyCount
        desktop.dismiss(restorePreviousApplication: false)
        try await Task.sleep(for: .milliseconds(1300))
        try require(desktop.nativeCheckOverviewApplyCount == appliedBeforeDismiss, "Dismissal must not rebuild the hidden Overview")
        var churned = records(20)
        for revision in 1...10 {
            churned[0] = WindowRecord(id: churned[0].id, appIdentifier: churned[0].appIdentifier, appName: churned[0].appName,
                                      title: "Synthetic document 1 · revision \(revision)", frame: churned[0].frame)
            service.nativeCheckInstall(Array(churned[1...]) + [churned[0]])
        }
        try require(desktop.nativeCheckOverviewApplyCount == appliedBeforeDismiss, "Hidden registry changes must not run synchronously")
        try await Task.sleep(for: .milliseconds(1300))
        let coalesced = desktop.nativeCheckOverviewApplyCount - appliedBeforeDismiss
        try require(coalesced == 1, "Ten hidden registry changes must coalesce into one diff, ran \(coalesced)")

        // Cards are reused across sessions even when the MRU order changes.
        desktop.present(mode: .switcher, fromShortcut: true)
        await settle()
        try require(desktop.nativeCheckCard(for: reusedID) === reusedCard, "A surviving window must keep its card view")
        desktop.dismiss(restorePreviousApplication: false)

        // A change pending at open is applied before the Overview shows.
        churned[0] = WindowRecord(id: churned[0].id, appIdentifier: churned[0].appIdentifier, appName: churned[0].appName,
                                  title: "Synthetic document 1 · applied on open", frame: churned[0].frame)
        service.nativeCheckInstall(churned)
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        try require(desktop.nativeCheckCard(for: churned[0].id)?.record?.title == "Synthetic document 1 · applied on open",
                    "Opening the Overview must apply a pending registry change")
        try require(desktop.nativeCheckOverviewWindow.frame == overviewFrame, "The Overview panel must not resize between opens")
        await settle()

        // Context menus exist only on request.
        guard let card = desktop.nativeCheckCard(for: churned[0].id) else { throw Failure.check("Missing Overview card") }
        try require(card.menu == nil, "Card menus must be built lazily")
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        try require(card.menu(for: rightClick)?.items.count == 3, "A right-click must build the slot menu")

        // A mouse-down outside the panel closes the Overview; the monitor exists only while it is visible.
        try require(desktop.nativeCheckOutsideClickMonitorInstalled && outsideMonitors == 1, "Visible Overview must install one outside-click monitor")
        let panelFrame = desktop.nativeCheckOverviewWindow.frame
        outsideClick?(NSPoint(x: panelFrame.midX, y: panelFrame.midY))
        try require(desktop.isOverviewVisible, "A mouse-down inside the panel must not dismiss the Overview")
        outsideClick?(NSPoint(x: panelFrame.minX - 40, y: panelFrame.minY - 40))
        try require(!desktop.isVisible, "A mouse-down outside the panel must dismiss the Overview")
        try require(!desktop.nativeCheckOutsideClickMonitorInstalled && outsideMonitors == 0, "Dismissal must remove the outside-click monitor")
        desktop.present(mode: .switcher, fromShortcut: true)
        try require(outsideMonitors == 0, "The switcher must not install the outside-click monitor")
        desktop.dismiss(restorePreviousApplication: false)
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()

        // Another application's activation dismisses the Overview; Paneflo's own does not.
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try require(desktop.isOverviewVisible, "Paneflo's own activation must not dismiss the Overview")
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw Failure.check("Missing a second running application for the activation fixture")
        }
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: other])
        try require(!desktop.isVisible, "Another application's activation must dismiss the Overview")
        try require(outsideMonitors == 0, "Every dismissal path must remove the outside-click monitor")
        await settle()
        print("PASS fast surfaces")
    }

    /// Synthetic, never-posted CGEvents go through the real tap callback and main-queue hop.
    /// No event tap is installed and no global input is observed or posted.
    @MainActor static func checkInputRouting(_ desktop: DesktopController) async throws {
        let input = GlobalShortcutService()
        var actions: [String] = []
        input.onAction = { action in
            switch action {
            case .switchForward: desktop.switchStep(backwards: false)
            case .switchBackward: desktop.switchStep(backwards: true)
            case .navigate(let direction): desktop.navigate(direction)
            case .navigateRow(let direction): desktop.navigateRow(direction)
            // Synthetic records belong to this process: record intents, never focus or move windows.
            case .commit: actions.append("commit"); if desktop.isVisible { desktop.dismiss(restorePreviousApplication: false) }
            case .cancel: actions.append("cancel"); if desktop.isVisible { desktop.dismiss(restorePreviousApplication: false) }
            case .tileSelected: actions.append("tileSelected")
            case .restore: actions.append("restore")
            case .overview: actions.append("overview")
            case .tile: actions.append("tile")
            }
        }
        desktop.onSurfaceVisibilityChanged = { input.surfaceVisible = $0 }
        desktop.onVisibilityChanged = { input.selectionContextActive = $0 }
        desktop.onCompositionChanged = { input.compositionActive = $0 }
        let overview = ShortcutChord(keyCode: 49, modifiers: [.control, .option])
        let tileLeft = ShortcutChord(keyCode: 123, modifiers: [.control, .option])
        input.nativeCheckAttach(configuration: .init(switcherEnabled: true, overview: overview, tiling: [tileLeft: .tile(.leftHalf)]))
        let command: CGEventFlags = .maskCommand
        let commandOption: CGEventFlags = [.maskCommand, .maskAlternate]

        // Held switcher: arrows select, Option–arrows arrange without moving the selection.
        try require(input.nativeCheckRoute(keyCode: 48, flags: command), "Command–Tab must be owned")
        await settle()
        try require(desktop.isVisible && !desktop.isOverviewVisible, "Command–Tab must open the switcher")
        let first = desktop.nativeCheckSelected
        try require(input.nativeCheckRoute(keyCode: 124, flags: command), "Command–Right must be owned while switching")
        await settle()
        let second = desktop.nativeCheckSelected
        try require(second != nil && second != first, "Command–Right must move the selection")
        input.nativeCheckRoute(keyCode: 124, down: false, flags: command)
        try require(input.nativeCheckRoute(keyCode: 123, flags: command), "Command–Left must be owned while switching")
        await settle()
        try require(desktop.nativeCheckSelected == first, "Command–Left must move the selection back")
        input.nativeCheckRoute(keyCode: 123, down: false, flags: command)
        try require(input.nativeCheckRoute(keyCode: 125, flags: command), "Command–Down must be owned while switching")
        await settle()
        try require(desktop.nativeCheckSelected != first, "Command–Down must move by a row when the picker wraps")
        input.nativeCheckRoute(keyCode: 125, down: false, flags: command)
        let beforeArrange = desktop.nativeCheckSelected
        try require(input.nativeCheckRoute(keyCode: 123, flags: commandOption), "Command–Option–Left must be owned")
        input.nativeCheckRoute(keyCode: 123, down: false, flags: commandOption)
        try require(input.nativeCheckRoute(keyCode: 125, flags: commandOption), "Command–Option–Down must be owned")
        await settle()
        try require(actions == ["tileSelected", "restore"], "Option–arrows must arrange and undo, got \(actions)")
        try require(desktop.isVisible && desktop.nativeCheckSelected == beforeArrange, "Arranging must keep the session and selection")
        input.nativeCheckRoute(keyCode: 125, down: false, flags: commandOption)

        // Missed Command release: the next key without Command commits and is not eaten.
        actions.removeAll()
        try require(!input.nativeCheckRoute(keyCode: 0), "A key after a missed release must pass through")
        await settle()
        try require(actions == ["commit"] && !desktop.isVisible, "A missed Command release must commit the session")

        // Visible but not key: Escape is still Paneflo's.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        await settle()
        try require(desktop.isOverviewVisible && !desktop.nativeCheckWindow.isKeyWindow, "Fixture needs a visible, non-key Overview")
        actions.removeAll()
        try require(input.nativeCheckRoute(keyCode: 53), "Escape must be owned while a surface is visible but not key")
        await settle()
        try require(actions == ["cancel"] && !desktop.isVisible, "Escape on a non-key Overview must close it")
        other.orderOut(nil)

        // A suppressed Escape is never discarded because the presentation changed meanwhile.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        try require(input.nativeCheckRoute(keyCode: 53), "Escape must be owned while Overview is visible")
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        try require(!desktop.isVisible, "Suppressed Escape must act even after a presentation change")
        try require(!input.nativeCheckRoute(keyCode: 53), "Escape must pass through when nothing is visible")

        // The IME exception: the first Escape belongs to the input method.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        guard let editor = desktop.nativeCheckSearch.currentEditor() as? NSTextView else { throw Failure.check("Missing search editor") }
        editor.setMarkedText("synthetic", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        try require(!input.nativeCheckRoute(keyCode: 53), "Escape during composition must go to the input method")
        input.nativeCheckRoute(keyCode: 53, down: false)
        editor.unmarkText()
        desktop.nativeCheckQuery("")
        await settle()
        try require(desktop.isVisible && input.nativeCheckRoute(keyCode: 53), "Escape after composition must be owned again")
        await settle()
        try require(!desktop.isVisible, "Escape after composition must close Overview")

        // Overview: Command–Option–arrows arrange and undo; Command–arrows select in the panel.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        actions.removeAll()
        try require(!input.nativeCheckRoute(keyCode: 123, flags: command), "Command–Left must not be a tap chord in Overview")
        try require(input.nativeCheckRoute(keyCode: 124, flags: commandOption), "Command–Option–Right must be owned in a focused Overview")
        input.nativeCheckRoute(keyCode: 124, down: false, flags: commandOption)
        try require(input.nativeCheckRoute(keyCode: 125, flags: commandOption), "Command–Option–Down must be owned in a focused Overview")
        input.nativeCheckRoute(keyCode: 125, down: false, flags: commandOption)
        await settle()
        try require(actions == ["tileSelected", "restore"], "Overview arranging must tile and undo, got \(actions)")
        let overviewSelected = desktop.nativeCheckSelected
        let commandRight = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        NSApp.sendEvent(commandRight)
        try require(desktop.isOverviewVisible && desktop.nativeCheckSelected != overviewSelected, "Command–Right must select in Overview")
        desktop.dismiss(restorePreviousApplication: false)
        await settle()

        // No expiry: actions delayed by a blocked main thread are still delivered.
        actions.removeAll()
        try require(input.nativeCheckRoute(keyCode: 49, flags: [.maskControl, .maskAlternate]), "Overview chord must be owned")
        try require(input.nativeCheckRoute(keyCode: 123, flags: [.maskControl, .maskAlternate]), "Tiling chord must be owned")
        usleep(350_000) // Deliberately block main past the old 250 ms expiry.
        await settle()
        try require(actions == ["overview", "tile"], "Delayed standalone actions must still be delivered, got \(actions)")
        input.stop()
        desktop.onSurfaceVisibilityChanged = nil
        desktop.onCompositionChanged = nil
    }
}
