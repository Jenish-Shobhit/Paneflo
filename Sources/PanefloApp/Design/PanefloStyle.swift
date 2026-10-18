import AppKit

/// Paneflo's design tokens: radii, spacing, type, semantic colors, strokes, motion and the accessibility display
/// settings that change them. Enum namespaces only, never instances.
///
/// Every color is a semantic `NSColor` resolved per appearance; layers take a `CGColor` resolved through
/// `cgColor(_:for:)` and re-resolve when the effective appearance, the accent color or an accessibility display
/// option changes. Nested radii are concentric: panel 28 → card 14 → well 10 → capsule chips.
///
/// Settings, Setup and menu-bar-only tokens live in `PanefloStyle+Windows.swift`.
enum PanefloStyle {
    // MARK: Radii

    enum Radius {
        static let panel: CGFloat = 28
        static let card: CGFloat = 14
        static let overviewCard: CGFloat = 16
        static let well: CGFloat = 10
        static let vacancyWell: CGFloat = 12
        static let pairGroup: CGFloat = 18
        static let keycap: CGFloat = 5
        /// The selection ring sits this far outside the card edge, inside the cell gutter.
        static let ringOutset: CGFloat = 3.5
        static func ring(around card: CGFloat) -> CGFloat { card + ringOutset }
    }

    // MARK: Spacing

    /// The spacing scale `2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 32` (s1…s11).
    enum Space {
        static let s1: CGFloat = 2, s2: CGFloat = 4, s3: CGFloat = 6, s4: CGFloat = 8, s5: CGFloat = 10, s6: CGFloat = 12
        static let s7: CGFloat = 14, s8: CGFloat = 16, s9: CGFloat = 20, s10: CGFloat = 24, s11: CGFloat = 32
    }

    enum Switcher {
        static let panelPadding = Space.s7
        /// Column and row gap between cells.
        static let gridGap = Space.s5
        /// Around every card, inside its cell: the ring never overlaps a neighbour and never shifts layout.
        static let cellGutter = Space.s2
        static let cardPadding = Space.s5
        static let wellToTitle = Space.s4
        static let titleHeight: CGFloat = 15
        static let titleToSubtitle = Space.s1
        static let subtitleHeight: CGFloat = 14
        /// Inset of chips and the icon badge inside the well.
        static let wellInset = Space.s3
        static let hairlineTop = Space.s6
        static let hairlineBottom = Space.s5
        static let focusLineHeight: CGFloat = 20
        static let focusToHints = Space.s2
        static let hintStripHeight: CGFloat = 22
        static let searchHeight: CGFloat = 28
        /// Usable share of the screen's visible frame.
        static let widthShare: CGFloat = 0.9
        static let heightShare: CGFloat = 0.8
        /// Top/bottom fade of an overflowing grid.
        static let scrollFade: CGFloat = 18
    }

    enum Overview {
        static let outerMargin = Space.s11
        static let headerHeight: CGFloat = 56
        static let gridGap = Space.s8
        static let minCardWidth: CGFloat = 260
        static let minColumns = 2
        static let maxColumns = 6
        static let maxContentWidth: CGFloat = 1600
        static let searchSize = NSSize(width: 320, height: 32)
        /// Card height beyond the well: padding, title, subtitle and gaps.
        static let cardChrome: CGFloat = 62
        static let scrollFade = Space.s10
        static let titleHeight: CGFloat = 16
        static let subtitleHeight: CGFloat = 16
    }

    // MARK: Type

    @MainActor enum Font {
        static func cardTitle(compact: Bool) -> NSFont { .systemFont(ofSize: compact ? 11 : 12, weight: .semibold) }
        static let cardSubtitle = NSFont.systemFont(ofSize: 11)
        static let overviewTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let overviewSubtitle = NSFont.systemFont(ofSize: 11.5)
        static let chip = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let chipTracking: CGFloat = 0.1
        static let focusTitle = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let focusApp = NSFont.systemFont(ofSize: 13)
        static let hint = NSFont.systemFont(ofSize: 11)
        static let keycap = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        static let bannerTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let bannerDetail = NSFont.systemFont(ofSize: 11)
        static let overviewHeaderTitle = NSFont.systemFont(ofSize: 15, weight: .semibold)
        static let overviewHeaderCount = NSFont.systemFont(ofSize: 12)
        static let emptySlotLabel = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let emptySlotHint = NSFont.systemFont(ofSize: 11)
        static let emptyState = NSFont.systemFont(ofSize: 12)
        static let failure = NSFont.systemFont(ofSize: 11)
    }

    // MARK: Color

