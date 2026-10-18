import Foundation

/// Switcher card sizes. Card sizes exclude the ring gutter around each card.
public enum CardTier: Int, CaseIterable, Sendable {
    case large, medium, small, extraSmall

    public static let padding = 10.0
    public static let wellToTitle = 8.0
    public static let titleHeight = 15.0
    public static let titleToSubtitle = 2.0
    public static let subtitleHeight = 14.0
    public static let wellAspect = 0.625

    public var cardWidth: Double {
        switch self {
        case .large: 232
        case .medium: 196
        case .small: 164
        case .extraSmall: 140
        }
    }

    public var wellWidth: Double { cardWidth - 2 * Self.padding }
    public var wellHeight: Double { (wellWidth * Self.wellAspect).rounded() }
    /// Extra-small cards show the title only; the badge names the app.
    public var showsSubtitle: Bool { self != .extraSmall }
    /// Small and extra-small cards use the 11 pt title.
    public var compactTitle: Bool { self == .small || self == .extraSmall }

    public var cardHeight: Double {
        Self.padding + wellHeight + Self.wellToTitle + Self.titleHeight
            + (showsSubtitle ? Self.titleToSubtitle + Self.subtitleHeight : 0) + Self.padding
    }

    public var badgeSize: Double {
        switch self {
        case .large: 28
        case .medium: 26
        case .small: 22
        case .extraSmall: 20
        }
    }

    /// The most rows this tier is chosen for in automatic sizing; nil for the last resort.
    public var automaticMaxRows: Int? {
        switch self {
        case .large: 1
        case .medium: 2
        case .small: 3
        case .extraSmall: nil
        }
    }
}

/// The user's card size choice (`switcher.cardSize`).
public enum CardSizePreference: String, CaseIterable, Sendable {
    case automatic = "auto", small, medium, large

