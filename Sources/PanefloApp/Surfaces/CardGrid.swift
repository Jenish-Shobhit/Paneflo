import AppKit
import PanefloCore

/// A scroll-view document that places cards by frame.
///
/// `apply` diffs by key: cards for surviving keys are reused (and only moved when their position changes), new keys
/// get a pooled or new view, removed keys release their payload. Nothing here forces a layout pass; frames are
/// computed directly from the layout, which the surface sets once per presentation. Selection never touches frames.
@MainActor
final class CardGrid: NSView {
    enum Layout: Equatable {
        /// The held switcher: tiered cards, balanced and centred rows, ring gutters around every card.
        case switcher(SwitcherLayout)
        /// The Overview: cards fill the row width inside `inset` (room for the selection ring); slot order is the
        /// user's, so rows are never re-centred.
        case overview(columns: Int, cardHeight: CGFloat, inset: CGFloat)
    }

    override var isFlipped: Bool { true }
    var layout = Layout.overview(columns: 4, cardHeight: 168, inset: 6) {
        didSet { if oldValue != layout { positionCards() } }
    }
    /// Display indices where a tile pair's first card is directly followed by its partner on the same row.
    var pairStarts: Set<Int> = [] {
        didSet { if oldValue != pairStarts { positionBackdrops() } }
    }
    /// Cards in display order.
    private(set) var cards: [CardView] = []
    private var byKey: [AnyHashable: CardView] = [:]
    private var keys: [AnyHashable] = []
    private var pool: [CardView] = []
    private let makeCard: () -> CardView
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    /// Pair group backgrounds, under the cards. Index: pair start.
    private var backdrops: [Int: PairBackdropView] = [:]
    private var backdropPool: [PairBackdropView] = []
    #if PANEFLO_NATIVE_CHECK
    /// Counts frame passes so checks can assert selection never lays out.
    static var positionPasses = 0
    #endif

