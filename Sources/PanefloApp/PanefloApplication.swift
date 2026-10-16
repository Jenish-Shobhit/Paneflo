import AppKit

@main
struct PanefloApplication {
    @MainActor
    static func main() {
        if RuntimeDiagnostics.handleCommandLine() { return }
        RuntimeDiagnostics.mark("entry")
        let application = NSApplication.shared
        RuntimeDiagnostics.mark("application initialized")
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var previewController: PreviewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeDiagnostics.mark("delegate launched")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Paneflo developer preview")
        item.button?.title = " Paneflo"
        item.button?.setAccessibilityLabel("Paneflo developer preview menu")

        let menu = NSMenu()
        let heading = NSMenuItem(title: "Native developer preview · Sample windows", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        for (index, title) in ["Switcher preview", "Tiling preview", "Overview preview"].enumerated() {
            let entry = NSMenuItem(title: title, action: #selector(openPreview(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Paneflo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        // Explicit preview launch only. No permissions or global input hooks are installed.
        showPreview(mode: 0)
        RuntimeDiagnostics.mark("initial surface requested")
    }

    @objc private func openPreview(_ sender: NSMenuItem) {
        showPreview(mode: sender.tag)
    }

    private func showPreview(mode: Int) {
        if previewController == nil { previewController = PreviewController() }
        previewController?.present(mode: mode)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
