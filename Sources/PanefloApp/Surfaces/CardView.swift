import AppKit
import QuartzCore
import PanefloCore

/// One window card, Overview slot (bound, free or kept), or the Desktop entry (`isDesktopEntry`).
///
/// Everything visible is a layer from `CardChrome`; the view never draws into a backing store. Selection, the
/// partner ring, hover, drop targets and search dimming change a handful of layer properties with implicit
/// animations off, so a selection step touches only the cards whose state changed and does no layout, drawing or
/// image work. Text layers change only when the card's record changes.
@MainActor
final class CardView: NSButton {
    /// What the preview layer shows. A live frame is retained only while it is displayed.
    enum PreviewPixels {
        case none
        case snapshot(CGImage)
        case live(LiveFrame)

        var hasContent: Bool { if case .none = self { false } else { true } }
    }

    /// An Overview slot without a window.
    enum Vacancy: Equatable {
        /// Where a closed window was; the next new window takes it.
        case free
        /// A pinned slot waiting for a window of its app.
        case kept(appName: String?)
    }

    /// How this card sits in a tile pair.
    enum PairRole: Equatable {
        case none
        /// The pair's first member with its partner directly to the right: carries the seam link chip.
        case leading
        /// The second member, directly right of its partner.
        case trailing
        /// Paired with a window that is not adjacent: a small link chip in the well.
        case detached
    }

    #if PANEFLO_NATIVE_CHECK
    /// Counts backing-store invalidations so own-window checks can assert redraw scope (cards never draw).
    static var invalidations = 0
    /// Cards whose selection chrome changed since the last reset.
    static var selectionChromeChanges: Set<ObjectIdentifier> = []
    #endif

    let chrome = CardChrome()
    private var palette: CardPalette?
    private static let homeTitleColor = NSColor.white.cgColor
    private static let homeSubtitleColor = NSColor.white.withAlphaComponent(0.8).cgColor
    private var appliedScale: CGFloat = 0

