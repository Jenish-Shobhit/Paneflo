import AppKit
import QuartzCore

/// Card colors resolved to `CGColor`s for one appearance, contrast setting and accent color. Shared by every card
/// (resolved once per combination), so an appearance change costs one resolve per surface, not per card.
@MainActor
struct CardPalette {
    let fill, hoverFill, selectedFill, ring, partnerRing, well, contrastBorder: CGColor
    let vacancyFill, vacancyHoverFill, vacancyBorder, vacancyHoverBorder, keptBorder, vacancyInner: CGColor
    let accent, dropFill, label, secondaryLabel, tertiaryLabel, chipFill, chipGlyph, ghostFill: CGColor
    let pairGroup, pairGroupActive, seamFill, seamBorder, seamGlyph, clear: CGColor
    let increaseContrast: Bool

    private static var cache: [String: CardPalette] = [:]
    private static var generation = 0
    private static var observer: NSObjectProtocol?

    /// The accent color or another system color changed: every palette resolves again on next use.
    static func invalidate() { generation += 1; cache.removeAll() }

    static func resolve(for appearance: NSAppearance) -> CardPalette {
        let contrast = PanefloStyle.Accessibility.current.increaseContrast
        let key = "\(PanefloStyle.isDark(appearance))|\(contrast)|\(generation)"
        if let palette = cache[key] { return palette }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                                              queue: .main) { _ in MainActor.assumeIsolated { CardPalette.invalidate() } }
        }
        let palette = CardPalette(appearance: appearance, increaseContrast: contrast)
        cache[key] = palette
        return palette
    }

    private init(appearance: NSAppearance, increaseContrast: Bool) {
        typealias C = PanefloStyle.Color
        let dark = PanefloStyle.isDark(appearance)
        func cg(_ color: NSColor) -> CGColor { PanefloStyle.cgColor(color, for: appearance) }
        fill = cg(C.cardFill); hoverFill = cg(C.cardHoverFill); selectedFill = cg(C.selectedWash(dark: dark))
        ring = cg(C.ring); partnerRing = cg(increaseContrast ? NSColor.controlAccentColor : C.partnerRing)
        well = cg(C.wellFill(dark: dark)); contrastBorder = cg(.separatorColor)
        vacancyFill = cg(C.vacancyFill); vacancyHoverFill = cg(.quaternarySystemFill)
        vacancyBorder = cg(increaseContrast ? .secondaryLabelColor : C.vacancyBorder)
        vacancyHoverBorder = cg(.secondaryLabelColor); keptBorder = cg(C.keptBorder)
        vacancyInner = cg(NSColor.black.withAlphaComponent(dark ? 0 : 0.04))
        accent = cg(.controlAccentColor); dropFill = cg(NSColor.controlAccentColor.withAlphaComponent(0.10))
        label = cg(.labelColor); secondaryLabel = cg(.secondaryLabelColor); tertiaryLabel = cg(.tertiaryLabelColor)
        chipFill = cg(C.chipBackground(increaseContrast: increaseContrast)); chipGlyph = cg(C.chipText)
        ghostFill = cg(NSColor.controlAccentColor.withAlphaComponent(increaseContrast ? 0.8 : 0.45))
        pairGroup = cg(C.pairGroup); pairGroupActive = cg(C.pairGroupActive)
        seamFill = cg(.windowBackgroundColor); seamBorder = cg(.separatorColor); seamGlyph = cg(.secondaryLabelColor)
        clear = NSColor.clear.cgColor
        self.increaseContrast = increaseContrast
    }
}

/// The free/kept slot well: a dashed recessed outline with a symbol, a label and hover/drop hints. Hint layers are
/// built once and swapped by opacity, so hover and drag never re-render text.
final class VacancyLayer: CALayer {
    let border = CAShapeLayer()
    let inner = CAShapeLayer()
    let glyph = GlyphLayer()
    let keptIcon = CALayer()
    let label = CATextLayer()
    let dropLabel = CATextLayer()
    let hoverHint = CATextLayer()

