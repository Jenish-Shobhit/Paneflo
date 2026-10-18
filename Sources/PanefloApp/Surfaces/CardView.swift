import AppKit
import QuartzCore
import PanefloCore

/// One window card, vacant Overview slot, or the Desktop entry (`isDesktopEntry`). Every property setter compares before it
/// invalidates, so a selection change redraws only the cards whose appearance changed.
///
/// The app icon, preview pixels and preview label live in their own layers: a snapshot, a live
/// frame or a label change touches only this card's layers and never redraws its backing store
/// (so dismissal and reopen do no card drawing for previews either).
@MainActor
final class CardView: NSButton {
    /// What the preview layer shows. A live frame is retained only while it is displayed.
    enum PreviewPixels {
        case none
        case snapshot(CGImage)
        case live(LiveFrame)

        var hasContent: Bool { if case .none = self { false } else { true } }
    }

    #if PANEFLO_NATIVE_CHECK
    /// Counts backing-store invalidations so own-window checks can assert redraw scope.
    static var invalidations = 0
    #endif

    var record: WindowRecord? {
        didSet {
            guard oldValue != record else { return }
            // A slot card rebound to another window must never show the previous window's pixels.
            if oldValue?.id != record?.id, hasPreviewState || pixels.hasContent { clearPreview() }
            toolTip = record?.title
            updateAccessibilityLabel()
            invalidate()
            updateIconLayer()
            updateStatusLayer()
        }
    }
    var icon: NSImage? {
        didSet {
            guard oldValue !== icon else { return }
            if PreviewRenderer.usesReferenceRenderer { invalidate() } else { updateIconLayer() }
        }
    }
    var layoutBadge: String? { didSet { if oldValue != layoutBadge { invalidate() } } }
    /// Tile-pair indicator after the app name; nil when the window has no partner.
    var pairBadge: String? { didSet { if oldValue != pairBadge { updateAccessibilityLabel(); invalidate() } } }
    /// The Desktop pseudo-entry: titled "Desktop", shows the wallpaper (or a placeholder) and never a window preview.
    /// It has no `record`, so it is never reported to the capture engine.
    var isDesktopEntry = false {
        didSet {
            guard oldValue != isDesktopEntry else { return }
            clearPreview()
            toolTip = nil
            updateAccessibilityLabel()
            if !PreviewRenderer.usesReferenceRenderer {
                // The wallpaper fills its area; window previews are letterboxed.
                previewLayer.contentsGravity = isDesktopEntry ? .resizeAspectFill : .resizeAspect
                previewLayer.masksToBounds = isDesktopEntry
                previewLayer.cornerRadius = isDesktopEntry ? 8 : 0
            }
            invalidate()
            updateIconLayer()
            updateStatusLayer()
        }
    }
    /// The desktop is the current state: choosing the entry brings the windows back instead of showing the desktop.
    var desktopIsCurrent = false {
        didSet {
            guard oldValue != desktopIsCurrent, isDesktopEntry else { return }
            updateAccessibilityLabel()
            invalidate()
        }
    }
    /// What choosing this card selects.
    var switchTarget: SwitchTarget? { isDesktopEntry ? .desktop : record.map { .window($0.id) } }
    private let previewLayer = CALayer()
    private let iconLayer = CALayer()
    private var iconLayerSource: (image: NSImage, scale: CGFloat)?
    private let statusLayer = CATextLayer()
    private let liveDot = CALayer()
    private(set) var pixels = PreviewPixels.none
    /// The engine's label ("Live", "Snapshot · 3s", "Unavailable: minimized"...), nil without preview state.
    private(set) var previewLabel: String?
    private(set) var previewIsLive = false
    /// False after `releasePayload` until the next preview update; the coordinator then asks the
    /// engine for this card's current state.
    private(set) var hasPreviewState = false
    var selected = false {
        didSet {
            guard oldValue != selected else { return }
            setAccessibilityValue(selected ? "Selected" : "Not selected")
            invalidate()
        }
    }
    var matches = true {
        didSet { if oldValue != matches { invalidate(); updatePreviewLayer(); updateIconLayer(); updateStatusLayer() } }
    }
    var isVacancyPinned = false { didSet { if oldValue != isVacancyPinned { invalidate() } } }
    var dragEnabled = false
    var onDoubleClick: ((SwitchTarget) -> Void)?
    var onDragEnd: ((Int, NSPoint) -> Void)?
    /// Context menus are built only when AppKit asks for one (right-click or Control-click).
    var menuProvider: ((CardView) -> NSMenu?)?

