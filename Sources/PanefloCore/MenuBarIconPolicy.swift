import Foundation

/// Whether the menu bar icon shows, and how hiding it and bringing it back work (Hide from Menu Bar).
///
/// Hiding asks once (a confirmation explaining how to come back, with "Don't show this again"). Opening Paneflo again
/// while it runs (Finder, Spotlight, Launchpad, Applications) brings the icon back. A hidden icon never strands the
/// user: while something needs attention (setup needed, shortcuts stopped by macOS) the icon cannot be hidden, and an
/// icon hidden earlier comes back on its own, with its badge. Pure value state; the app persists `hidden` and
/// `skipsConfirmation` in `SetupPreferences`.
public struct MenuBarIconPolicy: Equatable, Sendable {
    /// Something only the menu bar icon (or Settings) can tell the user about.
    public enum Attention: Equatable, Sendable {
        case none
        /// A required permission is missing (Finish Setup… in the menu, the orange badge).
        case setupNeeded
        /// The user wants shortcuts, but macOS stopped or refused the event tap.
        case shortcutsStopped
    }

    /// What a hide request does.
    public enum HideStep: Equatable, Sendable {
        /// Ask first (the confirmation with "Don't show this again").
        case confirm
        /// Hide at once (the user chose not to be asked again).
        case hide
        /// Keep the icon: it is already hidden, or something needs attention.
        case refuse
    }

    public private(set) var hidden: Bool
    public private(set) var skipsConfirmation: Bool

    public init(hidden: Bool = false, skipsConfirmation: Bool = false) {
        self.hidden = hidden
        self.skipsConfirmation = skipsConfirmation
    }

    public var isVisible: Bool { !hidden }

    public static func attention(status: PanefloStatus, shortcutsWanted: Bool, shortcutsStopped: Bool) -> Attention {
        if status == .setupNeeded { return .setupNeeded }
        return shortcutsWanted && shortcutsStopped ? .shortcutsStopped : .none
    }

    /// The user chose Hide from Menu Bar (the menu item or the Settings switch).
    public func hideStep(attention: Attention) -> HideStep {
        guard !hidden, attention == .none else { return .refuse }
        return skipsConfirmation ? .hide : .confirm
    }

    /// The user confirmed (or was not asked). `dontAskAgain`: the confirmation's checkbox.
    public mutating func hide(dontAskAgain: Bool) {
        hidden = true
        if dontAskAgain { skipsConfirmation = true }
    }

    /// The Settings switch turned the icon back on. Returns true when it changed.
    @discardableResult
    public mutating func show() -> Bool {
        guard hidden else { return false }
        hidden = false
        return true
    }

    /// Paneflo was opened again while running. Returns true when this brought the icon back (Settings then says so).
    public mutating func reopened() -> Bool { show() }

    /// The attention state changed. Returns true when this brought a hidden icon back.
    public mutating func attentionChanged(_ attention: Attention) -> Bool {
        attention == .none ? false : show()
    }
}