    init(makeCard: @escaping () -> CardView) {
        self.makeCard = makeCard
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width]
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = PanefloStyle.Font.emptyState
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(emptyLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func card(for key: AnyHashable) -> CardView? { byKey[key] }

    /// Reconciles the displayed cards with `newKeys` and calls `configure` for each card in order.
    /// Returns whether the set or order of keys changed.
    @discardableResult
    func apply(keys newKeys: [AnyHashable], configure: (CardView, Int) -> Void) -> Bool {
        let structural = newKeys != keys
        if structural {
            let incoming = Set(newKeys)
            for (key, card) in byKey where !incoming.contains(key) {
                card.releasePayload()
                card.record = nil
                card.vacancy = nil
                card.isDesktopEntry = false
                card.selected = false
                card.pairRole = .none
                card.pairPartnerName = nil
                card.removeFromSuperview()
                if pool.count < 8 { pool.append(card) }
                byKey.removeValue(forKey: key)
            }
            var ordered: [CardView] = []
            ordered.reserveCapacity(newKeys.count)
            for key in newKeys {
                if let card = byKey[key] { ordered.append(card); continue }
                let card = pool.popLast() ?? makeCard()
                byKey[key] = card
                addSubview(card)
                ordered.append(card)
            }
            cards = ordered
            keys = newKeys
        }
        PanefloStyle.withoutAnimation {
            for (index, card) in cards.enumerated() {
                card.tag = index
                configure(card, index)
            }
        }
        if structural { positionCards() }
        return structural
    }

    func showEmpty(_ message: String?) {
        guard message != nil || !emptyLabel.isHidden else { return }
        emptyLabel.isHidden = message == nil
        if let message, emptyLabel.stringValue != message { emptyLabel.stringValue = message }
        positionCards()
    }

    var columns: Int {
        switch layout {
        case .switcher(let plan): plan.columns
        case .overview(let columns, _, _): max(1, columns)
        }
    }

    var cardHeight: CGFloat {
        switch layout {
        case .switcher(let plan): CGFloat(plan.tier.cardHeight)
        case .overview(_, let height, _): height
        }
    }

    private var gap: CGFloat {
        switch layout {
        case .switcher: CGFloat(SwitcherLayout.gap)
        case .overview: PanefloStyle.Overview.gridGap
        }
    }

    /// Vertical distance between rows.
    var rowPitch: CGFloat {
        switch layout {
        case .switcher(let plan): CGFloat(plan.cellHeight + SwitcherLayout.gap)
        case .overview(_, let height, _): height + PanefloStyle.Overview.gridGap
        }
    }

    var rows: Int {
        guard !cards.isEmpty else { return 0 }
        switch layout {
        case .switcher(let plan): return plan.rows
        case .overview(let columns, _, _): return (cards.count + max(1, columns) - 1) / max(1, columns)
        }
    }

    /// The row a card sits in.
    func row(of index: Int) -> Int {
        switch layout {
        case .switcher(let plan): plan.positions.indices.contains(index) ? plan.positions[index].row : 0
        case .overview(let columns, _, _): index / max(1, columns)
        }
    }

    /// Document height for the current cards; independent of width.
    var contentHeight: CGFloat {
        if cards.isEmpty { return emptyLabel.isHidden ? 0 : 100 }
        return cardsHeight + (emptyLabel.isHidden ? 0 : 10 + 60)
    }

    private var cardsHeight: CGFloat {
        switch layout {
        case .switcher(let plan): CGFloat(plan.gridHeight(rows: plan.rows))
        case .overview(_, let height, let inset): CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * gap + 2 * inset
        }
    }

    /// Frame of card `index` for a document of the given width.
    func frameForCard(at index: Int, width: CGFloat) -> NSRect {
        switch layout {
        case .switcher(let plan):
            guard plan.positions.indices.contains(index) else { return .zero }
            let gutter = CGFloat(SwitcherLayout.gutter)
            let left = max(0, (width - CGFloat(plan.gridWidth)) / 2)
            return NSRect(x: left + CGFloat(plan.cellX(of: index)) + gutter, y: CGFloat(plan.cellY(of: index)) + gutter,
                          width: CGFloat(plan.tier.cardWidth), height: CGFloat(plan.tier.cardHeight))
        case .overview(let columns, let height, let inset):
            let columns = max(1, columns)
            let cardWidth = max(1, ((width - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down))
            let row = index / columns, column = index % columns
            return NSRect(x: inset + CGFloat(column) * (cardWidth + gap), y: inset + CGFloat(row) * (height + gap),
                          width: cardWidth, height: height)
        }
    }

    private func positionCards() {
        #if PANEFLO_NATIVE_CHECK
        CardGrid.positionPasses += 1
        #endif
        let width = superview?.bounds.width ?? bounds.width
        let height = contentHeight
        if frame.size != NSSize(width: width, height: height) { super.setFrameSize(NSSize(width: width, height: height)) }
        for (index, card) in cards.enumerated() {
            let target = frameForCard(at: index, width: width)
            if card.frame.size == target.size {
                if card.frame.origin != target.origin { card.setFrameOrigin(target.origin) }
            } else { card.frame = target }
        }
        if !emptyLabel.isHidden {
            // Below the cards when some remain (the Desktop entry alone), else at the top.
            let labelWidth = min(360, width)
            let target = NSRect(x: ((width - labelWidth) / 2).rounded(), y: cards.isEmpty ? 8 : cardsHeight + 10, width: labelWidth, height: 60)
            if emptyLabel.frame != target { emptyLabel.frame = target }
        }
        positionBackdrops()
    }

    private func positionBackdrops() {
        let width = superview?.bounds.width ?? bounds.width
        for (start, view) in backdrops where !pairStarts.contains(start) || start + 1 >= cards.count {
            view.removeFromSuperview()
            backdrops.removeValue(forKey: start)
            if backdropPool.count < 4 { view.active = false; backdropPool.append(view) }
        }
        let outset: CGFloat = 4
        for start in pairStarts where start + 1 < cards.count {
            let frame = frameForCard(at: start, width: width).union(frameForCard(at: start + 1, width: width)).insetBy(dx: -outset, dy: -outset)
            let view = backdrops[start] ?? {
                let view = backdropPool.popLast() ?? PairBackdropView()
                addSubview(view, positioned: .below, relativeTo: nil)
                backdrops[start] = view
                return view
            }()
            if view.frame != frame { view.frame = frame }
        }
    }

    /// Washes the group background of the pair containing display index `index` (nil clears all). Layer property only.
    func highlightPair(containing index: Int?) {
        for (start, view) in backdrops {
            let active = index.map { $0 == start || $0 == start + 1 } ?? false
            if view.active != active { view.active = active }
        }
    }

    /// Clip-view resizes change the width only; height always follows the card count.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let superview, superview.bounds.width != frame.width else { return }
        positionCards()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(NSSize(width: newSize.width, height: contentHeight))
        if widthChanged { positionCards() }
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckBackdropCount: Int { backdrops.count }
    var nativeCheckActiveBackdrops: Int { backdrops.values.filter(\.active).count }
    #endif
}

/// The shared background behind a tile pair's two cards (radius 18). Selecting a member washes it with the accent.
@MainActor
final class PairBackdropView: NSView {
    var active = false { didSet { if oldValue != active { applyColor() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = PanefloStyle.Radius.pairGroup
        layer?.cornerCurve = .continuous
        applyColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }

    private func applyColor() {
        PanefloStyle.withoutAnimation {
            layer?.backgroundColor = PanefloStyle.cgColor(active ? PanefloStyle.Color.pairGroupActive : PanefloStyle.Color.pairGroup,
                                                          for: effectiveAppearance)
        }
    }
}
