import AppKit
import PanefloCore
import Darwin
import CoreVideo

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
        try await checkPreviews(desktop, service: service, records: records)
        try await checkDesktopEntry(desktop, service: service, records: records)
        try await checkLifecycle(desktop, service: service, records: records)
        service.nativeCheckInstall(records(20))
        await settle()
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
        var selectionOwned = false
        let hidePreviews = FakePreviews()
        desktop.previews = hidePreviews
        desktop.onVisibilityChanged = { selectionOwned = $0 }
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        guard let hideSelected = desktop.nativeCheckSelected else { throw Failure.check("Hide fixture needs a selection") }
        hidePreviews.deliverSnapshot(fixtureImage(.systemBlue), for: hideSelected)
        _ = hidePreviews.deliverLive(for: hideSelected)
        try require(desktop.nativeCheckPayloadCount > 0 && hidePreviews.visible && hidePreviews.liveStreamCount == 1 && selectionOwned,
                    "Hide fixture must begin with visible panel and synthetic preview")
        NSApp.hide(nil)
        await settle()
        try require(!desktop.isVisible && desktop.nativeCheckPayloadCount == 0 && hidePreviews.budget.counts.current == 0,
                    "Hiding app must dismiss panel and release preview payload")
        try require(!hidePreviews.visible && hidePreviews.liveStreamCount == 0 && !selectionOwned,
                    "Hiding app must release preview and keyboard ownership")
        desktop.previews = nil
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
        try await checkSetupAndMenuBar(desktop)
    }

    /// Writes a window's content view to a PNG in light appearance (readable on the transparent background).
    @MainActor static func snapshot(_ window: NSWindow?, _ name: String) async throws {
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()
        guard let window, let view = window.contentView else { return }
        let appearance = window.appearance
        window.appearance = NSAppearance(named: .aqua)
        defer { window.appearance = appearance }
        // Let row crossfades and step transitions finish first.
        try? await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        }
    }

    /// Every label, title and value the view exposes to VoiceOver: proof that SwiftUI built the content, and that it
    /// is labelled.
    @MainActor static func accessibilityTexts(_ element: Any, depth: Int = 0) -> [String] {
        // SwiftUI's accessibility nodes implement the informal NSAccessibility methods without the Swift protocol.
        guard depth < 40, let object = element as? NSObject else { return [] }
        func read(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var texts: [String] = []
        for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            if let text = read(key) as? String, !text.isEmpty { texts.append(text) }
        }
        for child in read("accessibilityChildren") as? [Any] ?? [] { texts += accessibilityTexts(child, depth: depth + 1) }
        return texts
    }

    /// The setup window's four steps with injected permission readings (never real TCC), Settings panes and permission
    /// rows, the menu per state, the icon images, and the hide/show menu-bar icon round trip on a throwaway defaults
    /// suite without a real status item.
    @MainActor static func checkSetupAndMenuBar(_ desktop: DesktopController) async throws {
        print("START setup and menu bar")
        let setup = SetupWindowController()
        var polls = 0, restarts = 0, resets = 0
        var granted: [SetupPermission] = []
        var gestureToggles: [Bool] = []
        var openedSettings: [SettingsPane?] = []
        setup.pollInterval = 0.05
        setup.onPoll = { polls += 1 }
        setup.onGrant = { granted.append($0) }
        setup.onRestart = { restarts += 1 }
        setup.onReset = { resets += 1 }
        setup.onToggleGesture = { gestureToggles.append($0) }
        setup.onOpenSettings = { openedSettings.append($0) }
        let intent = SetupIntent(shortcuts: true, gesture: false, previews: true)
        func state(_ ax: Bool, _ im: Bool, _ sr: Bool) -> PermissionState {
            PermissionState(accessibility: ax, inputMonitoring: im, screenRecording: sr)
        }
        var model = SetupModel(permissions: state(false, false, false), intent: intent)
        try require(model.showsAtLaunch(alreadyShownThisLaunch: false) && !model.showsAtLaunch(alreadyShownThisLaunch: true),
                    "Setup must show at most once per launch while required permissions are missing")
        setup.update(model)
        try require(!setup.isPolling, "Setup must not poll before it is shown")
        setup.show()
        await settle()
        try require(setup.isVisible && setup.isPolling && polls >= 2, "Setup must poll about once per interval while visible, polled \(polls)")
        try require(setup.step == .permissions && setup.nativeCheckHeadline == "Give Paneflo access",
                    "Setup opened because something is missing must start on the permissions step")
        try require(setup.nativeCheckWindow?.frame.size.width == 600, "Setup is a fixed 600 pt wide window")
        var rows = setup.nativeCheckRows
        try require(rows.map(\.title) == ["Accessibility", "Input Monitoring", "Screen Recording"], "Setup must list the three permissions in order")
        try require(rows.map(\.tag) == ["Required", "Required", "Optional"], "Screen Recording must be the only optional row")
        try require(rows.allSatisfy { $0.status == "Off" && $0.grantVisible }, "Missing permissions must read Off with a Grant button")
        try require(!setup.nativeCheckRestartVisible && !setup.nativeCheckStaleHintVisible, "A fresh setup offers no restart or reset hint")
        try require(setup.nativeCheckPrimaryTitle == "Continue" && !setup.nativeCheckPrimaryEnabled && setup.nativeCheckSecondaryTitle == "Later",
                    "Continue waits for the required permissions, with Later beside it")
        setup.nativeCheckPressPrimary()
        try require(setup.step == .permissions, "A disabled Continue must not leave the permissions step")
        let axTexts = accessibilityTexts(setup.nativeCheckWindow?.contentView as Any)
        try require(axTexts.contains { $0.contains("Accessibility") } && axTexts.contains("Step 2 of 4"),
                    "Setup rows and the step indicator must be labelled for VoiceOver, saw \(axTexts.prefix(12))")
        setup.nativeCheckPressGrant(.inputMonitoring)
        try require(granted == [.inputMonitoring], "Grant must report its permission")

        model.permissions = state(true, false, false)
        model.requested = [.accessibility, .inputMonitoring]
        setup.update(model)
        rows = setup.nativeCheckRows
        try require(rows[0].status == "On" && !rows[0].grantVisible, "A granted row turns On and hides Grant")
        try require(rows[1].status.contains("Restart") && setup.nativeCheckRestartVisible && setup.nativeCheckPrimaryTitle == "Restart Paneflo",
                    "Input Monitoring asked for but still off must offer Restart Paneflo as the primary button")
        await settle()
        try await snapshot(setup.nativeCheckWindow, "native-setup.png")
        setup.nativeCheckPressRestart()
        try require(restarts == 1, "Restart Paneflo must reach the app")

        model = SetupModel(permissions: state(true, false, false), intent: intent, missingBeforeRelaunch: [.inputMonitoring])
        setup.update(model)
        try require(setup.nativeCheckStaleHintVisible && !setup.nativeCheckRestartVisible,
                    "Still off after a restart must show the stale-entry hint instead of another restart")
        await settle()
        try await snapshot(setup.nativeCheckWindow, "native-setup-stuck.png")
        setup.nativeCheckPressReset()
        try require(resets == 1, "Reset and grant again must reach the app")

        model = SetupModel(permissions: state(true, true, false), intent: intent)
        setup.update(model)
        rows = setup.nativeCheckRows
        try require(rows[1].status == "On" && rows[2].status == "Off" && setup.nativeCheckPrimaryEnabled
                    && setup.nativeCheckPrimaryTitle == "Continue" && setup.nativeCheckSecondaryTitle == nil,
                    "Required permissions on must enable Continue")
        try require(!setup.nativeCheckRestartVisible && !setup.nativeCheckStaleHintVisible, "A complete setup hides restart and reset hints")
        // Permissions → Gesture → Done, with Back.
        setup.nativeCheckPressPrimary()
        await settle()
        try require(setup.step == .gesture && setup.nativeCheckHeadline == "Swipe up for Overview" && setup.nativeCheckSecondaryTitle == "Skip",
                    "Continue must move to the optional gesture step")
        try await snapshot(setup.nativeCheckWindow, "native-setup-gesture.png")
        setup.nativeCheckToggleGesture(true)
        try require(gestureToggles == [true], "The gesture toggle writes the same choice as Settings")
        setup.nativeCheckPressSecondary()
        await settle()
        try require(setup.step == .done && setup.nativeCheckHeadline == "You’re set" && setup.nativeCheckPrimaryTitle == "Done"
                    && setup.nativeCheckSecondaryTitle == "Open Settings", "Skip must reach the done step")
        try require(setup.nativeCheckChecklist == ["⌘Tab switcher on", "Tiling shortcuts on", "Gesture off"],
                    "The done step summarises what actually runs")
        try await snapshot(setup.nativeCheckWindow, "native-setup-done.png")
        setup.nativeCheckPressBack()
        try require(setup.step == .gesture && setup.nativeCheckShowsBack, "Back returns one step")
        setup.nativeCheckPressPrimary()
        setup.nativeCheckPressSecondary()
        await settle()
        try require(openedSettings.count == 1 && openedSettings[0] == nil && !setup.isVisible,
                    "Open Settings closes setup and opens Settings")
        setup.show(step: .welcome)
        await settle()
        try require(setup.nativeCheckHeadline == "Welcome to Paneflo" && !setup.nativeCheckShowsBack && setup.nativeCheckPrimaryTitle == "Get Started",
                    "A first run opens on Welcome")
        try await snapshot(setup.nativeCheckWindow, "native-setup-welcome.png")
        setup.nativeCheckPressPrimary()
        try require(setup.step == .permissions, "Get Started moves to permissions")
        setup.show()
        try require(setup.step == .permissions, "Showing a visible setup window keeps its step")
        setup.close()
        await settle()
        let pollsAfterClose = polls
        try await Task.sleep(for: .milliseconds(250))
        try require(!setup.isVisible && !setup.isPolling && polls == pollsAfterClose, "Setup must stop polling once hidden")
        setup.show()
        try require(setup.step == .permissions, "Reopening setup while incomplete starts on permissions")
        setup.close()

        // Settings: permission rows, every pane, live polling while visible, the shortcuts toggle path.
        let settings = desktop.settingsController
        settings.setSetupModel(model)
        try require(settings.nativeCheckPermissionStatus(.accessibility) == "On"
                    && settings.nativeCheckPermissionStatus(.screenRecording) == "Off" && !settings.model.setupNeeded,
                    "Settings must show permission status inline")
        settings.setSetupModel(SetupModel(permissions: state(false, false, false), intent: intent))
        try require(settings.model.setupNeeded, "Missing required permissions must badge Settings › Permissions")
        for pane in SettingsPane.allCases {
            settings.show(pane: pane)
            await settle()
            try require(settings.model.pane == pane && settings.isVisible, "Settings must open on \(pane.title)")
            let texts = accessibilityTexts(settings.nativeCheckWindow?.contentView as Any)
            let marker = pane == .about ? "Every window. In its place." : pane.summary
            try require(texts.contains { $0.contains(marker) }, "The \(pane.title) pane must build, saw \(texts.prefix(8))")
            if pane == .help {
                try require(texts.contains("Close the selected window") && texts.contains("Open or close Overview"),
                            "Shortcuts & Help lists the switcher and Overview keys")
            }
            if pane == .tiling {
                try require(texts.contains("Raise tile pairs together"), "The Tiling pane offers Raise tile pairs together")
            }
            try await snapshot(settings.nativeCheckWindow, "native-settings-\(pane.rawValue).png")
        }
        try require(HelpContent.filtered("quit").flatMap(\.entries).map(\.text) == ["Quit its app (never Finder)"]
                    && HelpContent.filtered("control option z").first?.title == "Tiling" && HelpContent.filtered("zzz-none").isEmpty,
                    "Shortcuts & Help search matches descriptions and spoken key names")
        try require(settings.nativeCheckIsPolling, "Settings must refresh permissions while visible")
        try require(UserDefaults.standard.string(forKey: SettingsWindowController.lastPaneKey) == SettingsPane.allCases.last?.rawValue,
                    "Settings must remember the last pane")
        settings.setSetupModel(model)
        let previousToggle = settings.onToggleShortcuts
        var toggled: [Bool] = []
        settings.onToggleShortcuts = { toggled.append($0) }
        settings.nativeCheckPerform(.toggleShortcuts(false))
        try require(toggled == [false] && !settings.model.shortcutsWanted, "Use Paneflo shortcuts must reach the app")
        settings.nativeCheckPerform(.toggleShortcuts(true))
        settings.onToggleShortcuts = previousToggle

        // Menu per state, with symbols and key equivalents.
        let suite = "org.paneflo.NativeUICheck.menu.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.check("No throwaway defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SetupPreferences(defaults: defaults)
        let menu = StatusMenuController(preferences: preferences)
        let common = ["Switch Windows…", "Arrange Windows…", "Overview", "Pause Shortcuts", "Refresh Window List",
                      "Settings…", "Check for Updates…", "About Paneflo", "Quit Paneflo"]
        menu.update(status: .setupNeeded, shortcutsWanted: true)
        var titles = menu.nativeCheckMenuTitles()
        try require(titles == ["Setup needed", "Finish Setup…"] + common, "Setup-needed menu, saw \(titles)")
        try require(menu.iconState == .setupNeeded, "Setup needed badges the icon")
        menu.update(status: .ready, shortcutsWanted: true)
        titles = menu.nativeCheckMenuTitles()
        try require(titles == ["⌘Tab is ready"] + common, "Ready menu, saw \(titles)")
        try require(menu.iconState == .normal, "Ready shows the plain icon")
        menu.update(status: .paused, shortcutsWanted: false)
        titles = menu.nativeCheckMenuTitles()
        try require(titles.first == "Shortcuts paused" && titles.contains("Resume Shortcuts") && !titles.contains("Pause Shortcuts"),
                    "Paused menu offers Resume Shortcuts, saw \(titles)")
        try require(menu.iconState == .paused, "Paused dims the icon")
        let keys = menu.nativeCheckMenuKeys()
        try require(keys["Settings…"].map { $0.0 == "," && $0.1 == .command } == true
                    && keys["Quit Paneflo"].map { $0.0 == "q" && $0.1 == .command } == true
                    && keys["Switch Windows…"].map { $0.0 == "\t" && $0.1 == .command } == true
                    && keys["Overview"].map { $0.0 == " " && $0.1 == [.control, .option] } == true,
                    "Menu key equivalents must match the spec")
        try require(menu.nativeCheckItemsWithoutSymbol.isEmpty, "Every actionable menu item has a symbol: \(menu.nativeCheckItemsWithoutSymbol)")
        try require(!titles.contains("Developer"), "Developer fixtures stay out of the normal menu")
        menu.showsDeveloperFixtures = true
        try require(menu.nativeCheckMenuTitles().contains("Developer") && menu.nativeCheckDeveloperTitles == ["Synthetic Developer Fixtures"],
                    "Diagnostics builds add the Developer submenu")
        menu.showsDeveloperFixtures = false

        // Icon images: 18 pt, template except the badge, drawn at 1x and 2x.
        for iconState in [MenuBarIcon.State.normal, .setupNeeded, .paused] {
            let image = MenuBarIcon.image(iconState)
            try require(image.size == NSSize(width: 18, height: 18) && image.isTemplate == (iconState != .setupNeeded),
                        "Menu bar icon \(iconState) must be an 18 pt \(iconState == .setupNeeded ? "badged" : "template") image")
            for scale in [1, 2] {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18 * scale, pixelsHigh: 18 * scale,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                bitmap.size = NSSize(width: 18, height: 18)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                NSGraphicsContext.restoreGraphicsState()
                var opaque = 0, orange = 0
                for x in 0..<(18 * scale) { for y in 0..<(18 * scale) {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    if color.alphaComponent > 0.3 { opaque += 1 }
                    if color.redComponent > 0.8, color.greenComponent > 0.4, color.greenComponent < 0.75, color.blueComponent < 0.3 { orange += 1 }
                } }
                try require(opaque > 20 * scale * scale, "Menu bar icon \(iconState) must draw at \(scale)x")
                try require((orange > 0) == (iconState == .setupNeeded), "Only the setup-needed icon carries the orange dot (\(iconState) \(scale)x)")
                if iconState == .setupNeeded, scale == 2 {
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
                            .appendingPathComponent("native-menubar-icon-setup@2x.png"))
                }
            }
        }

        // Hide/show round trip: Settings asks (a sheet), the menu persists it, Settings mirrors it.
        @MainActor final class HideAnswer { var confirm = false; var count = 0 }
        let answer = HideAnswer()
        let sheetConfirm = settings.confirmHideIcon
        settings.confirmHideIcon = { reply in answer.count += 1; reply(answer.confirm) }
        menu.onIconVisibilityChanged = { settings.setMenuBarIconVisible($0) }
        let previousIcon = settings.onToggleMenuBarIcon
        settings.onToggleMenuBarIcon = { menu.setIconVisible($0) }
        settings.setMenuBarIconVisible(true)
        settings.nativeCheckPerform(.setMenuBarIcon(false))
        try require(answer.count == 1 && menu.isIconVisible && !preferences.menuBarIconHidden && settings.model.menuBarIconVisible,
                    "Cancelling the hide confirmation must keep the icon and the toggle")
        answer.confirm = true
        settings.nativeCheckPerform(.setMenuBarIcon(false))
        try require(answer.count == 2 && !menu.isIconVisible && !settings.model.menuBarIconVisible,
                    "Confirming must hide the icon and clear Show menu bar icon")
        try require(SetupPreferences(defaults: defaults).menuBarIconHidden && !StatusMenuController(preferences: SetupPreferences(defaults: defaults)).isIconVisible,
                    "The hidden icon must persist across launches")
        settings.nativeCheckPerform(.setMenuBarIcon(true))
        try require(answer.count == 2 && menu.isIconVisible && !SetupPreferences(defaults: defaults).menuBarIconHidden
                    && settings.model.menuBarIconVisible, "Show menu bar icon must bring it back without asking")
        // The real confirmation is a sheet on Settings, not an app-modal alert.
        settings.confirmHideIcon = sheetConfirm
        settings.show(pane: .general)
        await settle()
        settings.nativeCheckPerform(.setMenuBarIcon(false))
        await settle()
        guard let window = settings.nativeCheckWindow, let sheet = window.attachedSheet else {
            throw Failure.check("Hiding the icon must ask in a sheet on Settings")
        }
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await settle()
        try require(menu.isIconVisible && settings.model.menuBarIconVisible, "Cancel in the sheet keeps the icon")
        settings.onToggleMenuBarIcon = previousIcon
        try await snapshot(settings.nativeCheckWindow, "native-settings.png")
        settings.nativeCheckWindow?.close()
        await settle()
        try require(!settings.nativeCheckIsPolling, "Settings must stop polling once closed")
        print("setup rows=\(rows.map(\.status)) polls=\(polls)")
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

    // MARK: Previews

    /// An injected preview backend. It follows the engine's card contract (emit each visible card
    /// once per session, live frames only for the visible selection, nothing while hidden) on the
    /// real Core cache and presentation types, and lets the check deliver updates deterministically.
    @MainActor final class FakePreviews: PreviewProvider {
        var onPreview: ((PreviewUpdate) -> Void)?
        var cache = ThumbnailCache<CGImage>()
        let budget = LiveFrameBudget()
        private(set) var visible = false
        private(set) var cards: [PreviewCard] = []
        private(set) var selected: WindowIdentity?
        private(set) var pixelSize: CGSize?
        private(set) var hiddenCalls = 0
        private var emitted: Set<WindowIdentity> = []
        private var liveID: WindowIdentity?
        /// At most one stream, only while visible, only for the selection.
        var liveStreamCount: Int { visible && liveID != nil ? 1 : 0 }

        func updateSurface(visible: Bool, cards: [PreviewCard], selected: WindowIdentity?, previewPixelSize: CGSize?) {
            guard visible else {
                self.visible = false; self.cards = []; self.selected = nil; liveID = nil; emitted.removeAll()
                hiddenCalls += 1
                return
            }
            if !self.visible { self.visible = true; emitted.removeAll() }
            self.cards = cards
            self.selected = selected
            if let previewPixelSize { pixelSize = previewPixelSize }
            for card in cards where !emitted.contains(card.id) { emitted.insert(card.id); onPreview?(preview(for: card)) }
            if let live = liveID, live != selected {
                liveID = nil
                onPreview?(PreviewUpdate(id: live, content: .keep,
                                         presentation: .snapshot(capturedAt: ProcessInfo.processInfo.systemUptime, note: nil)))
            }
        }

        func preview(for card: PreviewCard) -> PreviewUpdate {
            let entry = cache.entry(for: card.id, windowNumber: card.windowNumber)
            let presentation = PreviewAvailability.presentation(cachedAt: entry?.capturedAt,
                unavailable: card.isMinimized ? .minimized : nil, paused: nil, live: false)
            return PreviewUpdate(id: card.id, content: entry.map { .snapshot($0.payload) } ?? .none, presentation: presentation)
        }

        /// A completed one-shot capture: cached even when the card is not visible.
        func deliverSnapshot(_ image: CGImage, for id: WindowIdentity) {
            let bytes = ThumbnailCache<CGImage>.payloadBytes(bytesPerRow: image.bytesPerRow, height: image.height) ?? 1
            _ = cache.insert(id: id, windowNumber: id.number, payload: image, bytes: bytes,
                             capturedAt: ProcessInfo.processInfo.systemUptime)
            guard visible, cards.contains(where: { $0.id == id }) else { return }
            onPreview?(PreviewUpdate(id: id, content: .snapshot(image),
                                     presentation: .snapshot(capturedAt: ProcessInfo.processInfo.systemUptime, note: nil)))
        }

        /// Ignores the session rules, as a late or misrouted delivery would.
        func forceDeliver(_ update: PreviewUpdate) { onPreview?(update) }

        /// One live frame for the visible selection; nil (no stream) otherwise.
        func deliverLive(for id: WindowIdentity) -> LiveFrame? {
            guard visible, id == selected, let frame = LiveFrame.nativeCheck(buffer: makePixelBuffer(), budget: budget) else { return nil }
            liveID = id
            onPreview?(PreviewUpdate(id: id, content: .live(frame), presentation: .live))
            return frame
        }
    }

    /// Renders the panel's layer tree (card layers included, which view caching skips) to a PNG.
    @MainActor static func writeLayerPNG(_ window: NSWindow, name: String) {
        let output = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory()
        guard let view = window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }

    static func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 10, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return buffer!
    }

    @MainActor static func fixtureImage(_ color: NSColor) -> CGImage {
        let context = CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        return context.makeImage()!
    }

    /// Wiring between the surfaces and an injected preview backend: snapshot and live updates
    /// reach exactly the affected card, labels show, dismissal leaves zero streams and no pixels,
    /// and the cache that survives dismissal paints snapshots synchronously on reopen.
    @MainActor static func checkPreviews(_ desktop: DesktopController, service: WindowService,
                                         records: (Int) -> [WindowRecord]) async throws {
        print("START previews")
        let previews = FakePreviews()
        desktop.previews = previews
        try require(previews.onPreview != nil, "Attaching previews must subscribe to updates")
        service.nativeCheckInstall(records(20))
        await settle()

        // Open: visible cards, selection included, sized in backing pixels, honest loading labels.
        desktop.present(mode: .switcher, fromShortcut: true)
        guard let selected = desktop.nativeCheckSelected, let selectedCard = desktop.nativeCheckCard(for: selected) else {
            throw Failure.check("Missing switcher selection")
        }
        try require(previews.visible && previews.selected == selected && previews.cards.contains { $0.id == selected },
                    "Open must report the visible cards including the selection")
        let scale = desktop.nativeCheckSwitcherWindow.backingScaleFactor
        let area = selectedCard.previewRect.size
        try require(previews.pixelSize == CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded()),
                    "Preview pixel size must be the card preview area at backing scale, got \(String(describing: previews.pixelSize))")
        try require(previews.cards.allSatisfy { desktop.nativeCheckCard(for: $0.id)?.nativeCheckStatusText == "Loading preview…" },
                    "Uncached cards must be labelled as loading")
        await settle()

        // Snapshots replace the icon layer and update only their card's layers: no card redraws.
        guard let other = previews.cards.first(where: { $0.id != selected })?.id, let otherCard = desktop.nativeCheckCard(for: other) else {
            throw Failure.check("Missing a second visible card")
        }
        let firstImage = fixtureImage(.systemOrange), secondImage = fixtureImage(.systemTeal)
        CardView.invalidations = 0
        previews.deliverSnapshot(firstImage, for: other)
        try require(CardView.invalidations == 0 && otherCard.nativeCheckLayerContents === firstImage,
                    "A first snapshot must reach its card without redrawing any card, redrew \(CardView.invalidations)")
        try require(previews.cards.filter { $0.id != other }.allSatisfy { desktop.nativeCheckCard(for: $0.id)?.pixels.hasContent == false },
                    "A snapshot must reach only its own card")
        try require(otherCard.nativeCheckStatusText?.hasPrefix("Snapshot · ") == true && !otherCard.nativeCheckLiveDotVisible,
                    "A snapshot must be labelled with its age, got \(otherCard.nativeCheckStatusText ?? "nil")")
        CardView.invalidations = 0
        previews.deliverSnapshot(secondImage, for: other)
        try require(CardView.invalidations == 0 && otherCard.nativeCheckLayerContents === secondImage,
                    "A refreshed snapshot must update the layer without redrawing cards")

        // Live: the layer samples the frame's IOSurface; frames after the first redraw nothing.
        CardView.invalidations = 0
        do {
            guard let frame = previews.deliverLive(for: selected) else { throw Failure.check("Live frame was refused") }
            try require(selectedCard.nativeCheckLayerContents === frame.surface, "Live frames must be shown zero-copy")
            try require(selectedCard.nativeCheckStatusText == "Live" && selectedCard.nativeCheckLiveDotVisible,
                        "A live card must show the Live label and dot")
            try require(CardView.invalidations == 0 && previews.liveStreamCount == 1, "The first live frame must not redraw any card")
        }
        CardView.invalidations = 0
        _ = previews.deliverLive(for: selected)
        try require(CardView.invalidations == 0, "Live frames must never redraw cards")
        try require(previews.budget.counts.current == 1, "A card must release the live frame it replaced")
        try require(previews.deliverLive(for: other) == nil, "Only the selection may stream")
        writeLayerPNG(desktop.nativeCheckSwitcherWindow, name: "native-previews.png")

        // Tab with previews attached: still two redraws; the outgoing card keeps its last frame as a snapshot.
        CardView.invalidations = 0
        desktop.switchStep(backwards: false)
        try require(CardView.invalidations == 2, "A Tab step with previews must redraw exactly two cards, redrew \(CardView.invalidations)")
        try require(previews.selected == desktop.nativeCheckSelected && previews.liveStreamCount == 0,
                    "A selection change must move the single stream")
        try require(selectedCard.pixels.hasContent && selectedCard.nativeCheckStatusText?.hasPrefix("Snapshot · ") == true
                    && !selectedCard.nativeCheckLiveDotVisible, "The outgoing card must keep its last frame, labelled as a snapshot")

        // Dismiss: hidden, zero streams, no pixels, no frames, no labels.
        desktop.dismiss(restorePreviousApplication: false)
        try require(!previews.visible && previews.liveStreamCount == 0, "Dismissal must leave zero live streams")
        try require(desktop.nativeCheckPayloadCount == 0 && desktop.nativeCheckLabelledCount == 0 && previews.budget.counts.current == 0,
                    "Dismissal must release every preview pixel, frame and label")
        previews.forceDeliver(PreviewUpdate(id: other, content: .snapshot(firstImage), presentation: .live))
        try require(desktop.nativeCheckPayloadCount == 0, "Updates after dismissal must be dropped")

        // Reopen: the surviving cache paints synchronously, before the next run-loop turn.
        desktop.present(mode: .switcher, fromShortcut: true)
        guard let reopened = desktop.nativeCheckCard(for: other) else { throw Failure.check("Missing reopened card") }
        try require(reopened.nativeCheckLayerContents === secondImage && reopened.nativeCheckStatusText?.hasPrefix("Snapshot · ") == true,
                    "Reopening must show the cached snapshot instantly")
        desktop.dismiss(restorePreviousApplication: false)

        // A card view rebuilt mid-session (search) asks the engine for its current state.
        desktop.present(mode: .switcher)
        await settle()
        let cachedID = other
        desktop.nativeCheckQuery("a query with no synthetic match 987654")
        try require(desktop.nativeCheckCard(for: cachedID) == nil && previews.cards.isEmpty, "A no-match search must report no cards")
        desktop.nativeCheckQuery("")
        try require(desktop.nativeCheckCard(for: cachedID)?.nativeCheckLayerContents === secondImage,
                    "A card rebuilt mid-session must show the engine's current snapshot")
        desktop.dismiss(restorePreviousApplication: false)
        await settle()

        // Overview: only cards in the viewport (plus margin) are reported; dimmed search misses are not.
        service.nativeCheckInstall(records(100))
        await settle()
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let viewport = desktop.nativeCheckViewport.insetBy(dx: 0, dy: -desktop.nativeCheckCardHeight / 2)
        try require(previews.visible && !previews.cards.isEmpty && previews.cards.count < 100,
                    "The Overview must report only visible cards, reported \(previews.cards.count)")
        try require(previews.cards.allSatisfy { desktop.nativeCheckCard(for: $0.id)?.frame.intersects(viewport) == true },
                    "Reported Overview cards must lie in the viewport")
        desktop.nativeCheckQuery("document 12")
        try require(previews.cards.map(\.id.number) == [12], "Search must report only matching cards, got \(previews.cards.map(\.id.number))")
        desktop.nativeCheckQuery("")
        desktop.dismiss(restorePreviousApplication: false)

        // Arrange mode shows no previews; turning previews off detaches and clears.
        desktop.present(mode: .tiling)
        try require(!previews.visible, "Arrange mode must not report preview cards")
        desktop.dismiss(restorePreviousApplication: false)
        desktop.present(mode: .switcher, fromShortcut: true)
        try require(previews.visible, "Fixture needs a visible preview session")
        desktop.previews = nil
        try require(!previews.visible && previews.onPreview == nil && desktop.nativeCheckLabelledCount == 0 && desktop.nativeCheckPayloadCount == 0,
                    "Turning previews off must end the session and clear every card")
        desktop.dismiss(restorePreviousApplication: false)
        await settle()
        print("PASS previews")
    }

    // MARK: Desktop entry

    /// Stands in for the app's Show Desktop service: records intents, never hides an app or focuses a window.
    @MainActor final class FakeDesktopEntry: DesktopEntryProvider {
        var showsDesktopEntry = true
        var isDesktopShown = false
        var wallpaper: CGImage?
        private(set) var activations = 0
        private(set) var focusPreparations: [pid_t] = []
        private(set) var refreshRequests = 0
        private(set) var screenChanges = 0
        func activateDesktopEntry() { activations += 1 }
        /// Records the restore-before-focus step; the synthetic windows are never focused.
        func prepareToFocus(pid: pid_t, then focus: @escaping @MainActor () -> Void) { focusPreparations.append(pid) }
        func cachedWallpaper(for screen: NSScreen) -> CGImage? { wallpaper }
        func refreshWallpaper(for screen: NSScreen, completion: @escaping @MainActor (CGImage?) -> Void) { refreshRequests += 1 }
        func screensChanged() { screenChanges += 1 }
    }

    @MainActor static func key(_ desktop: DesktopController, code: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// The Desktop card in the switcher loop and the Overview home tile, against a fake Desktop service.
    @MainActor static func checkDesktopEntry(_ desktop: DesktopController, service: WindowService,
                                             records: (Int) -> [WindowRecord]) async throws {
        print("START desktop entry")
        let fake = FakeDesktopEntry()
        fake.wallpaper = fixtureImage(.systemPurple)
        let previews = FakePreviews()
        desktop.previews = previews
        desktop.desktopEntry = fake
        let windows = records(20)
        service.nativeCheckInstall(windows)
        await settle()

        // Trailing: the Desktop is the last stop; the loop starts on the second window as before.
        desktop.present(mode: .switcher, fromShortcut: true)
        let loop = desktop.nativeCheckSwitcherTargets
        try require(loop.count == 21 && loop.last == .desktop && loop.filter({ $0 == .desktop }).count == 1,
                    "The Desktop must be the last of 21 switcher stops, got \(loop.count)")
        try require(desktop.nativeCheckSelectedTarget == loop[1], "The held switcher must still start on the second stop")
        guard let card = desktop.nativeCheckDesktopCard, card.isDesktopEntry, card.record == nil else {
            throw Failure.check("Missing the Desktop card")
        }
        try require(card.nativeCheckLayerContents === fake.wallpaper && card.nativeCheckStatusText == "Wallpaper"
                    && !card.nativeCheckLiveDotVisible && card.previewLabel != "Live",
                    "The Desktop card must show the wallpaper labelled Wallpaper, never Live")
        try require(fake.refreshRequests > 0, "Presenting must ask for a wallpaper refresh off the input path")
        try require(previews.cards.allSatisfy { id in windows.contains { $0.id == id.id } } && previews.cards.count <= 20,
                    "Only window cards may reach the capture engine")

        // Tab onto the Desktop and back: two card redraws per step, no live stream for the Desktop.
        CardView.invalidations = 0
        desktop.switchStep(backwards: true)
        try require(desktop.nativeCheckSelectedTarget == .window(windows[0].id), "Shift-Tab from the second stop must reach the first")
        try require(CardView.invalidations == 2, "A step must redraw two cards, redrew \(CardView.invalidations)")
        CardView.invalidations = 0
        desktop.switchStep(backwards: true)
        try require(desktop.nativeCheckSelectedTarget == .desktop, "Shift-Tab from the first stop must wrap to the Desktop")
        try require(CardView.invalidations == 2, "Stepping onto the Desktop must redraw two cards, redrew \(CardView.invalidations)")
        try require(previews.visible && previews.selected == nil && previews.liveStreamCount == 0,
                    "The Desktop selection must never be sent to the capture engine as a live target")
        try require(card.selected && card.nativeCheckStatusText == "Wallpaper", "The selected Desktop card keeps its Wallpaper label")
        // Arranging the Desktop is a no-op: no badge, no failure text, the session continues.
        desktop.tileSelected(.leftHalf)
        try require(card.layoutBadge == nil && desktop.isVisible && desktop.nativeCheckSelectedTarget == .desktop,
                    "Command-Option arrows on the Desktop card must do nothing")
        desktop.commitShortcut()
        try require(fake.activations == 1 && !desktop.isVisible && fake.focusPreparations.isEmpty,
                    "Committing the Desktop must run the Desktop action and nothing else")
        try require(desktop.nativeCheckPayloadCount == 0, "Dismissal must release the wallpaper too")

        // A window commit asks the Desktop service to restore that window's app before focusing.
        desktop.present(mode: .switcher, fromShortcut: true)
        let chosen = desktop.nativeCheckSelected
        desktop.commitShortcut()
        try require(chosen != nil && fake.focusPreparations == [chosen!.process.pid] && fake.activations == 1,
                    "Committing a window must restore its app before focusing")

        // Current: the desktop was just shown. Desktop sits at index 1; release returns to the window left behind.
        fake.isDesktopShown = true
        desktop.desktopStateChanged()
        desktop.present(mode: .switcher, fromShortcut: true)
        let current = desktop.nativeCheckSwitcherTargets
        try require(current.count == 21 && current[1] == .desktop && desktop.nativeCheckSelectedTarget == current[0],
                    "With the desktop current, the Desktop must be stop 2 and the selection the first window")
        try require(desktop.nativeCheckDesktopCard?.desktopIsCurrent == true, "The Desktop card must offer to bring windows back")
        desktop.switchStep(backwards: false)
        try require(desktop.nativeCheckSelectedTarget == .desktop, "One step must reach the Desktop when it is current")
        desktop.dismiss(restorePreviousApplication: false)
        fake.isDesktopShown = false
        desktop.desktopStateChanged()

        // Search in a manual switcher matches "desktop"; Return chooses it.
        desktop.present(mode: .switcher)
        await settle()
        desktop.nativeCheckQuery("desk")
        try require(desktop.nativeCheckSwitcherTargets == [.desktop] && desktop.nativeCheckSelectedTarget == .desktop,
                    "Searching desk must leave only the Desktop, selected")
        try require(desktop.nativeCheckDesktopCard?.nativeCheckLayerContents === fake.wallpaper,
                    "A Desktop card rebuilt by search must show the wallpaper")
        NSApp.sendEvent(key(desktop, code: 36, characters: "\r"))
        try require(fake.activations == 2 && !desktop.isVisible, "Return on the Desktop must run the Desktop action")
        desktop.present(mode: .tiling)
        try require(!desktop.nativeCheckSwitcherTargets.contains(.desktop), "Arrange lists windows only")
        desktop.dismiss(restorePreviousApplication: false)
        await settle()

        // Overview: a fixed home tile before the slots; slot order untouched; arrows, click and Return.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let slots = desktop.nativeCheckSlots
        try require(desktop.nativeCheckCards.count == slots.count + 1,
                    "The home tile must stay outside the slot store, got \(slots.count) slots for \(desktop.nativeCheckCards.count) cards")
        guard let tile = desktop.nativeCheckCards.first, tile.isDesktopEntry, tile === desktop.nativeCheckDesktopCard else {
            throw Failure.check("The Overview must start with the Desktop home tile")
        }
        try require(desktop.nativeCheckSelected != nil, "The Overview must open on a window, not the tile")
        guard let firstWindow = slots.compactMap({ $0 }).first(where: { id in windows.contains { $0.id == id } }) else {
            throw Failure.check("Missing a bound Overview slot")
        }
        desktop.nativeCheckSelect(.window(firstWindow))
        try require(tile.nativeCheckLayerContents === fake.wallpaper, "The home tile must show the wallpaper")
        CardView.invalidations = 0
        desktop.navigate(.backward)
        try require(desktop.nativeCheckSelectedTarget == .desktop && CardView.invalidations == 2,
                    "Left from the first window must select the home tile with two redraws, redrew \(CardView.invalidations)")
        try require(previews.selected == nil && previews.liveStreamCount == 0, "The home tile must never stream")
        desktop.navigate(.forward)
        try require(desktop.nativeCheckSelected == firstWindow, "Right from the tile must return to the first window")
        desktop.navigateRow(.forward); desktop.navigateRow(.backward)
        try require(desktop.nativeCheckSelectedTarget != nil, "Row navigation must keep a selection with the tile present")
        _ = tile.sendAction(tile.action, to: tile.target)
        try require(desktop.nativeCheckSelectedTarget == .desktop, "Clicking the home tile must select it")
        desktop.nativeCheckQuery("document 12")
        try require(!tile.matches && desktop.nativeCheckSelected?.number == 12, "A window search must dim the tile")
        desktop.nativeCheckQuery("desktop")
        try require(tile.matches && desktop.nativeCheckSelectedTarget == .desktop, "Searching desktop must select the tile")
        try require(desktop.nativeCheckSlots == slots, "The home tile must not change slot order")
        NSApp.sendEvent(key(desktop, code: 36, characters: "\r"))
        try require(fake.activations == 3 && !desktop.isVisible, "Return on the home tile must run the Desktop action")
        try require(desktop.nativeCheckPayloadCount == 0, "Dismissal must release the home tile's wallpaper")

        // Overview Return on a window restores its app before focusing.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let overviewChoice = desktop.nativeCheckSelected
        NSApp.sendEvent(key(desktop, code: 36, characters: "\r"))
        try require(overviewChoice != nil && fake.focusPreparations.count == 2 && !desktop.isVisible,
                    "Overview Return on a window must restore before focusing")

        // Setting off: no Desktop anywhere.
        fake.showsDesktopEntry = false
        desktop.desktopStateChanged()
        desktop.present(mode: .switcher, fromShortcut: true)
        try require(!desktop.nativeCheckSwitcherTargets.contains(.desktop) && desktop.nativeCheckDesktopCard == nil,
                    "With the setting off the switcher has no Desktop card")
        desktop.dismiss(restorePreviousApplication: false)
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        try require(desktop.nativeCheckCards.allSatisfy { !$0.isDesktopEntry } && desktop.nativeCheckSlots == slots,
                    "With the setting off the Overview has no home tile and the same slots")
        desktop.dismiss(restorePreviousApplication: false)
        desktop.desktopEntry = nil
        desktop.previews = nil
        await settle()
        print("PASS desktop entry")
    }

    // MARK: Display, lock and session lifecycle

    /// AppKit rounds window frames to the backing grid.
    static func sameSize(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1 }

    @MainActor static func fits(_ window: NSWindow) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.insetBy(dx: 15, dy: 15).contains(window.frame) }
    }

    /// Screen-parameter changes re-fit or close surfaces; lock, display sleep and session switches dismiss,
    /// purge snapshots and refuse presentation until the session is back. Nothing here locks or reconfigures
    /// the real displays: the workspace notifications are posted in-process and the lock path is invoked directly
    /// (a distributed notification would reach other processes).
    @MainActor static func checkLifecycle(_ desktop: DesktopController, service: WindowService,
                                          records: (Int) -> [WindowRecord]) async throws {
        print("START lifecycle")
        let fake = FakeDesktopEntry()
        desktop.desktopEntry = fake
        service.nativeCheckInstall(records(20))
        await settle()
        let center = NotificationCenter.default

        // Visible Overview knocked off its screen and resized: a parameter change re-fits it.
        desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
        await settle()
        let overview = desktop.nativeCheckOverviewWindow
        overview.setFrame(NSRect(x: -9000, y: -9000, width: 300, height: 200), display: false)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        guard let overviewScreen = fits(overview) else { throw Failure.check("The Overview must be re-fitted inside a display") }
        try require(sameSize(overview.frame.size, OverviewPanelController.contentSize(for: overviewScreen.visibleFrame)),
                    "The re-fitted Overview must be sized for its display, got \(overview.frame) on \(overviewScreen.visibleFrame)")
        try require(desktop.isOverviewVisible && fake.screenChanges == 1, "A parameter change must keep the Overview and drop cached wallpapers")
        desktop.nativeCheckDetachPlacedScreen()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try require(!desktop.isVisible && outsideMonitors == 0, "A surface whose display disappeared must close")

        // Held switcher: same re-fit.
        desktop.present(mode: .switcher, fromShortcut: true)
        let switcher = desktop.nativeCheckSwitcherWindow
        let fitted = switcher.frame.size
        switcher.setFrame(NSRect(x: -9000, y: -9000, width: 200, height: 100), display: false)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try require(fits(switcher) != nil && switcher.frame.size == fitted && desktop.isVisible,
                    "The visible switcher must be re-fitted inside its display")
        desktop.dismiss(restorePreviousApplication: false)

        // Hidden panels are re-laid out for the pointer's display once the notification burst settles.
        overview.setFrame(NSRect(x: -9000, y: -9000, width: 300, height: 200), display: false)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(500))
        guard let pointer = NSScreen.pointerScreen else { throw Failure.check("No screen") }
        try require(sameSize(overview.frame.size, OverviewPanelController.contentSize(for: pointer.visibleFrame))
                    && fits(overview) != nil && !overview.isVisible,
                    "The hidden Overview must be re-sized for the pointer's display and stay hidden")
        try await Task.sleep(for: .milliseconds(200))

        // Lock with a visible surface and cached snapshots: dismiss, zero streams, purge, refuse until unlocked.
        let previews = FakePreviews()
        desktop.previews = previews
        var purges = 0
        desktop.onPrivacyPurge = { purges += 1; previews.cache.removeAll() }
        desktop.present(mode: .switcher, fromShortcut: true)
        guard let selected = desktop.nativeCheckSelected else { throw Failure.check("Missing a selection") }
        previews.deliverSnapshot(fixtureImage(.systemRed), for: selected)
        _ = previews.deliverLive(for: selected)
        try require(previews.liveStreamCount == 1 && previews.cache.count == 1, "Lock fixture needs a stream and a cached snapshot")
        desktop.nativeCheckReplaceSessionState { (locked: true, onConsole: true) }
        desktop.suspend(.screenLocked)
        try require(!desktop.isVisible && !previews.visible && previews.liveStreamCount == 0 && previews.budget.counts.current == 0,
                    "Locking must close the surface and end the live stream")
        try require(purges == 1 && previews.cache.count == 0 && desktop.nativeCheckPayloadCount == 0,
                    "Locking must purge cached snapshots")
        desktop.present(mode: .switcher, fromShortcut: true)
        desktop.focusOverview()
        try require(!desktop.isVisible, "No surface may open while the screen is locked")
        desktop.resume(.screenLocked)
        desktop.nativeCheckReplaceSessionState { (locked: false, onConsole: true) }
        desktop.present(mode: .switcher, fromShortcut: true)
        try require(desktop.isVisible, "Unlocking must allow surfaces again")
        desktop.dismiss(restorePreviousApplication: false)

        // Fast user switching and display sleep arrive as workspace notifications (posted in-process here).
        let workspace = NSWorkspace.shared.notificationCenter
        for (begin, end) in [(NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
                             (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification)] {
            desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore()
            await settle()
            let before = purges
            desktop.nativeCheckReplaceSessionState { (locked: false, onConsole: false) }
            workspace.post(name: begin, object: NSWorkspace.shared)
            try require(!desktop.isVisible && purges == before + 1 && !previews.visible && outsideMonitors == 0,
                        "\(begin.rawValue) must dismiss and purge")
            desktop.focusOverview()
            try require(!desktop.isVisible, "\(begin.rawValue) must refuse new surfaces")
            workspace.post(name: end, object: NSWorkspace.shared)
            desktop.nativeCheckReplaceSessionState { (locked: false, onConsole: true) }
        }
        // A missed unlock/wake notification heals itself: the session reports unlocked and on console.
        desktop.suspend(.screenLocked)
        desktop.present(mode: .switcher, fromShortcut: true)
        try require(desktop.isVisible && desktop.suspensions.isEmpty, "A stale suspension must clear when the session is unlocked")
        desktop.dismiss(restorePreviousApplication: false)
        desktop.onPrivacyPurge = nil
        desktop.previews = nil
        desktop.desktopEntry = nil
        await settle()
        print("PASS lifecycle")
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