    var style = CardStyle.switcher(.medium) {
        didSet { guard oldValue != style else { return }; applyFonts(); applyLayout(); applyText() }
    }
    var record: WindowRecord? {
        didSet {
            guard oldValue != record else { return }
            // A slot card rebound to another window must never show the previous window's pixels.
            if oldValue?.id != record?.id, hasPreviewState || pixels.hasContent { clearPreview() }
            updateAccessibilityLabel()
            withoutAnimation { applyText(); applyContent(); applyStatus(); applyVacancy() }
        }
    }
    var icon: NSImage? {
        didSet { guard oldValue !== icon else { return }; withoutAnimation { applyIcon() } }
    }
    /// Arrangement feedback ("Left half", "Right half", "Fill screen") shown as a corner glyph for the session.
    var layoutBadge: String? {
        didSet { guard oldValue != layoutBadge else { return }; updateAccessibilityLabel(); withoutAnimation { applyCorner() } }
    }
    /// The tile partner's app name, for the spoken label; nil when unpaired.
    var pairPartnerName: String? {
        didSet { if oldValue != pairPartnerName { updateAccessibilityLabel() } }
    }
    var pairRole = PairRole.none {
        didSet { guard oldValue != pairRole else { return }; withoutAnimation { applyPairChips() } }
    }
    /// The half the selected card would take in a snap-assist pairing, as a faint corner glyph; nil hides it.
    var snapGhost: LayoutZone? {
        didSet { guard oldValue != snapGhost else { return }; withoutAnimation { applyCorner() } }
    }
    /// The Desktop pseudo-entry: titled "Desktop", shows the wallpaper (or a placeholder) and never a window preview.
    /// It has no `record`, so it is never reported to the capture engine.
    var isDesktopEntry = false {
        didSet {
            guard oldValue != isDesktopEntry else { return }
            clearPreview()
            updateAccessibilityLabel()
            withoutAnimation { applyLayout(); applyText(); applyContent(); applyStatus(); applyVacancy() }
        }
    }
    /// The desktop is the current state: choosing the entry brings the windows back instead of showing the desktop.
    var desktopIsCurrent = false {
        didSet {
            guard oldValue != desktopIsCurrent, isDesktopEntry else { return }
            updateAccessibilityLabel()
            withoutAnimation { applyText() }
        }
    }
    var vacancy: Vacancy? {
        didSet { guard oldValue != vacancy else { return }; updateAccessibilityLabel(); withoutAnimation { applyText(); applyVacancy(); applySelection() } }
    }
    /// The kept slot's app icon (drawn faint in the well).
    var vacancyIcon: NSImage? {
        didSet { guard oldValue !== vacancyIcon else { return }; withoutAnimation { applyVacancy() } }
    }
    /// A pinned Overview slot: pin glyph in the corner.
    var isPinned = false {
        didSet { guard oldValue != isPinned else { return }; updateAccessibilityLabel(); withoutAnimation { applyCorner() } }
    }
    /// What choosing this card selects.
    var switchTarget: SwitchTarget? { isDesktopEntry ? .desktop : record.map { .window($0.id) } }
    private(set) var pixels = PreviewPixels.none
    /// The engine's label ("Live", "Snapshot · 3s", "Unavailable: minimized"...), nil without preview state. Spoken,
    /// never shown as text.
    private(set) var previewLabel: String?
    private(set) var presentation: PreviewPresentation?
    var previewIsLive: Bool { presentation?.isLive ?? false }
    /// False after `releasePayload` until the next preview update; the coordinator then asks the
    /// engine for this card's current state.
    private(set) var hasPreviewState = false
    private(set) var indicator = PreviewIndicator.none
    var selected = false {
        didSet {
            guard oldValue != selected else { return }
            setAccessibilityValue(selected ? "Selected" : "Not selected")
            withoutAnimation { applySelection() }
        }
    }
    /// The selection's tile partner: drawn with the dashed "comes along" ring.
    var isPartnerHighlighted = false {
        didSet { guard oldValue != isPartnerHighlighted else { return }; withoutAnimation { applySelection() } }
    }
    var matches = true {
        didSet { guard oldValue != matches else { return }; withoutAnimation { applySelection() } }
    }
    /// A dragged card is over this one: drop highlight (accent outline; a vacancy shows its drop state).
    var isDropTarget = false {
        didSet {
            guard oldValue != isDropTarget else { return }
            animatedIfAllowed(PanefloStyle.Motion.dropTarget) { applySelection(); applyVacancy() }
        }
    }
    /// The card being dragged keeps its cell but fades, like a free slot.
    var isDragOrigin = false {
        didSet { guard oldValue != isDragOrigin else { return }; withoutAnimation { applySelection() } }
    }
    private(set) var isHovered = false
    /// Overview only: hover feedback and on-hover tooltips with the preview state. The held switcher has neither.
    var hoverEnabled = false {
        didSet { guard oldValue != hoverEnabled else { return }; updateTrackingAreas(); updateToolTipRect() }
    }
    var dragEnabled = false
    var onDoubleClick: ((SwitchTarget) -> Void)?
    var onDragMove: ((Int, NSPoint) -> Void)?
    var onDragEnd: ((Int, NSPoint) -> Void)?
    /// Context menus are built only when AppKit asks for one (right-click or Control-click).
    var menuProvider: ((CardView) -> NSMenu?)?
    private var hoverArea: NSTrackingArea?
    private var toolTipTag: NSView.ToolTipTag?

