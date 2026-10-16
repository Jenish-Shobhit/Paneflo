import AppKit
import Foundation

@MainActor
final class FixtureWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let geometryLabel = NSTextField(labelWithString: "")
    private let focusLabel = NSTextField(labelWithString: "")

    init(number: Int, frame: NSRect) {
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        let label = number == 1 ? "One" : number == 2 ? "Two" : "Window \(number)"
        window.title = "Paneflo Fixture \(label)"
        window.minSize = NSSize(width: 200, height: 120)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("paneflo.fixture.window.\(number)")

        let title = NSTextField(labelWithString: window.title)
        title.font = .boldSystemFont(ofSize: 17)
        title.setAccessibilityIdentifier("fixture.title")

        geometryLabel.setAccessibilityIdentifier("fixture.geometry")
        focusLabel.setAccessibilityIdentifier("fixture.focus")
        geometryLabel.setAccessibilityLabel("Window frame in screen points")
        focusLabel.setAccessibilityLabel("Window focus state")

        let stack = NSStackView(views: [title, geometryLabel, focusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        window.contentView = content
        refreshLabels()
    }

    func windowDidMove(_ notification: Notification) { refreshLabels() }
    func windowDidResize(_ notification: Notification) { refreshLabels() }
    func windowDidBecomeKey(_ notification: Notification) { refreshLabels() }
    func windowDidResignKey(_ notification: Notification) { refreshLabels() }

    func refreshLabels() {
        let frame = window.frame
        geometryLabel.stringValue = String(
            format: "x: %.0f   y: %.0f   width: %.0f   height: %.0f",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height
        )
        focusLabel.stringValue = window.isKeyWindow ? "Focused: yes" : "Focused: no"
        focusLabel.setAccessibilityValue(focusLabel.stringValue)
        geometryLabel.setAccessibilityValue(geometryLabel.stringValue)
    }
}

@MainActor
final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [FixtureWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let requestedCount = Self.requestedWindowCount(arguments: CommandLine.arguments)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(440, max(200, screen.width * 0.42))
        let height = min(260, max(120, screen.height * 0.38))
        let gap: CGFloat = 24
        let totalWidth = width * 2 + gap
        let startX = screen.minX + max(0, (screen.width - totalWidth) / 2)
        let y = screen.minY + max(0, (screen.height - height) / 2)

        for index in 0..<requestedCount {
            let x = startX + CGFloat(index % 2) * (width + gap)
            let controller = FixtureWindowController(
                number: index + 1,
                frame: NSRect(x: x, y: y, width: width, height: height)
            )
            controllers.append(controller)
            controller.window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = appMenu.addItem(withTitle: "Quit Paneflo Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let newWindowItem = windowMenu.addItem(withTitle: "New Fixture Window", action: #selector(newFixtureWindow), keyEquivalent: "n")
        newWindowItem.target = self
        windowMenuItem.submenu = windowMenu
        main.addItem(windowMenuItem)
        NSApp.mainMenu = main
    }

    @objc private func newFixtureWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let index = controllers.count
        let width = min(440, max(200, screen.width * 0.42))
        let height = min(260, max(120, screen.height * 0.38))
        let frame = NSRect(
            x: screen.minX + CGFloat(index % 2) * min(width + 24, screen.width - width),
            y: screen.minY + max(0, (screen.height - height) / 2) - CGFloat(index / 2) * 28,
            width: width,
            height: height
        )
        let controller = FixtureWindowController(number: index + 1, frame: frame)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
    }

    private static func requestedWindowCount(arguments: [String]) -> Int {
        guard let marker = arguments.firstIndex(of: "--count"),
              arguments.indices.contains(marker + 1),
              let count = Int(arguments[marker + 1]) else { return 2 }
        return min(max(count, 1), 20)
    }
}

@main
struct PanefloFixtureMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
