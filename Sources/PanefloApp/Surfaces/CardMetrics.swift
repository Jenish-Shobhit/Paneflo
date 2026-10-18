import AppKit
import PanefloCore

/// Geometry and type of one card, the same for every card in a grid and set once per presentation (a tier change is
/// the only thing that resizes cards). Rects are in the card's flipped coordinates.
struct CardStyle: Equatable {
    enum Kind: Equatable { case switcher(CardTier), overview }

    var kind: Kind

    static let overview = CardStyle(kind: .overview)
    static func switcher(_ tier: CardTier) -> CardStyle { CardStyle(kind: .switcher(tier)) }

    var isOverview: Bool { kind == .overview }
    var padding: CGFloat { PanefloStyle.Switcher.cardPadding }
    var cornerRadius: CGFloat { isOverview ? PanefloStyle.Radius.overviewCard : PanefloStyle.Radius.card }
    var wellRadius: CGFloat { PanefloStyle.Radius.well }

    var showsSubtitle: Bool {
        if case .switcher(let tier) = kind { return tier.showsSubtitle }
        return true
    }

    @MainActor var titleFont: NSFont {
        switch kind {
        case .switcher(let tier): PanefloStyle.Font.cardTitle(compact: tier.compactTitle)
        case .overview: PanefloStyle.Font.overviewTitle
        }
    }
    @MainActor var subtitleFont: NSFont { isOverview ? PanefloStyle.Font.overviewSubtitle : PanefloStyle.Font.cardSubtitle }
    var titleHeight: CGFloat { isOverview ? PanefloStyle.Overview.titleHeight : PanefloStyle.Switcher.titleHeight }
    var subtitleHeight: CGFloat { isOverview ? PanefloStyle.Overview.subtitleHeight : PanefloStyle.Switcher.subtitleHeight }

    var badgeSize: CGFloat {
        if case .switcher(let tier) = kind { return CGFloat(tier.badgeSize) }
        return 28
    }

    /// Height under the well: gap, title, optional subtitle, bottom padding.
    var textBlockHeight: CGFloat {
        PanefloStyle.Switcher.wellToTitle + titleHeight
            + (showsSubtitle ? PanefloStyle.Switcher.titleToSubtitle + subtitleHeight : 0) + padding
    }

    /// The recessed preview well: full width inside the padding, 16:10, never taller than the card leaves room for.
    func wellRect(in bounds: NSRect) -> NSRect {
        let width = max(0, bounds.width - 2 * padding)
        let height = max(0, min((width * CGFloat(CardTier.wellAspect)).rounded(), bounds.height - padding - textBlockHeight))
        return NSRect(x: padding, y: padding, width: width, height: height)
    }

    func titleRect(in bounds: NSRect) -> NSRect {
        let well = wellRect(in: bounds)
        return NSRect(x: padding, y: well.maxY + PanefloStyle.Switcher.wellToTitle, width: well.width, height: titleHeight)
    }

    func subtitleRect(in bounds: NSRect) -> NSRect {
        let title = titleRect(in: bounds)
        return NSRect(x: padding, y: title.maxY + PanefloStyle.Switcher.titleToSubtitle, width: title.width, height: subtitleHeight)
    }

    /// The centred app icon shown while the well has no pixels.
    func iconSize(for well: NSRect) -> CGFloat { min(56, (well.height * 0.55).rounded()) }

    /// Overview card height for a card width: the well plus the text block, capped by the caller.
    static func overviewHeight(forWidth width: CGFloat) -> CGFloat {
        ((width - 2 * PanefloStyle.Switcher.cardPadding) * CGFloat(CardTier.wellAspect)).rounded() + PanefloStyle.Overview.cardChrome
    }
}
