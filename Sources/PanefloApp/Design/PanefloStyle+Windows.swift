import AppKit
import SwiftUI

/// Settings, Setup and menu-bar tokens (design spec §2, §6, §7, §9). Workstream B owns this file. The shared
/// `PanefloStyle` namespace (Design/PanefloStyle.swift) belongs to the switcher/Overview workstream; until it lands
/// these live in their own namespace so the two never collide, and `PanefloStyle` may absorb them later.
enum PanefloWindowStyle {
    // MARK: Color

    /// Brand teal for text and illustration: #0B6B61 light, #4FD1BD dark.
    static let brand = Color(nsColor: NSColor(name: "PanefloBrand") { appearance in
        appearance.isDark ? NSColor(srgbRed: 0x4F / 255, green: 0xD1 / 255, blue: 0xBD / 255, alpha: 1)
            : NSColor(srgbRed: 0x0B / 255, green: 0x6B / 255, blue: 0x61 / 255, alpha: 1)
    })
    /// Fixed brand teal behind white glyphs (#0B7A6E): enough contrast in both modes.
    static let brandTile = Color(.sRGB, red: 0x0B / 255, green: 0x7A / 255, blue: 0x6E / 255)
    /// Brand coral, illustrations only: #E2603F light, #FF8A6B dark.
    static let coral = Color(nsColor: NSColor(name: "PanefloCoral") { appearance in
        appearance.isDark ? NSColor(srgbRed: 1, green: 0x8A / 255, blue: 0x6B / 255, alpha: 1)
            : NSColor(srgbRed: 0xE2 / 255, green: 0x60 / 255, blue: 0x3F / 255, alpha: 1)
    })
    static let granted = Color(nsColor: .systemGreen)
    static let attention = Color(nsColor: .systemOrange)
    static let fill = Color(nsColor: .quaternarySystemFill)
    static let separator = Color(nsColor: .separatorColor)

    // MARK: Geometry

    static let keycapRadius: CGFloat = 5
    static let keycapHeight: CGFloat = 22
    static let rowRadius: CGFloat = 12
    static let calloutRadius: CGFloat = 10
    static let sidebarTile: CGFloat = 20
    static let heroTile: CGFloat = 40
    static let sidebarWidth: CGFloat = 200

    // MARK: Windows

    static let settingsSize = NSSize(width: 720, height: 540)
    static let settingsMinSize = NSSize(width: 680, height: 460)
    static let setupSize = NSSize(width: 600, height: 520)

    // MARK: Motion

    /// Setup step change (spec §2.8): 220 ms ease-out, none with Reduce Motion.
    static func stepAnimation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.22) }
    /// A permission row's status symbol turning green: 180 ms crossfade.
    static func statusAnimation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
}

fileprivate extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false }
}