    override init() {
        super.init()
        actions = GlyphLayer.noActions
        for layer in [border, inner] {
            layer.actions = GlyphLayer.noActions
            layer.fillColor = nil
            addSublayer(layer)
        }
        inner.lineWidth = 1
        keptIcon.actions = GlyphLayer.noActions
        keptIcon.contentsGravity = .resizeAspect
        keptIcon.opacity = 0.35
        addSublayer(keptIcon)
        addSublayer(glyph)
        for text in [label, dropLabel, hoverHint] {
            text.actions = GlyphLayer.noActions
            text.alignmentMode = .center
            text.truncationMode = .end
            text.isWrapped = false
            addSublayer(text)
        }
        // PanefloStyle.Font.emptySlotLabel / emptySlotHint (12 medium, 11 regular).
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium), hintFont = NSFont.systemFont(ofSize: 11)
        label.font = labelFont; label.fontSize = 12
        dropLabel.font = labelFont; dropLabel.fontSize = 12
        hoverHint.font = hintFont; hoverHint.fontSize = 11
        dropLabel.string = "Drop to place here"
        hoverHint.string = "Drag a window here"
        dropLabel.opacity = 0
        hoverHint.opacity = 0
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Lays the well out in `bounds` (this layer's own space, geometry flipped like the card).
    @MainActor func layout(scale: CGFloat) {
        let well = bounds.insetBy(dx: 6, dy: 6)
        let path = CGPath(roundedRect: well, cornerWidth: PanefloStyle.Radius.vacancyWell, cornerHeight: PanefloStyle.Radius.vacancyWell, transform: nil)
        border.frame = bounds; border.path = path
        inner.frame = bounds
        inner.path = CGPath(roundedRect: well.insetBy(dx: 1.5, dy: 1.5), cornerWidth: PanefloStyle.Radius.vacancyWell - 1.5,
                            cornerHeight: PanefloStyle.Radius.vacancyWell - 1.5, transform: nil)
        let showsHint = bounds.height >= 150
        let stack: CGFloat = 36 + 6 + 16 + (showsHint ? 16 : 0)
        var y = (bounds.height - stack) / 2
        let glyphSize: CGFloat = 26
        glyph.frame = CGRect(x: bounds.midX - glyphSize / 2, y: y + 5, width: glyphSize, height: glyphSize)
        keptIcon.frame = CGRect(x: bounds.midX - 18, y: y, width: 36, height: 36)
        y += 36 + 6
        let line = CGRect(x: well.minX + 8, y: y, width: max(0, well.width - 16), height: 16)
        label.frame = line; dropLabel.frame = line
        hoverHint.frame = line.offsetBy(dx: 0, dy: 16)
        hoverHint.isHidden = !showsHint
        for text in [label, dropLabel, hoverHint] { text.contentsScale = scale }
    }

    enum State { case rest, hover, dropTarget }

    @MainActor func apply(kept: Bool, keptName: String?, state: State, palette: CardPalette, contrast: Bool, scale: CGFloat) {
        let drop = state == .dropTarget
        border.lineWidth = drop ? PanefloStyle.Stroke.dropTarget : PanefloStyle.Stroke.vacancy(increaseContrast: contrast)
        border.lineDashPattern = drop ? nil : PanefloStyle.Stroke.vacancyDash
        border.strokeColor = drop ? palette.accent : state == .hover ? palette.vacancyHoverBorder : kept ? palette.keptBorder : palette.vacancyBorder
        border.fillColor = drop ? palette.dropFill : state == .hover ? palette.vacancyHoverFill : palette.vacancyFill
        inner.strokeColor = palette.vacancyInner
        inner.isHidden = drop
        let showsKeptIcon = kept && keptIcon.contents != nil && !drop
        keptIcon.isHidden = !showsKeptIcon
        glyph.isHidden = showsKeptIcon
        glyph.setSymbol(drop ? "arrow.down.to.line" : "plus.square.dashed", pointSize: 20, weight: .regular, scale: scale)
        glyph.backgroundColor = drop ? palette.accent : palette.tertiaryLabel
        let text = kept ? "Kept for \(keptName ?? "an app")" : "Free slot"
        if (label.string as? String) != text { label.string = text }
        label.foregroundColor = palette.secondaryLabel
        dropLabel.foregroundColor = palette.accent
        hoverHint.foregroundColor = palette.tertiaryLabel
        label.opacity = drop ? 0 : 1
        dropLabel.opacity = drop ? 1 : 0
        // The hint appears only while the pointer is over the slot: no persistent instructions.
        hoverHint.opacity = state == .hover ? 1 : 0
    }
}

/// The layer tree of one card, created once per `CardView` and reused for its lifetime. Nothing here draws into a
/// backing store: selection, hover, search dimming and previews change layer properties only.
@MainActor
final class CardChrome {
    let ring = CAShapeLayer()
    let partnerRing = CAShapeLayer()
    let well = CALayer()
    let placeholder = CAGradientLayer()
    let placeholderGlyph = GlyphLayer()
    let preview = CALayer()
    let icon = CALayer()
    let badge = CALayer()
    let homeScrim = CAGradientLayer()
    let status = ChipLayer()
    let corner = ChipLayer()
    let link = ChipLayer()
    let seam = ChipLayer()
    let title = CATextLayer()
    let subtitle = CATextLayer()
    private(set) var vacancy: VacancyLayer?

