import AppKit
import PanefloCore

/// "Set up Paneflo": one row per permission with live status, a Grant button, Restart Paneflo when macOS needs a
/// relaunch, and a reset for stale permission entries. It renders a `SetupModel` the app rebuilds from preflight
/// readings; while the window is visible it asks for a fresh reading once a second (`onPoll`) and stops when hidden.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    var onGrant: ((SetupPermission) -> Void)?
    var onRestart: (() -> Void)?
    var onReset: (() -> Void)?
    /// Asked once a second while the window is visible, and once when it opens.
    var onPoll: (() -> Void)?
    var pollInterval: TimeInterval = 1

    private(set) var model: SetupModel?
    private var window: NSWindow?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    @MainActor private struct RowViews {
        let icon = NSImageView()
        let title = NSTextField(labelWithString: "")
        let tag = NSTextField(labelWithString: "")
        let purpose = NSTextField(wrappingLabelWithString: "")
        let status = NSTextField(labelWithString: "")
        let grant = NSButton(title: "Grant…", target: nil, action: nil)
    }
    private var rows: [SetupPermission: RowViews] = [:]
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let restartSection = NSStackView()
    private let restartButton = NSButton(title: "Restart Paneflo", target: nil, action: nil)
    private let staleHint = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: "Permissions stuck? Reset and grant again", target: nil, action: nil)
    private let doneButton = NSButton(title: "Later", target: nil, action: nil)
    private static let width: CGFloat = 500

    var isVisible: Bool { window?.isVisible == true }
    var isPolling: Bool { timer != nil }

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPolling() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.startPolling() } }
        })
    }

    isolated deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if let model { render(model) }
        if !window.isVisible {
            window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: Self.width + 48, height: 420))
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // An accessory app launched in the background can be refused activation; keep the window in front anyway.
        window.orderFrontRegardless()
        startPolling()
        onPoll?()
    }

    func close() { window?.close() }

    func update(_ model: SetupModel) {
        guard model != self.model else { return }
        self.model = model
        if window != nil { render(model) }
    }

    func windowWillClose(_ notification: Notification) { stopPolling() }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.onPoll?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Rendering

    private func render(_ model: SetupModel) {
        if model.isComplete {
            headline.stringValue = model.permissions.screenRecording
                ? "You’re set. ⌘Tab now opens Paneflo."
                : "You’re set. ⌘Tab now opens Paneflo. Screen Recording is optional: grant it to see window pictures."
        } else {
            headline.stringValue = "Paneflo needs Accessibility and Input Monitoring to replace ⌘Tab. Click Grant…, switch Paneflo on in the System Settings pane that opens, then come back. Each row turns green by itself."
        }
        for row in model.rows {
            guard let views = rows[row.permission] else { continue }
            views.tag.stringValue = row.required ? "Required" : "Optional"
            switch row.status {
            case .granted:
                views.status.stringValue = "On"
                views.status.textColor = .systemGreen
                views.icon.image = symbol("checkmark.circle.fill", color: .systemGreen)
            case .missing:
                views.status.stringValue = "Off"
                views.status.textColor = .secondaryLabelColor
                views.icon.image = row.required ? symbol("exclamationmark.circle.fill", color: .systemOrange)
                    : symbol("circle.dashed", color: .secondaryLabelColor)
            case .needsRestart:
                views.status.stringValue = "Switched on? Restart Paneflo to apply"
                views.status.textColor = .systemOrange
                views.icon.image = symbol("arrow.clockwise.circle.fill", color: .systemOrange)
            }
            views.icon.setAccessibilityLabel("\(row.permission.title): \(views.status.stringValue)")
            views.grant.isHidden = row.isGranted
        }
        restartSection.isHidden = !model.offersRestart
        restartButton.keyEquivalent = model.offersRestart ? "\r" : ""
        if model.showsStaleHint {
            let names = SetupPermission.allCases.filter(model.likelyStale.contains).map(\.title)
            staleHint.stringValue = "\(ListFormatter.localizedString(byJoining: names)) still reads off. \(PermissionReset.explanation)"
        }
        staleHint.isHidden = !model.showsStaleHint
        resetButton.bezelStyle = model.showsStaleHint ? .push : .inline
        doneButton.title = model.isComplete ? "Done" : "Later"
        doneButton.keyEquivalent = model.isComplete && !model.offersRestart ? "\r" : ""
        if let window, window.isVisible, let size = window.contentView?.fittingSize, size.height > window.contentLayoutRect.height {
            window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: size.height))
        }
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        // Filled symbols: a white glyph on the colored disc.
        let colors: [NSColor] = name.hasSuffix(".fill") ? [.white, color] : [color]
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular).applying(.init(paletteColors: colors)))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 48, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up Paneflo"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        let root = NSView()
        window.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        let title = NSTextField(labelWithString: "Set up Paneflo")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)
        headline.font = .systemFont(ofSize: 12); headline.textColor = .secondaryLabelColor
        headline.preferredMaxLayoutWidth = Self.width
        stack.addArrangedSubview(headline)
        for permission in SetupPermission.allCases {
            let views = RowViews()
            rows[permission] = views
            stack.addArrangedSubview(makeRow(permission, views))
        }

        restartSection.orientation = .vertical; restartSection.alignment = .leading; restartSection.spacing = 8
        let restartText = NSTextField(wrappingLabelWithString: "Switched Paneflo on in System Settings? macOS applies Input Monitoring and Screen Recording after Paneflo restarts.")
        restartText.font = .systemFont(ofSize: 12); restartText.preferredMaxLayoutWidth = Self.width
        restartSection.addArrangedSubview(restartText)
        restartButton.target = self; restartButton.action = #selector(restart)
        restartButton.bezelStyle = .push; restartButton.bezelColor = .controlAccentColor
        restartButton.controlSize = .large
        restartButton.setAccessibilityLabel("Restart Paneflo")
        restartSection.addArrangedSubview(restartButton)
        restartSection.isHidden = true
        stack.addArrangedSubview(restartSection)

        staleHint.font = .systemFont(ofSize: 11); staleHint.textColor = .secondaryLabelColor
        staleHint.preferredMaxLayoutWidth = Self.width
        staleHint.isHidden = true
        stack.addArrangedSubview(staleHint)
        let footer = NSStackView()
        footer.orientation = .horizontal; footer.spacing = 10
        resetButton.target = self; resetButton.action = #selector(reset)
        resetButton.bezelStyle = .inline
        resetButton.toolTip = PermissionReset.explanation
        resetButton.setAccessibilityLabel("Permissions stuck? Reset and grant again")
        footer.addArrangedSubview(resetButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        doneButton.target = self; doneButton.action = #selector(done)
        doneButton.bezelStyle = .push
        footer.addArrangedSubview(doneButton)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return window
    }

    private func makeRow(_ permission: SetupPermission, _ views: RowViews) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 12
        views.icon.image = symbol("circle.dashed", color: .secondaryLabelColor)
        views.icon.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(views.icon)
        let text = NSStackView()
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let titleLine = NSStackView()
        titleLine.orientation = .horizontal; titleLine.spacing = 6
        views.title.stringValue = permission.title
        views.title.font = .systemFont(ofSize: 13, weight: .semibold)
        views.tag.font = .systemFont(ofSize: 11); views.tag.textColor = .tertiaryLabelColor
        titleLine.addArrangedSubview(views.title); titleLine.addArrangedSubview(views.tag)
        text.addArrangedSubview(titleLine)
        views.purpose.stringValue = permission.purpose
        views.purpose.font = .systemFont(ofSize: 11); views.purpose.textColor = .secondaryLabelColor
        views.purpose.preferredMaxLayoutWidth = Self.width - 150
        text.addArrangedSubview(views.purpose)
        views.status.font = .systemFont(ofSize: 11, weight: .medium)
        text.addArrangedSubview(views.status)
        text.widthAnchor.constraint(equalToConstant: Self.width - 150).isActive = true
        row.addArrangedSubview(text)
        views.grant.target = self; views.grant.action = #selector(grant(_:))
        views.grant.bezelStyle = .push
        views.grant.tag = SetupPermission.allCases.firstIndex(of: permission) ?? 0
        views.grant.setAccessibilityLabel("Grant \(permission.title)")
        views.grant.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(views.grant)
        row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return row
    }

    @objc private func grant(_ sender: NSButton) {
        guard SetupPermission.allCases.indices.contains(sender.tag) else { return }
        onGrant?(SetupPermission.allCases[sender.tag])
    }
    @objc private func restart() { onRestart?() }
    @objc private func reset() { onReset?() }
    @objc private func done() { window?.close() }

    #if PANEFLO_NATIVE_CHECK
    struct NativeCheckRow: Equatable { let title: String; let tag: String; let status: String; let grantVisible: Bool }
    var nativeCheckRows: [NativeCheckRow] {
        SetupPermission.allCases.compactMap { permission in
            rows[permission].map { NativeCheckRow(title: $0.title.stringValue, tag: $0.tag.stringValue,
                                                  status: $0.status.stringValue, grantVisible: !$0.grant.isHidden) }
        }
    }
    var nativeCheckRestartVisible: Bool { !restartSection.isHidden }
    var nativeCheckStaleHintVisible: Bool { !staleHint.isHidden }
    var nativeCheckHeadline: String { headline.stringValue }
    var nativeCheckDoneTitle: String { doneButton.title }
    var nativeCheckWindow: NSWindow? { window }
    func nativeCheckPressGrant(_ permission: SetupPermission) { rows[permission]?.grant.performClick(nil) }
    func nativeCheckPressRestart() { restartButton.performClick(nil) }
    func nativeCheckPressReset() { resetButton.performClick(nil) }
    #endif
}