    override var isFlipped: Bool { true }
    /// The held picker is never key; a click must still select on the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 168) }
    /// Cards are placed by frame, but the glass shelf's window keeps a constraint engine, so every card move asks for
    /// alignment insets. NSButton derives them from its title metrics (font and attribute lookups per card, measured
    /// at about half of a warm 60-card present); a card has no title, so its alignment rect is its frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var wantsUpdateLayer: Bool { true }
    /// The ring and the pair seam sit outside the card bounds; the card never clips them.
    override var clipsToBounds: Bool { get { false } set {} }
    override var wantsDefaultClipping: Bool { false }
    override func updateLayer() { if layer?.masksToBounds == true { layer?.masksToBounds = false } }
    override func draw(_ dirtyRect: NSRect) {}
    #if PANEFLO_NATIVE_CHECK
    override var needsDisplay: Bool {
        didSet { if needsDisplay { CardView.invalidations += 1 } }
    }
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = true
        // Cards move on every MRU change; nobody observes their geometry.
        postsFrameChangedNotifications = false
        postsBoundsChangedNotifications = false
        setAccessibilityValue("Not selected")
        wantsLayer = true
        // The selection ring and the pair seam sit just outside the card, inside the cell gutter.
        clipsToBounds = false
        layerContentsRedrawPolicy = .never
        if let layer {
            layer.cornerCurve = .continuous
            chrome.install(in: layer)
        }
        applyFonts()
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setEnabledIfChanged(_ enabled: Bool) { if isEnabled != enabled { isEnabled = enabled } }

    /// Drops window content and per-session decoration; keeps the view for reuse.
    func releasePayload() {
        clearPreview()
        layoutBadge = nil
        snapGhost = nil
        isPartnerHighlighted = false
        isDropTarget = false
        isDragOrigin = false
        setHovered(false)
    }

    /// Renders one engine update. `.keep` changes the state only.
    func showPreview(_ update: PreviewUpdate, now: Double = ProcessInfo.processInfo.systemUptime) {
        withoutAnimation {
            switch update.content {
            case .live(let frame): setPixels(.live(frame))
            case .snapshot(let image): setPixels(.snapshot(image))
            case .keep: break
            case .none: setPixels(.none)
            }
            hasPreviewState = true
            setPresentation(update.presentation, label: update.label(now: now))
        }
    }

    /// The Desktop entry's wallpaper; nil shows the placeholder. Never labelled live.
    func showWallpaper(_ image: CGImage?) {
        guard isDesktopEntry else { return }
        withoutAnimation {
            setPixels(image.map { .snapshot($0) } ?? .none)
            setPresentation(nil, label: image == nil ? nil : "Wallpaper")
        }
    }

    /// Back to the app icon with no preview state (previews off, card reused, surface hidden).
    func clearPreview() {
        guard pixels.hasContent || hasPreviewState || presentation != nil || previewLabel != nil else { return }
        withoutAnimation {
            setPixels(.none)
            hasPreviewState = false
            setPresentation(nil, label: nil)
        }
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
        applyPixels()
        if hadContent != next.hasContent { applyContent() }
    }

    private func setPresentation(_ next: PreviewPresentation?, label: String?) {
        previewLabel = label
        guard next != presentation else { return }
        presentation = next
        applyStatus()
    }

