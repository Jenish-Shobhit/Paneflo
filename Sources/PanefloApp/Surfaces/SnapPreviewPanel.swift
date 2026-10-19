import AppKit
import PanefloCore

/// The translucent outline of where a dragged window will land when it is released on a screen edge. A borderless,
/// non-activating panel that ignores the mouse, joins every Space and sits above normal windows. Built on first use;
/// ordered out (never destroyed) when hidden, so a hidden preview does no work.
///
/// Accent tint over a glass material, a 12 pt continuous corner and a thin accent border. Increase Contrast makes the
/// fill and border stronger; Reduce Transparency drops the material for a flat tint; Reduce Motion makes every change
/// instant (otherwise a short fade in and a frame glide between zones).
@MainActor
final class SnapPreviewPanel {
    private static let radius: CGFloat = 12
    private var panel: NSPanel?
    private var effect: NSVisualEffectView?
    private var tint: NSView?
    var isVisible: Bool { panel?.isVisible ?? false }

    /// `frame` in Accessibility coordinates (top-left origin at the primary display).
    func show(_ frame: WindowRect) {
        guard let primary = NSScreen.screens.first else { return }
        let rect = NSRect(x: frame.x, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyStyle(PanefloStyle.Accessibility.current)
        let duration = PanefloStyle.Motion.duration(0.12)
        if panel.isVisible {
            guard duration > 0 else { panel.setFrame(rect, display: true); return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(rect, display: true)
            }
            return
        }
        panel.setFrame(rect, display: false)
        panel.alphaValue = duration > 0 ? 0 : 1
        panel.orderFrontRegardless()
        guard duration > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func applyStyle(_ options: PanefloStyle.Accessibility) {
        guard let panel, let tint, let layer = tint.layer else { return }
        effect?.isHidden = options.reduceTransparency
        let appearance = panel.effectiveAppearance
        let dark = PanefloStyle.isDark(appearance)
        let fillAlpha: CGFloat = options.reduceTransparency ? (dark ? 0.34 : 0.26) : (options.increaseContrast ? 0.30 : 0.18)
        PanefloStyle.withoutAnimation {
            layer.backgroundColor = PanefloStyle.cgColor(NSColor.controlAccentColor.withAlphaComponent(fillAlpha), for: appearance)
            layer.borderColor = PanefloStyle.cgColor(NSColor.controlAccentColor.withAlphaComponent(options.increaseContrast ? 1 : 0.6),
                                                     for: appearance)
            layer.borderWidth = options.increaseContrast ? 3 : 1.5
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityElement(false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        let effect = NSVisualEffectView(frame: content.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        content.addSubview(effect)
        let tint = NSView(frame: content.bounds)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = Self.radius
        tint.layer?.cornerCurve = .continuous
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)
        panel.contentView = content
        self.effect = effect
        self.tint = tint
        return panel
    }
}