    override var isFlipped: Bool { true }
    /// The held picker is never key; a click must still select on the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 168) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityValue("Not selected")
        if !PreviewRenderer.usesReferenceRenderer {
            wantsLayer = true
            // Letterbox the window's aspect ratio inside the preview area. Frames and snapshots are
            // captured at the area's pixel size, so plain linear filtering stays crisp.
            previewLayer.contentsGravity = .resizeAspect
            previewLayer.minificationFilter = .linear
            previewLayer.magnificationFilter = .linear
            previewLayer.isHidden = true
            layer?.addSublayer(previewLayer)
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.isHidden = true
            layer?.addSublayer(iconLayer)
            statusLayer.fontSize = 10
            statusLayer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            statusLayer.truncationMode = .end
            statusLayer.alignmentMode = .left
            statusLayer.isWrapped = false
            layer?.addSublayer(statusLayer)
            liveDot.cornerRadius = 3
            liveDot.isHidden = true
            layer?.addSublayer(liveDot)
            updateStatusColors()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setEnabledIfChanged(_ enabled: Bool) { if isEnabled != enabled { isEnabled = enabled } }

    /// Drops window content and per-session decoration; keeps the view for reuse.
    func releasePayload() {
        clearPreview()
        layoutBadge = nil
    }

    /// Renders one engine update. `.keep` changes the label only.
    func showPreview(_ update: PreviewUpdate, now: Double = ProcessInfo.processInfo.systemUptime) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch update.content {
        case .live(let frame): setPixels(.live(frame))
        case .snapshot(let image): setPixels(.snapshot(image))
        case .keep: break
        case .none: setPixels(.none)
        }
        hasPreviewState = true
        setLabel(update.label(now: now), live: update.presentation.isLive)
    }

    /// The Desktop entry's wallpaper, labelled "Wallpaper"; nil shows the placeholder. Never labelled live.
    func showWallpaper(_ image: CGImage?) {
        guard isDesktopEntry else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        setPixels(image.map { .snapshot($0) } ?? .none)
        setLabel(image == nil ? nil : "Wallpaper", live: false)
    }

    private func updateAccessibilityLabel() {
        if isDesktopEntry {
            setAccessibilityLabel(desktopIsCurrent ? "Desktop, bring your windows back" : "Desktop, show the desktop")
        } else {
            setAccessibilityLabel(record.map { "\($0.appName), \($0.title)" + (pairBadge == nil ? "" : ", paired") } ?? "Vacant overview slot")
        }
    }

    /// A window card or the Desktop entry, as opposed to a vacant slot.
    private var hasItem: Bool { record != nil || isDesktopEntry }

    /// Back to the app icon with no preview label (previews off, card reused, surface hidden).
    func clearPreview() {
        setPixels(.none)
        hasPreviewState = false
        setLabel(nil, live: false)
    }

    private func setPixels(_ next: PreviewPixels) {
        switch (pixels, next) {
        case (.none, .none): return
        case let (.snapshot(old), .snapshot(new)) where old === new: return
        case let (.live(old), .live(new)) where old === new: return
        default: break
        }
        let hadContent = pixels.hasContent
        pixels = next
        if PreviewRenderer.usesReferenceRenderer { invalidate(); return }
        updatePreviewLayer()
        if hadContent != next.hasContent { updateIconLayer() }
    }

    private func setLabel(_ text: String?, live: Bool) {
        guard text != previewLabel || live != previewIsLive else { return }
        previewLabel = text
        previewIsLive = live
        if PreviewRenderer.usesReferenceRenderer { invalidate() } else { updateStatusLayer() }
    }

    /// Text in the card's bottom line: the engine's label, or a plain state without previews.
    private var statusText: String {
        previewLabel ?? (record?.isMinimized == true ? "Minimized" : "")
    }

    /// The preview area in view coordinates (flipped); shared by drawing, layers and capture sizing.
    var previewRect: NSRect {
        NSRect(x: 14, y: 13, width: max(0, bounds.width - 28), height: max(0, bounds.height - 66))
    }

