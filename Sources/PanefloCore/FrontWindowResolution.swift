import Foundation

/// Which window a ⌃⌥ arrangement (or the menu's Tile Front Window) acts on, decided from a fresh Accessibility read of
/// the frontmost app at keypress time, never from a cached focus. Pure: the worker reads the candidates and applies
/// the choice.
public enum FrontWindowResolution {
    /// One Accessibility element the frontmost app reported, as read just now.
    public struct Candidate: Equatable, Sendable {
        public enum Source: String, Sendable { case focused, main, firstStandard }
        public var source: Source
        /// `AXRole` (`AXWindow`, `AXSheet`…).
        public var role: String?
        /// `AXSubrole` (`AXStandardWindow`, `AXDialog`, `AXSystemDialog`, `AXFloatingWindow`…).
        public var subrole: String?
        public var fullScreen: Bool
        public var minimized: Bool
        public var sizeSettable: Bool
        public var positionSettable: Bool
        /// A sheet or dialog attached to a window: the parent window is arranged instead.
        public var hasParentWindow: Bool

        public init(source: Source, role: String?, subrole: String?, fullScreen: Bool = false, minimized: Bool = false,
                    sizeSettable: Bool = true, positionSettable: Bool = true, hasParentWindow: Bool = false) {
            self.source = source; self.role = role; self.subrole = subrole; self.fullScreen = fullScreen
            self.minimized = minimized; self.sizeSettable = sizeSettable; self.positionSettable = positionSettable
            self.hasParentWindow = hasParentWindow
        }
    }

    /// Why nothing was arranged; `message` is what the feedback HUD says.
    public enum Failure: Equatable, Sendable {
        case accessibilityOff, ownWindow, noWindow, fullScreen, notMovable, unresponsive

        public var message: String {
            switch self {
            case .accessibilityOff: "Grant Accessibility in Settings to arrange windows"
            case .ownWindow: "Paneflo doesn’t arrange its own windows"
            case .noWindow: "No window to arrange"
            case .fullScreen: "Can’t arrange a full-screen window"
            case .notMovable: "This window can’t be moved"
            case .unresponsive: "The app didn’t respond. Try again"
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Arrange this candidate (`useParent`: its parent window). `resizable` false: it can only be moved.
        case arrange(Candidate.Source, useParent: Bool, resizable: Bool)
        case fail(Failure)
    }

    /// What a candidate is: a normal window, a sheet or dialog standing for its parent, or nothing to arrange.
    private static func usable(_ candidate: Candidate) -> (ok: Bool, useParent: Bool) {
        if candidate.role == "AXSheet" || ((candidate.subrole == "AXDialog" || candidate.subrole == "AXSystemDialog") && candidate.hasParentWindow) {
            return (candidate.hasParentWindow, true)
        }
        guard candidate.role == "AXWindow", candidate.subrole != "AXSystemDialog" else { return (false, false) }
        return (true, false)
    }

    /// Chooses among the frontmost app's focused window, then its main window, then its first standard window (not for
    /// Finder, whose "no focused window" means the desktop). `parentFullScreen` and the settable flags of the parent
    /// are passed in the candidate when it stands for a parent.
    public static func decide(accessibilityTrusted: Bool, frontmostIsPaneflo: Bool, frontmostIsFinder: Bool,
                              candidates: [Candidate]) -> Decision {
        guard accessibilityTrusted else { return .fail(.accessibilityOff) }
        guard !frontmostIsPaneflo else { return .fail(.ownWindow) }
        for source in [Candidate.Source.focused, .main, .firstStandard] {
            if source == .firstStandard && frontmostIsFinder { continue }
            guard let candidate = candidates.first(where: { $0.source == source }) else { continue }
            let kind = usable(candidate)
            guard kind.ok, !candidate.minimized else { continue }
            if candidate.fullScreen { return .fail(.fullScreen) }
            if !candidate.positionSettable && !candidate.sizeSettable { return .fail(.notMovable) }
            return .arrange(source, useParent: kind.useParent, resizable: candidate.sizeSettable)
        }
        return .fail(.noWindow)
    }
}