    init() {
        for layer in [ring, partnerRing] as [CAShapeLayer] {
            layer.actions = GlyphLayer.noActions
            layer.fillColor = nil
            layer.isHidden = true
        }
        for layer in [well, placeholder, preview, icon, badge, homeScrim, title, subtitle] as [CALayer] { layer.actions = GlyphLayer.noActions }
        well.masksToBounds = true
        well.cornerRadius = PanefloStyle.Radius.well
        well.cornerCurve = .continuous
        preview.contentsGravity = .resizeAspect
        preview.minificationFilter = .linear
        preview.magnificationFilter = .linear
        preview.isHidden = true
        placeholder.startPoint = CGPoint(x: 0, y: 0)
        placeholder.endPoint = CGPoint(x: 1, y: 1)
        placeholder.isHidden = true
        placeholderGlyph.isHidden = true
        icon.contentsGravity = .resizeAspect
        icon.isHidden = true
        badge.contentsGravity = .resizeAspect
        badge.isHidden = true
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = PanefloStyle.Shadow.badgeOpacity
        badge.shadowRadius = PanefloStyle.Shadow.badgeRadius
        badge.shadowOffset = PanefloStyle.Shadow.badgeOffset
        homeScrim.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.45).cgColor]
        homeScrim.isHidden = true
        for layer in [placeholder, placeholderGlyph, preview, icon, badge, homeScrim, status, corner, link] as [CALayer] {
            well.addSublayer(layer)
        }
        for text in [title, subtitle] {
            text.truncationMode = .end
            text.isWrapped = false
            text.alignmentMode = .left
        }
    }

    /// Adds the tree to the card's backing layer (once).
    func install(in host: CALayer) {
        host.addSublayer(well)
        host.addSublayer(title)
        host.addSublayer(subtitle)
        host.addSublayer(partnerRing)
        host.addSublayer(ring)
        host.addSublayer(seam)
    }

    /// The vacancy well, created the first time this card shows a free or kept slot.
    func vacancyLayer(in host: CALayer) -> VacancyLayer {
        if let vacancy { return vacancy }
        let layer = VacancyLayer()
        host.insertSublayer(layer, below: partnerRing)
        vacancy = layer
        return layer
    }

    /// Ring paths follow the card size; they change only when the card is resized.
    func layoutRings(cardBounds: CGRect, cornerRadius: CGFloat, contrast: Bool) {
        let outset = PanefloStyle.Radius.ringOutset
        let ringRect = cardBounds.insetBy(dx: -outset, dy: -outset)
        let radius = cornerRadius + outset
        ring.frame = cardBounds
        ring.path = CGPath(roundedRect: ringRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ring.lineWidth = PanefloStyle.Stroke.ring(increaseContrast: contrast)
        partnerRing.frame = cardBounds
        let partnerRect = cardBounds.insetBy(dx: -3, dy: -3)
        partnerRing.path = CGPath(roundedRect: partnerRect, cornerWidth: cornerRadius + 3, cornerHeight: cornerRadius + 3, transform: nil)
        partnerRing.lineWidth = PanefloStyle.Stroke.partnerRing(increaseContrast: contrast)
        partnerRing.lineDashPattern = PanefloStyle.Stroke.partnerDash(increaseContrast: contrast)
    }
}
