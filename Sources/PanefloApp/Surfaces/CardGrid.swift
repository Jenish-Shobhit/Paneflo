import AppKit

/// A scroll-view document that places cards by frame in a fixed-column grid.
///
/// `apply` diffs by key: cards for surviving keys are reused (and only moved when their
/// position changes), new keys get a pooled or new view, removed keys release their payload.
/// Nothing here forces a layout pass; frames are computed directly.
@MainActor
final class CardGrid: NSView {
    struct Metrics: Equatable {
        var columns: Int
        var cardHeight: CGFloat
        var spacing: CGFloat = 10
    }

    override var isFlipped: Bool { true }
    var metrics = Metrics(columns: 4, cardHeight: 142) {
        didSet { if oldValue != metrics { positionCards() } }
    }
    /// Cards in display order.
    private(set) var cards: [CardView] = []
    private var byKey: [AnyHashable: CardView] = [:]
    private var keys: [AnyHashable] = []
    private var pool: [CardView] = []
    private let makeCard: () -> CardView
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    init(makeCard: @escaping () -> CardView) {
        self.makeCard = makeCard
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width]
        emptyLabel.textColor = .secondaryLabelColor
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
                card.isDesktopEntry = false
                card.selected = false
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
        for (index, card) in cards.enumerated() {
            card.tag = index
            configure(card, index)
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

    var rows: Int { cards.isEmpty ? 0 : (cards.count + metrics.columns - 1) / max(1, metrics.columns) }

    /// Document height for the current cards; independent of width.
    var contentHeight: CGFloat {
        if cards.isEmpty { return emptyLabel.isHidden ? 0 : 100 }
        return cardsHeight + (emptyLabel.isHidden ? 0 : metrics.spacing + 84)
    }

    private var cardsHeight: CGFloat { CGFloat(rows) * metrics.cardHeight + CGFloat(max(0, rows - 1)) * metrics.spacing }

    /// Frame of card `index` for a document of the given width.
    func frameForCard(at index: Int, width: CGFloat) -> NSRect {
        let columns = max(1, metrics.columns)
        let cardWidth = max(1, ((width - CGFloat(columns - 1) * metrics.spacing) / CGFloat(columns)).rounded(.down))
        let row = index / columns, column = index % columns
        return NSRect(x: CGFloat(column) * (cardWidth + metrics.spacing),
                      y: CGFloat(row) * (metrics.cardHeight + metrics.spacing),
                      width: cardWidth, height: metrics.cardHeight)
    }

    private func positionCards() {
        let width = superview?.bounds.width ?? bounds.width
        let height = contentHeight
        if frame.size != NSSize(width: width, height: height) { super.setFrameSize(NSSize(width: width, height: height)) }
        for (index, card) in cards.enumerated() {
            let target = frameForCard(at: index, width: width)
            if card.frame != target { card.frame = target }
        }
        if !emptyLabel.isHidden {
            // Below the cards when some remain (the Desktop entry alone), else at the top.
            let target = NSRect(x: 0, y: cards.isEmpty ? 8 : cardsHeight + metrics.spacing, width: width, height: 84)
            if emptyLabel.frame != target { emptyLabel.frame = target }
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
}