    /// The preview well in view coordinates (flipped); shared by layers and capture sizing.
    var previewRect: NSRect {
        if isDesktopEntry, style.isOverview { return bounds }
        return style.wellRect(in: bounds)
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { applyLayout(); updateToolTipRect() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Re-resolves colors (appearance, accent or Increase Contrast changed).
    func refreshColors() {
        palette = nil
        withoutAnimation { applyColors(); applyLayout() }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// The card's rect in its own layer space, from the view size (AppKit syncs the backing layer's bounds later).
    private var cardLayerRect: CGRect { CGRect(origin: .zero, size: bounds.size) }

    private func applyFonts() {
        chrome.title.font = style.titleFont
        chrome.title.fontSize = style.titleFont.pointSize
        chrome.subtitle.font = style.subtitleFont
        chrome.subtitle.fontSize = style.subtitleFont.pointSize
    }

    /// Frames for every layer. Runs when the card is resized, restyled or moved to another display, never on selection.
    private func applyLayout() {
        guard let layer else { return }
        withoutAnimation {
            let scale = self.scale
            let contrast = currentPalette.increaseContrast
            layer.cornerRadius = style.cornerRadius
            if layer.masksToBounds { layer.masksToBounds = false }
            let well = convertToLayer(previewRect)
            chrome.well.frame = well
            chrome.well.cornerRadius = isDesktopEntry && style.isOverview ? style.cornerRadius : style.wellRadius
            let wellBounds = chrome.well.bounds
            chrome.preview.frame = wellBounds
            chrome.placeholder.frame = wellBounds
            chrome.homeScrim.frame = CGRect(x: 0, y: wellBounds.maxY - 54, width: wellBounds.width, height: 54)
            let glyphSize = min(30, wellBounds.height * 0.4)
            chrome.placeholderGlyph.frame = CGRect(x: wellBounds.midX - glyphSize / 2, y: wellBounds.midY - glyphSize / 2,
                                                   width: glyphSize, height: glyphSize)
            let iconSize = style.iconSize(for: previewRect)
            chrome.icon.frame = CGRect(x: wellBounds.midX - iconSize / 2, y: wellBounds.midY - iconSize / 2, width: iconSize, height: iconSize)
            let inset = PanefloStyle.Switcher.wellInset
            let badgeSize = style.badgeSize
            chrome.badge.frame = CGRect(x: inset, y: wellBounds.maxY - inset - badgeSize, width: badgeSize, height: badgeSize)
            let chip = ChipLayer.diameter
            chrome.status.place(at: CGPoint(x: inset, y: inset))
            chrome.corner.place(at: CGPoint(x: wellBounds.maxX - inset - chip, y: inset))
            chrome.link.place(at: CGPoint(x: wellBounds.maxX - inset - chip, y: wellBounds.maxY - inset - chip))
            // The seam chip sits in the gap to the right partner, centred on the wells.
            let gap = style.isOverview ? PanefloStyle.Overview.gridGap : PanefloStyle.Switcher.gridGap + 2 * PanefloStyle.Switcher.cellGutter
            chrome.seam.place(at: CGPoint(x: bounds.width + gap / 2 - 10, y: well.midY - 10), diameter: 20)
            let homeTile = isDesktopEntry && style.isOverview
            var titleRect = style.titleRect(in: bounds), subtitleRect = style.subtitleRect(in: bounds)
            if homeTile {
                titleRect = NSRect(x: 12, y: bounds.height - 40, width: bounds.width - 24, height: 16)
                subtitleRect = NSRect(x: 12, y: bounds.height - 22, width: bounds.width - 24, height: 15)
            }
            chrome.title.frame = convertToLayer(titleRect)
            chrome.subtitle.frame = convertToLayer(subtitleRect)
            chrome.layoutRings(cardBounds: cardLayerRect, cornerRadius: style.cornerRadius, contrast: contrast)
            if let vacancy = chrome.vacancy {
                vacancy.frame = cardLayerRect
                vacancy.layout(scale: scale)
            }
            if appliedScale != scale {
                appliedScale = scale
                for sublayer in [chrome.title, chrome.subtitle, chrome.preview, chrome.icon, chrome.badge] as [CALayer] {
                    sublayer.contentsScale = scale
                }
                applyIcon(); applyStatus(); applyCorner(); applyPairChips(); applyVacancy(); applyContent()
            }
        }
    }

    // MARK: State → layers

    private var currentPalette: CardPalette {
        if let palette { return palette }
        let resolved = CardPalette.resolve(for: effectiveAppearance)
        palette = resolved
        return resolved
    }

    private func applyColors() {
        let palette = currentPalette
        chrome.ring.strokeColor = palette.ring
        chrome.partnerRing.strokeColor = palette.partnerRing
        chrome.well.backgroundColor = palette.well
        chrome.placeholder.colors = {
            let (start, end) = PanefloStyle.Color.desktopGradient
            return [PanefloStyle.cgColor(start, for: effectiveAppearance), PanefloStyle.cgColor(end, for: effectiveAppearance)]
        }()
        chrome.placeholderGlyph.backgroundColor = palette.secondaryLabel
        layer?.borderColor = palette.contrastBorder
        applySelection(); applyText(); applyStatus(); applyCorner(); applyPairChips(); applyVacancy()
    }

    private func applySelection() {
        guard let layer else { return }
        #if PANEFLO_NATIVE_CHECK
        CardView.selectionChromeChanges.insert(ObjectIdentifier(self))
        #endif
        let palette = currentPalette
        let isVacant = vacancy != nil && record == nil && !isDesktopEntry
        let fill: CGColor = isVacant ? palette.clear : selected ? palette.selectedFill : isHovered ? palette.hoverFill : palette.fill
        if layer.backgroundColor != fill { layer.backgroundColor = fill }
        let dropOnCard = isDropTarget && !isVacant
        let border: CGFloat = dropOnCard ? PanefloStyle.Stroke.dropTarget : palette.increaseContrast && !isVacant ? PanefloStyle.Stroke.contrastBorder : 0
        if layer.borderWidth != border { layer.borderWidth = border }
        let borderColor = dropOnCard ? palette.accent : palette.contrastBorder
        if layer.borderColor != borderColor { layer.borderColor = borderColor }
        if chrome.ring.isHidden == selected { chrome.ring.isHidden = !selected }
        let partner = isPartnerHighlighted && !selected
        if chrome.partnerRing.isHidden == partner { chrome.partnerRing.isHidden = !partner }
        let opacity: CGFloat = isDragOrigin ? 0.3 : matches ? 1 : 0.28
        if alphaValue != opacity { alphaValue = opacity }
    }

    private func applyText() {
        let palette = currentPalette
        let homeTile = isDesktopEntry && style.isOverview
        var title = "", subtitle = ""
        if isDesktopEntry {
            title = SwitcherSession.desktopTitle
            subtitle = desktopIsCurrent ? "Bring your windows back" : "Show the desktop"
        } else if let record {
            let ownTitle = record.title.trimmingCharacters(in: .whitespaces)
            if ownTitle.isEmpty || ownTitle == record.appName {
                title = record.appName
            } else {
                title = ownTitle
                subtitle = record.appName
            }
        }
        let vacant = record == nil && !isDesktopEntry
        if (chrome.title.string as? String) != title { chrome.title.string = title }
        if (chrome.subtitle.string as? String) != subtitle { chrome.subtitle.string = subtitle }
        hide(chrome.title, vacant || title.isEmpty)
        hide(chrome.subtitle, vacant || subtitle.isEmpty || (!style.showsSubtitle && !homeTile))
        let titleColor = homeTile ? CardView.homeTitleColor : palette.label
        let subtitleColor = homeTile ? CardView.homeSubtitleColor : palette.secondaryLabel
        if chrome.title.foregroundColor !== titleColor { chrome.title.foregroundColor = titleColor }
        if chrome.subtitle.foregroundColor !== subtitleColor { chrome.subtitle.foregroundColor = subtitleColor }
    }

    private func applyPixels() {
        switch pixels {
        case .none: chrome.preview.contents = nil
        case .snapshot(let image): chrome.preview.contents = image
        case .live(let frame):
            if PreviewRenderer.usesReferenceRenderer {
                // Developer A/B renderer: a CPU image of the frame instead of the zero-copy surface.
                chrome.preview.contents = CaptureController.borrowedImage(from: frame)
            } else {
                // Zero-copy: the layer samples the frame's IOSurface. A recycled surface object must still register
                // as new content.
                if let current = chrome.preview.contents as AnyObject?, current === frame.surface { chrome.preview.contents = nil }
                chrome.preview.contents = frame.surface
            }
        }
    }

    /// Which content the well shows: pixels, the big app icon, the Desktop placeholder, or nothing (vacancy).
    private func applyContent() {
        let hasPixels = pixels.hasContent
        let vacant = record == nil && !isDesktopEntry
        hide(chrome.well, vacant)
        hide(chrome.preview, !hasPixels)
        let gravity: CALayerContentsGravity = isDesktopEntry ? .resizeAspectFill : .resizeAspect
        if chrome.preview.contentsGravity != gravity { chrome.preview.contentsGravity = gravity }
        hide(chrome.placeholder, !isDesktopEntry || hasPixels)
        hide(chrome.placeholderGlyph, !isDesktopEntry || hasPixels)
        if !chrome.placeholderGlyph.isHidden {
            chrome.placeholderGlyph.setSymbol("menubar.dock.rectangle", pointSize: 28, weight: .light, scale: scale)
        }
        hide(chrome.homeScrim, !(isDesktopEntry && style.isOverview))
        applyIcon()
    }

    /// Layer property sets are not free even with actions off; set only what changed.
    private func hide(_ layer: CALayer, _ hidden: Bool) { if layer.isHidden != hidden { layer.isHidden = hidden } }
    private func setOpacity(_ layer: CALayer, _ value: Float) { if layer.opacity != value { layer.opacity = value } }

    private func applyContentOpacity(_ opacity: Float) {
        setOpacity(chrome.preview, isDesktopEntry ? 1 : opacity)
        setOpacity(chrome.icon, opacity)
    }

    private func applyIcon() {
        let hasPixels = pixels.hasContent
        let showsBig = record != nil && !isDesktopEntry && icon != nil && !hasPixels
        let showsBadge = record != nil && !isDesktopEntry && icon != nil && hasPixels
        if (showsBig || showsBadge), let icon {
            let prepared = IconContents.contents(for: icon, scale: scale)
            for target in [chrome.icon, chrome.badge] where (target.contents as AnyObject?) !== (prepared.contents as AnyObject) {
                target.contentsScale = prepared.scale
                target.contents = prepared.contents
            }
        }
        hide(chrome.icon, !showsBig)
        hide(chrome.badge, !showsBadge)
        applyContentOpacity(Float(PreviewIndicator.resolve(presentation, isMinimized: record?.isMinimized ?? false).contentOpacity))
    }

    private func applyStatus() {
        let resolved: (indicator: PreviewIndicator, contentOpacity: Double) = isDesktopEntry || record == nil ? (.none, 1.0)
            : PreviewIndicator.resolve(presentation, isMinimized: record?.isMinimized ?? false)
        indicator = resolved.indicator
        let symbol: String? = switch resolved.indicator {
        case .none: nil
        case .minimized: "minus"
        case .appHidden: "eye.slash"
        case .otherSpace: "square.on.square"
        case .paused: "pause.fill"
        }
        let palette = currentPalette
        chrome.status.show(symbol, fill: palette.chipFill, tint: palette.chipGlyph, scale: scale)
        applyContentOpacity(Float(resolved.1))
    }

    private func applyCorner() {
        let palette = currentPalette
        if let snapGhost, record != nil {
            let symbol = snapGhost == .leftHalf ? "rectangle.lefthalf.filled" : snapGhost == .rightHalf ? "rectangle.righthalf.filled" : "rectangle.fill"
            chrome.corner.show(symbol, fill: palette.ghostFill, tint: palette.chipGlyph, scale: scale)
            return
        }
        let symbol: String? = switch layoutBadge {
        case "Left half"?: "rectangle.lefthalf.filled"
        case "Right half"?: "rectangle.righthalf.filled"
        case .some: "rectangle.fill"
        case nil: isPinned && record != nil ? "pin.fill" : nil
        }
        chrome.corner.show(symbol, fill: palette.accent, tint: palette.chipGlyph, scale: scale)
    }

    private func applyPairChips() {
        let palette = currentPalette
        chrome.link.show(pairRole == .detached && record != nil ? "link" : nil, fill: palette.chipFill, tint: palette.chipGlyph, scale: scale)
        let seam = pairRole == .leading && record != nil
        chrome.seam.show(seam ? "link" : nil, fill: palette.seamFill, tint: palette.seamGlyph, scale: scale, glyphSize: 10)
        chrome.seam.borderWidth = seam ? 0.5 : 0
        chrome.seam.borderColor = palette.seamBorder
    }

    private func applyVacancy() {
        guard let layer else { return }
        let vacant = record == nil && !isDesktopEntry && vacancy != nil
        guard vacant || chrome.vacancy != nil else { return }
        let vacancyLayer = chrome.vacancyLayer(in: layer)
        vacancyLayer.isHidden = !vacant
        guard vacant else { return }
        if vacancyLayer.frame != cardLayerRect { vacancyLayer.frame = cardLayerRect; vacancyLayer.layout(scale: scale) }
        var keptName: String?
        var kept = false
        if case .kept(let name) = vacancy { kept = true; keptName = name }
        if kept, let vacancyIcon {
            let prepared = IconContents.contents(for: vacancyIcon, scale: scale)
            vacancyLayer.keptIcon.contentsScale = prepared.scale
            vacancyLayer.keptIcon.contents = prepared.contents
        } else {
            vacancyLayer.keptIcon.contents = nil
        }
        let state: VacancyLayer.State = isDropTarget ? .dropTarget : isHovered ? .hover : .rest
        vacancyLayer.apply(kept: kept, keptName: keptName, state: state, palette: currentPalette,
                           contrast: currentPalette.increaseContrast, scale: scale)
    }

    // MARK: Hover and tooltips (Overview only)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea); self.hoverArea = nil }
        guard hoverEnabled else { setHovered(false); return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { if hoverEnabled { setHovered(true) } }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        withoutAnimation { applySelection(); applyVacancy() }
    }

    private func updateToolTipRect() {
        if let toolTipTag { removeToolTip(toolTipTag); self.toolTipTag = nil }
        guard hoverEnabled, bounds.width > 0 else { return }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    /// Built only when AppKit is about to show the tooltip: the full title and the preview state.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if isDesktopEntry { return desktopIsCurrent ? "Desktop — bring your windows back" : "Desktop — show the desktop" }
        guard let record else {
            if case .kept(let name)? = vacancy { return "Slot kept for \(name ?? "an app"). A window of that app returns here." }
            return "Free slot. The next window you open takes it; drag a window here to place it."
        }
        var lines = [record.title.isEmpty ? record.appName : record.title]
        var detail = [record.appName]
        if let state = spokenPreviewState { detail.append(state) }
        if let pairPartnerName { detail.append("tiled with \(pairPartnerName)") }
        lines.append(detail.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    // MARK: Accessibility

    private func updateAccessibilityLabel() {
        if isDesktopEntry {
            setAccessibilityLabel(desktopIsCurrent ? "Desktop, bring your windows back" : "Desktop, show the desktop")
        } else if let record {
            var label = "\(record.appName), \(record.title)"
            if let pairPartnerName { label += ", tiled with \(pairPartnerName)" }
            if isPinned { label += ", pinned" }
            setAccessibilityLabel(label)
        } else if case .kept(let name)? = vacancy {
            setAccessibilityLabel("Slot kept for \(name ?? "an app")")
        } else {
            setAccessibilityLabel("Free slot")
        }
    }

    /// The preview state in words: what the picture is (live, a snapshot and its age) or why there is none.
    private var spokenPreviewState: String? {
        if let presentation {
            switch presentation {
            case .live: return "Live window preview"
            case .snapshot(let capturedAt, let note):
                let age = PreviewLabel.age(ProcessInfo.processInfo.systemUptime - capturedAt)
                return "Snapshot, \(age) old" + (note.map { ", " + PreviewLabel.short($0) } ?? "")
            default: return previewLabel
            }
        }
        return indicator.spokenState ?? (record?.isMinimized == true ? "Minimized" : nil)
    }

    /// Computed on request so preview updates never pay for accessibility bookkeeping.
    override func accessibilityHelp() -> String? {
        if isDesktopEntry { return pixels.hasContent ? "Desktop wallpaper" : nil }
        guard record != nil else {
            return vacancy == .free ? "The next window you open takes this slot" : nil
        }
        return spokenPreviewState ?? "App icon"
    }

    // MARK: Input

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(self) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let switchTarget { onDoubleClick?(switchTarget); return }
        guard dragEnabled, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        var dragged = false
        isHighlighted = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 5 { dragged = true }
            if next.type == .leftMouseDragged, dragged { onDragMove?(tag, next.locationInWindow) }
            if next.type == .leftMouseUp {
                isHighlighted = false
                if dragged { onDragEnd?(tag, next.locationInWindow) }
                else { _ = sendAction(action, to: target) }
                break
            }
        }
    }

    // MARK: Helpers

    private func withoutAnimation(_ body: () -> Void) { PanefloStyle.withoutAnimation(body) }

    /// Drop feedback eases in over `duration` unless Reduce Motion is on.
    private func animatedIfAllowed(_ duration: CFTimeInterval, _ body: () -> Void) {
        let value = PanefloStyle.Motion.duration(duration)
        withoutAnimation(body)
        guard value > 0, let layer else { return }
        // Card layers never animate implicitly; drop feedback crossfades explicitly (drag time only).
        let fade = CATransition()
        fade.type = .fade
        fade.duration = value
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "dropTarget")
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckLayerContents: AnyObject? { chrome.preview.contents as AnyObject? }
    /// The spoken preview label (no text is shown on cards).
    var nativeCheckStatusText: String? { previewLabel }
    var nativeCheckIndicatorSymbol: String? { chrome.status.isHidden ? nil : chrome.status.glyph.symbolName }
    var nativeCheckCornerSymbol: String? { chrome.corner.isHidden ? nil : chrome.corner.glyph.symbolName }
    var nativeCheckSeamVisible: Bool { !chrome.seam.isHidden }
    var nativeCheckRingVisible: Bool { !chrome.ring.isHidden }
    var nativeCheckRingDebug: String {
        "hidden=\(chrome.ring.isHidden) frame=\(chrome.ring.frame) path=\(chrome.ring.path?.boundingBox ?? .zero) width=\(chrome.ring.lineWidth) stroke=\(String(describing: chrome.ring.strokeColor)) super=\(chrome.ring.superlayer === layer) masks=\(layer?.masksToBounds ?? false) sublayers=\(layer?.sublayers?.count ?? 0) layerbounds=\(layer?.bounds ?? .zero)"
    }
    var nativeCheckPartnerRingVisible: Bool { !chrome.partnerRing.isHidden }
    var nativeCheckTitle: String? { chrome.title.isHidden ? nil : chrome.title.string as? String }
    var nativeCheckSubtitle: String? { chrome.subtitle.isHidden ? nil : chrome.subtitle.string as? String }
    var nativeCheckVacancyLabel: String? { chrome.vacancy.flatMap { $0.isHidden ? nil : $0.label.string as? String } }
    var nativeCheckVacancyHintOpacity: Float? { chrome.vacancy?.hoverHint.opacity }
    var nativeCheckVacancyDropLabelOpacity: Float? { chrome.vacancy?.dropLabel.opacity }
    var nativeCheckBadgeVisible: Bool { !chrome.badge.isHidden }
    /// True when any chrome layer has a running animation (selection must never animate).
    var nativeCheckAnimating: Bool {
        ([layer, chrome.ring, chrome.partnerRing, chrome.well] as [CALayer?]).contains { ($0?.animationKeys() ?? []).isEmpty == false }
    }
    func nativeCheckSetHovered(_ hovered: Bool) { setHovered(hovered) }
    func nativeCheckToolTip() -> String { view(self, stringForToolTip: 0, point: .zero, userData: nil) }
    var nativeCheckHasToolTip: Bool { toolTipTag != nil }
    #endif
}
