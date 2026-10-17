import AppKit
import QuartzCore
import PanefloCore

/// One window (or vacant Overview slot) card. Every property setter compares before it
/// invalidates, so a selection change redraws only the cards whose appearance changed.
@MainActor
final class CardView: NSButton {
    #if PANEFLO_NATIVE_CHECK
    /// Counts backing-store invalidations so own-window checks can assert redraw scope.
    static var invalidations = 0
    #endif

    var record: WindowRecord? {
        didSet {
            guard oldValue != record else { return }
            toolTip = record?.title
            setAccessibilityLabel(record.map { "\($0.appName), \($0.title)" } ?? "Vacant overview slot")
            invalidate()
        }
    }
    var icon: NSImage? { didSet { if oldValue !== icon { invalidate() } } }
    var layoutBadge: String? { didSet { if oldValue != layoutBadge { invalidate() } } }
    private let previewLayer = CALayer()
    var thumbnail: CGImage? {
        didSet {
            guard oldValue !== thumbnail else { return }
            updatePreviewLayer()
            if preview == nil, (oldValue == nil) != (thumbnail == nil) { invalidate() }
        }
    }
    var preview: CGImage? {
        didSet {
            guard oldValue !== preview else { return }
            if PreviewRenderer.usesReferenceRenderer { invalidate() }
            else {
                updatePreviewLayer()
                // Only image/placeholder transitions change the static backing-store drawing.
                if (oldValue == nil) != (preview == nil) { invalidate() }
            }
        }
    }
    var previewLabel = "Icon preview" { didSet { if oldValue != previewLabel { invalidate() } } }
    var selected = false {
        didSet {
            guard oldValue != selected else { return }
            setAccessibilityValue(selected ? "Selected" : "Not selected")
            invalidate()
        }
    }
    var matches = true { didSet { if oldValue != matches { invalidate(); updatePreviewLayer() } } }
    var isVacancyPinned = false { didSet { if oldValue != isVacancyPinned { invalidate() } } }
    var dragEnabled = false
    var onDoubleClick: ((WindowIdentity) -> Void)?
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
            previewLayer.contentsGravity = .resizeAspect
            previewLayer.minificationFilter = .trilinear
            previewLayer.magnificationFilter = .linear
            previewLayer.isHidden = true
            layer?.addSublayer(previewLayer)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setEnabledIfChanged(_ enabled: Bool) { if isEnabled != enabled { isEnabled = enabled } }

    /// Drops window content and per-session decoration; keeps the view for reuse.
    func releasePayload() {
        preview = nil
        thumbnail = nil
        previewLabel = "Icon preview"
        layoutBadge = nil
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
        if changed, !PreviewRenderer.usesReferenceRenderer { updatePreviewLayer() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if !PreviewRenderer.usesReferenceRenderer { updatePreviewLayer() }
    }

    private func updatePreviewLayer() {
        guard !PreviewRenderer.usesReferenceRenderer else { return }
        let visible = preview != nil || thumbnail != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if visible {
            let target = NSRect(x: 14, y: 13, width: max(0, bounds.width - 28), height: max(0, bounds.height - 66))
            previewLayer.frame = convertToLayer(target)
            previewLayer.contentsScale = window?.backingScaleFactor ?? 1
            previewLayer.opacity = matches ? 1 : 0.24
        }
        previewLayer.contents = preview ?? thumbnail
        previewLayer.isHidden = !visible
        CATransaction.commit()
        setAccessibilityHelp(preview != nil ? "Live window preview" : thumbnail != nil ? "Static window snapshot" : previewLabel)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let record { onDoubleClick?(record.id); return }
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
        guard let record else {
            drawText(isVacancyPinned ? "Pinned vacancy" : "Vacant slot", in: NSRect(x: 18, y: 68, width: bounds.width - 36, height: 24), font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
            NSGraphicsContext.restoreGraphicsState(); return
        }
        let target = NSRect(x: 14, y: 13, width: bounds.width - 28, height: bounds.height - 66)
        if let preview = preview ?? thumbnail {
            if PreviewRenderer.usesReferenceRenderer {
                let scale = min(target.width / CGFloat(preview.width), target.height / CGFloat(preview.height))
                let area = NSRect(x: target.midX - CGFloat(preview.width) * scale / 2, y: target.midY - CGFloat(preview.height) * scale / 2, width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)).draw(in: area)
            }
        } else { icon?.draw(in: NSRect(x: target.midX - 30, y: target.midY - 30, width: 60, height: 60)) }
        drawText(record.appName + (layoutBadge.map { " · " + $0 } ?? "") + (isVacancyPinned ? "  • pinned" : ""), in: NSRect(x: 15, y: bounds.height - 53, width: bounds.width - 30, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        drawText(record.title, in: NSRect(x: 15, y: bounds.height - 34, width: bounds.width - 30, height: 17), font: .systemFont(ofSize: 11), color: .labelColor)
        drawText(preview != nil ? "● Live" : thumbnail != nil ? "◷ Snapshot" : record.isMinimized ? "Minimized" : "", in: NSRect(x: 15, y: bounds.height - 18, width: bounds.width - 30, height: 13), font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        NSGraphicsContext.restoreGraphicsState()
    }
}