    private func invalidate() {
        #if PANEFLO_NATIVE_CHECK
        CardView.invalidations += 1
        #endif
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(self) }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed, !PreviewRenderer.usesReferenceRenderer { updatePreviewLayer(); updateIconLayer(); updateStatusLayer() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if !PreviewRenderer.usesReferenceRenderer { updatePreviewLayer(); updateIconLayer(); updateStatusLayer() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !PreviewRenderer.usesReferenceRenderer { updateStatusColors() }
    }

    private func updatePreviewLayer() {
        guard !PreviewRenderer.usesReferenceRenderer else { return }
        let visible = pixels.hasContent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if visible {
            let target = convertToLayer(previewRect)
            if previewLayer.frame != target { previewLayer.frame = target }
            let scale = window?.backingScaleFactor ?? 1
            if previewLayer.contentsScale != scale { previewLayer.contentsScale = scale }
            previewLayer.opacity = matches ? 1 : 0.24
        }
        switch pixels {
        case .none: previewLayer.contents = nil
        case .snapshot(let image): previewLayer.contents = image
        case .live(let frame):
            // Zero-copy: the layer samples the frame's IOSurface. A recycled surface object must
            // still register as new content.
            if let current = previewLayer.contents as AnyObject?, current === frame.surface { previewLayer.contents = nil }
            previewLayer.contents = frame.surface
        }
        previewLayer.isHidden = !visible
        CATransaction.commit()
    }

    /// The app icon, shown while the card has no preview pixels.
    private func updateIconLayer() {
        guard !PreviewRenderer.usesReferenceRenderer else { return }
        let visible = record != nil && !isDesktopEntry && icon != nil && !pixels.hasContent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if visible, let icon {
            let area = previewRect
            let target = convertToLayer(NSRect(x: area.midX - 30, y: area.midY - 30, width: 60, height: 60))
            if iconLayer.frame != target { iconLayer.frame = target }
            let scale = icon.recommendedLayerContentsScale(window?.backingScaleFactor ?? 1)
            if iconLayerSource?.image !== icon || iconLayerSource?.scale != scale {
                iconLayerSource = (icon, scale)
                iconLayer.contentsScale = scale
                iconLayer.contents = icon.layerContents(forContentsScale: scale)
            }
            iconLayer.opacity = matches ? 1 : 0.24
        }
        if iconLayer.isHidden == visible { iconLayer.isHidden = !visible }
        CATransaction.commit()
    }

    private func updateStatusLayer() {
        guard !PreviewRenderer.usesReferenceRenderer else { return }
        let text = hasItem ? statusText : ""
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 1
        if statusLayer.contentsScale != scale { statusLayer.contentsScale = scale }
        let inset: CGFloat = previewIsLive ? 10 : 0
        let line = NSRect(x: 15 + inset, y: bounds.height - 19, width: max(0, bounds.width - 30 - inset), height: 14)
        let target = convertToLayer(line)
        if statusLayer.frame != target { statusLayer.frame = target }
        if (statusLayer.string as? String) != text { statusLayer.string = text }
        statusLayer.isHidden = text.isEmpty
        let dot = convertToLayer(NSRect(x: 15, y: bounds.height - 15, width: 6, height: 6))
        if liveDot.frame != dot { liveDot.frame = dot }
        liveDot.isHidden = !previewIsLive || record == nil || isDesktopEntry
        let opacity: Float = matches ? 1 : 0.24
        statusLayer.opacity = opacity; liveDot.opacity = opacity
        CATransaction.commit()
    }

    private func updateStatusColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
            liveDot.backgroundColor = NSColor.systemGreen.cgColor
            CATransaction.commit()
        }
    }

    /// Computed on request so preview updates never pay for accessibility bookkeeping.
    override func accessibilityHelp() -> String? {
        if isDesktopEntry { return pixels.hasContent ? "Desktop wallpaper" : nil }
        return switch pixels {
        case .live: "Live window preview"
        case .snapshot: "Window snapshot" + (previewLabel.map { ", " + $0 } ?? "")
        case .none: previewLabel ?? (record == nil ? nil : "App icon")
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let switchTarget { onDoubleClick?(switchTarget); return }
        guard dragEnabled, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        var dragged = false
        isHighlighted = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 5 { dragged = true }
            if next.type == .leftMouseUp {
                isHighlighted = false
                if dragged { onDragEnd?(tag, next.locationInWindow) }
                else { _ = sendAction(action, to: target) }
                break
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .controlBackgroundColor).setFill(); path.fill()
        (selected ? NSColor.controlAccentColor : .separatorColor).setStroke(); path.lineWidth = selected ? 3 : 1; path.stroke()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setAlpha(matches ? 1 : 0.24)
        if isDesktopEntry {
            drawDesktopEntry()
            NSGraphicsContext.restoreGraphicsState(); return
        }
        guard let record else {
            drawText(isVacancyPinned ? "Pinned vacancy" : "Vacant slot", in: NSRect(x: 18, y: 68, width: bounds.width - 36, height: 24), font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
            NSGraphicsContext.restoreGraphicsState(); return
        }
        let target = previewRect
        if pixels.hasContent {
            if PreviewRenderer.usesReferenceRenderer, let preview = referenceImage {
                let scale = min(target.width / CGFloat(preview.width), target.height / CGFloat(preview.height))
                let area = NSRect(x: target.midX - CGFloat(preview.width) * scale / 2, y: target.midY - CGFloat(preview.height) * scale / 2, width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)).draw(in: area)
            }
        } else if PreviewRenderer.usesReferenceRenderer {
            icon?.draw(in: NSRect(x: target.midX - 30, y: target.midY - 30, width: 60, height: 60))
        }
        drawText(record.appName + (layoutBadge.map { " · " + $0 } ?? "") + (pairBadge.map { "  " + $0 } ?? "") + (isVacancyPinned ? "  • pinned" : ""), in: NSRect(x: 15, y: bounds.height - 53, width: bounds.width - 30, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        drawText(record.title, in: NSRect(x: 15, y: bounds.height - 34, width: bounds.width - 30, height: 17), font: .systemFont(ofSize: 11), color: .labelColor)
        if PreviewRenderer.usesReferenceRenderer {
            drawText((previewIsLive ? "● " : "") + statusText, in: NSRect(x: 15, y: bounds.height - 18, width: bounds.width - 30, height: 13), font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A quiet stand-in drawn under the wallpaper layer (visible when no still wallpaper exists, for example a
    /// dynamic one), plus the entry's two text lines.
    private func drawDesktopEntry() {
        let area = previewRect
        let backdrop = NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8)
        NSGradient(starting: NSColor.systemTeal.withAlphaComponent(0.22), ending: NSColor.systemIndigo.withAlphaComponent(0.30))?
            .draw(in: backdrop, angle: -60)
        // Always drawn: the wallpaper layer (aspect-fill) covers it completely when present, so a wallpaper arriving
        // or being released never needs a redraw.
        if let symbol = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .light).applying(.init(hierarchicalColor: .secondaryLabelColor))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
        }
        if PreviewRenderer.usesReferenceRenderer, let preview = referenceImage {
            NSGraphicsContext.saveGraphicsState(); backdrop.addClip()
            NSImage(cgImage: preview, size: area.size).draw(in: area)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawText(SwitcherSession.desktopTitle, in: NSRect(x: 15, y: bounds.height - 53, width: bounds.width - 30, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        drawText(desktopIsCurrent ? "Bring your windows back" : "Show the desktop", in: NSRect(x: 15, y: bounds.height - 34, width: bounds.width - 30, height: 17), font: .systemFont(ofSize: 11), color: .labelColor)
        if PreviewRenderer.usesReferenceRenderer, let previewLabel {
            drawText(previewLabel, in: NSRect(x: 15, y: bounds.height - 18, width: bounds.width - 30, height: 13), font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        }
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckLayerContents: AnyObject? { previewLayer.contents as AnyObject? }
    var nativeCheckStatusText: String? { statusLayer.isHidden ? nil : statusLayer.string as? String }
    var nativeCheckLiveDotVisible: Bool { !liveDot.isHidden }
    #endif

    /// Developer A/B renderer only: a CPU image of the current pixels.
    private var referenceImage: CGImage? {
        switch pixels {
        case .none: nil
        case .snapshot(let image): image
        case .live(let frame): CaptureController.borrowedImage(from: frame)
        }
    }
}
