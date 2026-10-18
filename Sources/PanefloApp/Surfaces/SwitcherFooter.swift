import AppKit
import QuartzCore

/// The switcher's one line under the cards: the selected window's full title and its app (cards truncate titles).
/// No instructions or key hints live here. A selection change sets one attributed string on one text layer; the view
/// never lays out or draws.
@MainActor
final class FocusLineView: NSView {
    static let height = PanefloStyle.Switcher.focusLineHeight
    private let text = CATextLayer()
    private var current: (title: String, app: String, partner: String?)?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        text.actions = GlyphLayer.noActions
        text.alignmentMode = .center
        text.truncationMode = .middle
        text.isWrapped = false
        layer?.addSublayer(text)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        PanefloStyle.withoutAnimation {
            text.frame = CGRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width, height: 17)
            text.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let current { render(current) }
    }

    /// Shows `title — app` (and the tile partner); empty strings clear the line.
    func show(title: String, app: String, partner: String? = nil) {
        let next = (title, app, partner)
        if let current, current == next { return }
        current = next
        render(next)
    }

    private func render(_ value: (title: String, app: String, partner: String?)) {
        let appearance = effectiveAppearance
        let fg = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let line = NSMutableAttributedString(string: value.title, attributes: [
            .font: PanefloStyle.Font.focusTitle, fg: PanefloStyle.cgColor(.labelColor, for: appearance)])
        var detail = value.title.isEmpty || value.app.isEmpty || value.app == value.title ? "" : "  " + value.app
        if value.title.isEmpty { detail = value.app }
        if let partner = value.partner { detail += "  ·  with \(partner)" }
        line.append(NSAttributedString(string: detail, attributes: [
            .font: PanefloStyle.Font.focusApp, fg: PanefloStyle.cgColor(.secondaryLabelColor, for: appearance)]))
        PanefloStyle.withoutAnimation { text.string = line }
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckText: String? { (text.string as? NSAttributedString)?.string }
    #endif
}