    public var forcedTier: CardTier? {
        switch self {
        case .automatic: nil
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

/// The held switcher's grid, computed once per presentation from the card count and the screen: the tier, balanced
/// rows (8 cards → 4 + 4, not 6 + 2), a centred last row, and tile pairs kept on one row. Selection changes never
/// recompute it.
public struct SwitcherLayout: Equatable, Sendable {
    public struct Position: Equatable, Sendable {
        public var row: Int
        /// Cell index within the row, before centring.
        public var column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
    }

    public static let gutter = 4.0
    public static let gap = 10.0
    public static let panelPadding = 14.0

    public let tier: CardTier
    public let columns: Int
    public let rows: Int
    /// Rows shown without scrolling.
    public let visibleRows: Int
    /// One position per item, in item order.
    public let positions: [Position]
    /// Occupied cells per row.
    public let rowCounts: [Int]

    public var cellWidth: Double { tier.cardWidth + 2 * Self.gutter }
    public var cellHeight: Double { tier.cardHeight + 2 * Self.gutter }
    public var gridWidth: Double { Double(columns) * cellWidth + Double(max(0, columns - 1)) * Self.gap }
    public func gridHeight(rows count: Int) -> Double {
        Double(count) * cellHeight + Double(max(0, count - 1)) * Self.gap
    }

    /// The cell's left edge in grid coordinates. Short rows are centred.
    public func cellX(of index: Int) -> Double {
        let position = positions[index]
        let empty = Double(columns - rowCounts[position.row])
        return (empty / 2 + Double(position.column)) * (cellWidth + Self.gap)
    }

    public func cellY(of index: Int) -> Double { Double(positions[index].row) * (cellHeight + Self.gap) }

    /// Plans `count` items. `pairStarts` holds the index of each tile pair's first member (its partner follows it);
    /// a pair never splits across rows. `width` and `height` are the usable screen area; `chrome` is the panel height
    /// that is not grid.
    public static func plan(count: Int, pairStarts: Set<Int> = [], width: Double, height: Double, chrome: Double,
                            forced: CardTier? = nil) -> SwitcherLayout {
        let n = max(0, count)
        func maxColumns(_ tier: CardTier) -> Int {
            max(1, Int(((width - 2 * panelPadding + gap) / (tier.cardWidth + 2 * gutter + gap)).rounded(.down)))
        }
        var tier = forced ?? .extraSmall
        if forced == nil {
            for candidate in CardTier.allCases {
                let rows = (n + maxColumns(candidate) - 1) / maxColumns(candidate)
                if let limit = candidate.automaticMaxRows, rows > limit { continue }
                tier = candidate
                break
            }
        }
        let capacity = maxColumns(tier)
        let rowsNeeded = max(1, (n + capacity - 1) / capacity)
        var columns = max(1, min(capacity, (n + rowsNeeded - 1) / rowsNeeded))
        let pairs = pairStarts.filter { $0 >= 0 && $0 + 1 < n }
        if !pairs.isEmpty, columns < 2, capacity >= 2 { columns = 2 }
        let (positions, rowCounts) = place(count: n, pairStarts: columns >= 2 ? pairs : [], columns: columns)
        let rows = max(1, rowCounts.count)
        let cellHeight = tier.cardHeight + 2 * gutter
        let fitting = Int(((height - chrome + gap) / (cellHeight + gap)).rounded(.down))
        return SwitcherLayout(tier: tier, columns: columns, rows: rows, visibleRows: max(1, min(rows, fitting)),
                              positions: positions, rowCounts: rowCounts.isEmpty ? [0] : rowCounts)
    }

    /// Fills rows left to right in item order. A pair that would start in a row's last cell moves to the next row and
    /// the next single item takes that cell (display only: the caller's order is unchanged).
    static func place(count: Int, pairStarts: Set<Int>, columns: Int) -> ([Position], [Int]) {
        var positions = Array(repeating: Position(row: 0, column: 0), count: count)
        var placed = Array(repeating: false, count: count)
        var rowCounts: [Int] = []
        var row = 0, column = 0
        func put(_ index: Int) {
            positions[index] = Position(row: row, column: column)
            placed[index] = true
            column += 1
            if rowCounts.count <= row { rowCounts.append(0) }
            rowCounts[row] += 1
            if column == columns { row += 1; column = 0 }
        }
        func isPairMember(_ index: Int) -> Bool { pairStarts.contains(index) || pairStarts.contains(index - 1) }
        var index = 0
        while index < count {
            if placed[index] { index += 1; continue }
            if pairStarts.contains(index), !placed[index + 1] {
                if columns - column < 2 {
                    if let filler = (index + 2..<count).first(where: { !placed[$0] && !isPairMember($0) }) {
                        put(filler)
                    } else {
                        row += 1; column = 0
                    }
                    if column != 0 { row += 1; column = 0 }
                }
                put(index); put(index + 1)
                index += 2
                continue
            }
            put(index)
            index += 1
        }
        return (positions, rowCounts)
    }

    /// The item one row up (`direction` < 0) or down whose centre is nearest the current item's, among `eligible`
    /// (nil: all). Skips rows with no eligible item; nil past the first or last row.
    public func vertical(from current: Int?, direction: Int, eligible: Set<Int>? = nil) -> Int? {
        let candidates = positions.indices.filter { eligible?.contains($0) ?? true }
        guard direction != 0, !candidates.isEmpty else { return nil }
        guard let current, positions.indices.contains(current) else {
            return direction > 0 ? candidates.min() : candidates.max()
        }
        let center = cellX(of: current)
        var row = positions[current].row + (direction > 0 ? 1 : -1)
        while row >= 0, row < rows {
            let inRow = candidates.filter { positions[$0].row == row }
            if let match = inRow.min(by: {
                let a = abs(cellX(of: $0) - center), b = abs(cellX(of: $1) - center)
                return a == b ? $0 < $1 : a < b
            }) { return match }
            row += direction > 0 ? 1 : -1
        }
        return nil
    }
}

/// What a card shows about its preview, beyond the pixels. Cached and live pixels look the same (the picture is the
/// window); only states that matter get a small glyph, and the full state stays in the accessibility text.
public enum PreviewIndicator: Equatable, Sendable {
    case none, minimized, appHidden, otherSpace, paused

    /// The glyph and the content opacity for a presentation. `presentation` nil means previews are off: only the
    /// record's own state (minimized) shows.
    public static func resolve(_ presentation: PreviewPresentation?, isMinimized: Bool) -> (indicator: PreviewIndicator, contentOpacity: Double) {
        func unavailable(_ reason: PreviewUnavailableReason) -> (PreviewIndicator, Double) {
            switch reason {
            case .minimized: (.minimized, 0.55)
            case .appHidden: (.appHidden, 0.55)
            case .otherSpace: (.otherSpace, 0.8)
            case .noWindowNumber, .permissionRequired, .captureFailed: (.none, 1)
            }
        }
        switch presentation {
        case nil: return isMinimized ? (.minimized, 0.55) : (.none, 1)
        case .live?, .loading?: return (.none, 1)
        case .snapshot(_, let note)?: return note.map(unavailable) ?? (.none, 1)
        case .unavailable(let reason)?: return unavailable(reason)
        case .paused(.previewsOff)?: return isMinimized ? (.minimized, 0.55) : (.none, 1)
        case .paused?: return (.paused, 0.8)
        }
    }

    /// Spoken with the card ("Minimized", "Previews paused"); nil when there is nothing to add.
    public var spokenState: String? {
        switch self {
        case .none: nil
        case .minimized: "Minimized"
        case .appHidden: "App hidden"
        case .otherSpace: "On another Space"
        case .paused: "Previews paused"
        }
    }
}
