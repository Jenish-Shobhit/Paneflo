import AppKit
import Foundation

private struct FixtureOptions {
    let count: Int
    let labelPrefix: String?

    static let usage = "Usage: PanefloFixture [--count 1...20] [--label SAFE_NAME] [--help]\n"

    static func parse(_ arguments: [String]) throws -> FixtureOptions? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage, terminator: "")
            return nil
        }

        var count = 2
        var labelPrefix: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option == "--count" || option == "--label" else {
                throw FixtureOptionsError.unknown(option)
            }
            guard arguments.indices.contains(index + 1) else {
                throw FixtureOptionsError.missingValue(option)
            }
            let value = arguments[index + 1]
            switch option {
            case "--count":
                guard let parsed = Int(value), (1...20).contains(parsed) else {
                    throw FixtureOptionsError.invalidCount(value)
                }
                count = parsed
            case "--label":
                guard Self.isSafeLabel(value) else { throw FixtureOptionsError.invalidLabel }
                labelPrefix = value
            default:
                throw FixtureOptionsError.unknown(option)
            }
            index += 2
        }
        return FixtureOptions(count: count, labelPrefix: labelPrefix)
    }

    private static func isSafeLabel(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...32).contains(scalars.count), value == value.trimmingCharacters(in: .whitespaces) else { return false }
        return scalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            scalar.value == 32 || scalar.value == 45 || scalar.value == 95
        }
    }
}

private enum FixtureOptionsError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidCount(String)
    case invalidLabel
    case unknown(String)

    var description: String {
        switch self {
        case .missingValue(let option): return "Missing value for \(option)."
        case .invalidCount(let value): return "Invalid window count '\(value)'; use a number from 1 to 20."
        case .invalidLabel: return "The label must use 1–32 letters, digits, spaces, hyphens, or underscores."
        case .unknown(let option): return "Unknown option '\(option)'."
        }
    }
}

@MainActor
final class FixtureWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let geometryLabel = NSTextField(labelWithString: "")
    private let focusLabel = NSTextField(labelWithString: "")
    private let animationView = FixtureAnimationView(frame: .zero)
    private let animateButton = NSButton(checkboxWithTitle: "Animate fixture", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause fixture for 5 seconds", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Fixture responsive")

    init(number: Int, frame: NSRect, labelPrefix: String?) {
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        let windowLabel = number == 1 ? "One" : number == 2 ? "Two" : "Window \(number)"
        let defaultTitle = "Paneflo Fixture \(windowLabel)"
        window.title = labelPrefix.map { "\($0) · \(defaultTitle)" } ?? defaultTitle
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
        animateButton.target = self
        animateButton.action = #selector(toggleAnimation)
        animateButton.setAccessibilityLabel("Animate fixture")
        pauseButton.target = self
        pauseButton.action = #selector(pauseForFiveSeconds)
        pauseButton.setAccessibilityLabel("Pause fixture for 5 seconds")
        pauseButton.toolTip = "Blocks this fixture's UI thread for five seconds to test unresponsive-window handling."
        statusLabel.setAccessibilityLabel("Fixture responsiveness")

        animationView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        animationView.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let controls = NSStackView(views: [animateButton, pauseButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        let stack = NSStackView(views: [title, geometryLabel, focusLabel, animationView, controls, statusLabel])
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
    func windowWillClose(_ notification: Notification) { stopWorkloads() }

    func stopWorkloads() {
        animationView.stopAnimating()
        animateButton.state = .off
    }

    @objc private func toggleAnimation() {
        if animateButton.state == .on { animationView.startAnimating() }
        else { animationView.stopAnimating() }
    }

    @objc private func pauseForFiveSeconds() {
        pauseButton.isEnabled = false
        statusLabel.stringValue = "Fixture paused for 5 seconds"
        window.displayIfNeeded()
        Thread.sleep(forTimeInterval: 5)
        pauseButton.isEnabled = true
        statusLabel.stringValue = "Fixture responsive"
        window.displayIfNeeded()
    }

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
private final class FixtureAnimationView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0

    override var isFlipped: Bool { true }

    func startAnimating() {
        guard timer == nil else { return }
        let nextTimer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(animationTick), userInfo: nil, repeats: true)
        timer = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    @objc private func animationTick() {
        phase = phase >= 1 ? 0 : phase + 1.0 / 30.0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()

        let track = bounds.insetBy(dx: 12, dy: 19)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.midY - 2, width: track.width, height: 4), xRadius: 2, yRadius: 2).fill()
        let diameter: CGFloat = 18
        let x = track.minX + max(0, track.width - diameter) * phase
        (timer == nil ? NSColor.systemBlue : NSColor.systemOrange).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: track.midY - diameter / 2, width: diameter, height: diameter)).fill()
        let label = timer == nil ? "Capture workload · animation paused" : "Capture workload · 30 fps"
        (label as NSString).draw(at: NSPoint(x: 12, y: bounds.maxY - 17), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
}

@MainActor
private final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [FixtureWindowController] = []
    private let options: FixtureOptions

    init(options: FixtureOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(440, max(200, screen.width * 0.42))
        let height = min(260, max(120, screen.height * 0.38))
        let gap: CGFloat = 24
        let totalWidth = width * 2 + gap
        let startX = screen.minX + max(0, (screen.width - totalWidth) / 2)
        let y = screen.minY + max(0, (screen.height - height) / 2)

        for index in 0..<options.count {
            let x = startX + CGFloat(index % 2) * (width + gap)
            let controller = FixtureWindowController(
                number: index + 1,
                frame: NSRect(x: x, y: y, width: width, height: height),
                labelPrefix: options.labelPrefix
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
        guard controllers.count < 20 else { NSSound.beep(); return }
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
        let controller = FixtureWindowController(number: index + 1, frame: frame, labelPrefix: options.labelPrefix)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers { controller.stopWorkloads() }
    }
}

@main
struct PanefloFixtureMain {
    @MainActor
    static func main() {
        let options: FixtureOptions
        do {
            guard let parsed = try FixtureOptions.parse(Array(CommandLine.arguments.dropFirst())) else { return }
            options = parsed
        } catch {
            fputs("PanefloFixture: \(error)\n\(FixtureOptions.usage)", stderr)
            exit(EXIT_FAILURE)
        }
        let app = NSApplication.shared
        let delegate = FixtureAppDelegate(options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