    enum Color {
        static var cardFill: NSColor { .quaternarySystemFill }
        static var cardHoverFill: NSColor { .tertiarySystemFill }
        /// The selected card's wash: accent 14 % in light, 22 % in dark.
        static func selectedWash(dark: Bool) -> NSColor { .controlAccentColor.withAlphaComponent(dark ? 0.22 : 0.14) }
        static var ring: NSColor { .controlAccentColor }
        static var partnerRing: NSColor { .controlAccentColor.withAlphaComponent(0.6) }
        /// Behind a letterboxed preview: black 6 % light, 28 % dark.
        static func wellFill(dark: Bool) -> NSColor { NSColor.black.withAlphaComponent(dark ? 0.28 : 0.06) }
        static var vacancyFill: NSColor { NSColor.quaternarySystemFill.withAlphaComponent(0.5) }
        static var vacancyBorder: NSColor { .separatorColor }
        static var keptBorder: NSColor { .controlAccentColor.withAlphaComponent(0.45) }
        static var pairGroup: NSColor { .quaternarySystemFill }
        static var pairGroupActive: NSColor { .controlAccentColor.withAlphaComponent(0.08) }
        /// Chips sit on pixels, so they are the same in light and dark.
        static func chipBackground(increaseContrast: Bool) -> NSColor { NSColor.black.withAlphaComponent(increaseContrast ? 0.8 : 0.55) }
        static var chipText: NSColor { .white }
        static var hairline: NSColor { NSColor.separatorColor.withAlphaComponent(0.5) }
        static var keycapFill: NSColor { .quaternarySystemFill }
        static var keycapBorder: NSColor { .separatorColor }
        static var snapBanner: NSColor { .controlAccentColor.withAlphaComponent(0.14) }
        static var live: NSColor { .systemGreen }
        static var attention: NSColor { .systemOrange }
        static var granted: NSColor { .systemGreen }
        /// Overview scrim over the backdrop: black 18 % dark, 8 % light.
        static func scrim(dark: Bool) -> NSColor { NSColor.black.withAlphaComponent(dark ? 0.18 : 0.08) }
        /// The Overview backdrop with Reduce Transparency on.
        static var opaqueBackdrop: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.96) }
        /// Brand teal for text and illustration: #0B6B61 light, #4FD1BD dark.
        static let brand = NSColor(name: "PanefloStyle.brand") { appearance in
            PanefloStyle.isDark(appearance) ? NSColor(srgbRed: 0x4F / 255, green: 0xD1 / 255, blue: 0xBD / 255, alpha: 1)
                : NSColor(srgbRed: 0x0B / 255, green: 0x6B / 255, blue: 0x61 / 255, alpha: 1)
        }
        /// Fixed brand teal behind white glyphs (#0B7A6E).
        static let brandTile = NSColor(srgbRed: 0x0B / 255, green: 0x7A / 255, blue: 0x6E / 255, alpha: 1)
        /// Illustrations only: #E2603F light, #FF8A6B dark.
        static let coral = NSColor(name: "PanefloStyle.coral") { appearance in
            PanefloStyle.isDark(appearance) ? NSColor(srgbRed: 1, green: 0x8A / 255, blue: 0x6B / 255, alpha: 1)
                : NSColor(srgbRed: 0xE2 / 255, green: 0x60 / 255, blue: 0x3F / 255, alpha: 1)
        }
        /// The Desktop placeholder gradient (−60°).
        static var desktopGradient: (NSColor, NSColor) {
            (NSColor.systemTeal.withAlphaComponent(0.22), NSColor.systemIndigo.withAlphaComponent(0.30))
        }
    }

    // MARK: Strokes

    enum Stroke {
        static func ring(increaseContrast: Bool) -> CGFloat { increaseContrast ? 3.5 : 2.5 }
        static func partnerRing(increaseContrast: Bool) -> CGFloat { increaseContrast ? 2 : 1.5 }
        /// Nil with Increase Contrast: the partner ring turns solid.
        static func partnerDash(increaseContrast: Bool) -> [NSNumber]? { increaseContrast ? nil : [4, 3] }
        static func vacancy(increaseContrast: Bool) -> CGFloat { increaseContrast ? 2 : 1.5 }
        static let vacancyDash: [NSNumber] = [6, 4]
        static let dropTarget: CGFloat = 2
        /// The 1 pt `separatorColor` border every card gets at rest with Increase Contrast.
        static let contrastBorder: CGFloat = 1
        static let keycapBorder: CGFloat = 0.5
    }

    // MARK: Shadow

    enum Shadow {
        static let badgeOpacity: Float = 0.25
        static let badgeRadius: CGFloat = 2
        static let badgeOffset = CGSize(width: 0, height: -1)
    }

    // MARK: Motion

    /// Surfaces appear, select and dismiss with no animation. These durations are for work the user never waits on;
    /// each is zero with Reduce Motion.
    enum Motion {
        static let snapBanner: CFTimeInterval = 0.12
        static let overviewScrim: CFTimeInterval = 0.12
        static let dropTarget: CFTimeInterval = 0.12
        static let pairedNotice: TimeInterval = 1.2
        @MainActor static func duration(_ value: CFTimeInterval) -> CFTimeInterval { Accessibility.current.reduceMotion ? 0 : value }
    }

    // MARK: Accessibility display options

    /// The display options that change surface rendering, read once and refreshed when the system reports a change,
    /// so no input handler or selection change queries the workspace.
    struct Accessibility: Equatable {
        var increaseContrast: Bool
        var reduceTransparency: Bool
        var reduceMotion: Bool
        var differentiateWithoutColor: Bool

        @MainActor private static var cached: Accessibility?
        @MainActor private static var observer: NSObjectProtocol?

        @MainActor static var current: Accessibility {
            if let cached { return cached }
            let value = read()
            cached = value
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Accessibility.cached = Accessibility.read() }
            }
            return value
        }

        @MainActor static func read() -> Accessibility {
            let workspace = NSWorkspace.shared
            return Accessibility(increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                                 reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                                 reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                                 differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
        }

        #if PANEFLO_NATIVE_CHECK
        /// Own-window checks render every combination without changing the system setting.
        @MainActor static func nativeCheckOverride(_ value: Accessibility?) { cached = value }
        #endif
    }

    // MARK: Helpers

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }

    /// Resolves a semantic color for a layer under `appearance`.
    @MainActor static func cgColor(_ color: NSColor, for appearance: NSAppearance) -> CGColor {
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    /// Runs layer changes with implicit animations off: every surface selection, appear and dismiss is instant.
    @MainActor static func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
