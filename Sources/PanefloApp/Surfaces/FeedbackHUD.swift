import AppKit
import PanefloCore

/// A small transient glass label near the bottom of a display (about 1.2 s) saying why an arrangement did not happen
/// ("Can't arrange a full-screen window", "Grant Accessibility in Settings to arrange windows"). Never takes focus or
/// clicks; VoiceOver announces it. Built on first use.
@MainActor
final class FeedbackHUD {
    static let duration: TimeInterval = 1.2
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private(set) var lastMessage: String?
    var isVisible: Bool { panel?.isVisible ?? false }

    /// `near`: a window frame in Accessibility coordinates; its display hosts the label (else the pointer's display).
    func show(_ message: String, near frame: WindowRect? = nil) {
        lastMessage = message
        RuntimeDiagnostics.mark("feedback hud shown")
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = message
        let size = label.fittingSize
        let content = NSSize(width: ceil(size.width) + 32, height: ceil(size.height) + 18)
        let screen = Self.screen(containing: frame) ?? NSScreen.pointerScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: (visible.midX - content.width / 2).rounded(), y: visible.minY + 72,
                              width: content.width, height: content.height), display: false)
        label.frame = NSRect(x: 16, y: 9, width: ceil(size.width), height: ceil(size.height))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    func hide() { hideWork?.cancel(); panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 36), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        effect.addSubview(label)
        panel.contentView = effect
        return panel
    }

    private static func screen(containing frame: WindowRect?) -> NSScreen? {
        guard let frame, let primary = NSScreen.screens.first else { return nil }
        // Accessibility (top-left origin) to AppKit (bottom-left origin) for the window's centre.
        let point = NSPoint(x: frame.centerX, y: primary.frame.height - frame.centerY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }
}
