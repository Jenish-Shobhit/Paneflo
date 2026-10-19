/// Physical key codes and semantic modifier bits; independent of keyboard layout text.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
    public static let function = Self(rawValue: 16)
}

public struct ShortcutChord: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }
}

public enum ShortcutAction: Sendable {
    case switchForward, switchBackward, commit, cancel
    /// Selection movement inside a visible switcher: linear (←/→) or by grid row (↑/↓).
    case navigate(CycleDirection), navigateRow(CycleDirection)
    case overview, tile(LayoutZone), tileSelected(LayoutZone), restore
    /// Command–Option–Return: open the selection together with its tile partner (ends a held switch session).
    case openPair
    /// Command-A in the held switcher: open the selection without its tile partner (ends the session). The Overview
    /// takes Option-Return for this in its own panel, since Command-A there selects the search text.
    case openAlone
}

/// Command chords that act on the held switcher's selected window instead of the frontmost app.
/// Delivered on `ShortcutRoute.windowCommand`, separate from `ShortcutAction`.
public enum SwitcherWindowCommand: Sendable, Equatable {
    /// Command-W: press the window's close button.
    case close
    /// Command-M: minimize the window.
    case minimize
    /// Command-H: hide the window's app.
    case hideApplication
    /// Command-Q: ask the window's app to quit.
    case quitApplication

    /// Physical ANSI key codes: W 13, M 46, H 4, Q 12.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 13: self = .close
        case 46: self = .minimize
        case 4: self = .hideApplication
        case 12: self = .quitApplication
        default: return nil
        }
    }

    /// Paneflo never acts on itself, and never quits Finder.
    public func isPermitted(bundleIdentifier: String?, isPaneflo: Bool) -> Bool {
        if isPaneflo { return false }
        if self == .quitApplication, bundleIdentifier == "com.apple.finder" { return false }
        return true
    }
}

public struct ShortcutConfiguration: Sendable {
    public var switcherEnabled: Bool
    public var overview: ShortcutChord?
    public var tiling: [ShortcutChord: ShortcutAction]
    public init(switcherEnabled: Bool = false, overview: ShortcutChord? = nil,
                tiling: [ShortcutChord: ShortcutAction] = [:]) {
        self.switcherEnabled = switcherEnabled; self.overview = overview; self.tiling = tiling
    }
    public var isEmpty: Bool { !switcherEnabled && overview == nil && tiling.isEmpty }
}

public enum ShortcutEventKind: Sendable { case down, up, modifiersChanged }
public struct ShortcutRoute: Sendable {
    public var suppress = false
    public var action: ShortcutAction?
    /// A Command chord aimed at the held switcher's selected window. The session keeps switching.
    public var windowCommand: SwitcherWindowCommand?
    public init(suppress: Bool = false, action: ShortcutAction? = nil, windowCommand: SwitcherWindowCommand? = nil) {
        self.suppress = suppress; self.action = action; self.windowCommand = windowCommand
    }
}

/// Only owned chords and their paired key-ups are suppressed. No text/IME interception.
///
/// Escape belongs to Paneflo whenever one of its surfaces is visible, independent of
/// key-window or application-active state; the only exception is marked IME text.
/// While Command is held in the switcher, arrows select. Command–Option–arrows arrange the selection
/// in the switcher and in a keyboard-focused Overview (Down undoes); Command–Option–Return opens the
/// selection with its tile partner there.
///
/// While the held switcher is up, every key-down belongs to Paneflo and never reaches the frontmost
/// app: Command-W/M/H/Q become window commands for the selection, Command-A opens the selection alone
/// (without its tile partner), and other keys are swallowed.
public struct ShortcutSession: Sendable {
    public var configuration: ShortcutConfiguration
    public private(set) var switching = false
    /// Increments each time a switch session starts, so a delayed observation of a Command release can
    /// never end a newer session.
    public private(set) var sessionSerial: UInt64 = 0
    /// A switcher or Overview surface is on screen.
    public var surfaceVisible = false
    /// A persistent surface (Overview) holds real keyboard focus. Gates Command–Option–arrow arranging there.
    public var selectionContextActive = false
    public var compositionActive = false
    /// A Settings recorder is capturing a key: the Overview and tiling chords pass through instead of firing.
    public var dedicatedChordsSuspended = false
    private var ownedKeys: Set<UInt16> = []
    public init(configuration: ShortcutConfiguration) { self.configuration = configuration }

    public mutating func reset() {
        switching = false; surfaceVisible = false; selectionContextActive = false; compositionActive = false
        ownedKeys.removeAll()
    }

    /// Called after macOS re-enables an interrupted tap. Key-ups seen while the tap was off are
    /// unknown, so pairing state is dropped; a switch session whose Command release was missed commits.
    public mutating func recoverAfterTapInterruption(commandHeld: Bool) -> ShortcutAction? {
        ownedKeys.removeAll()
        guard switching, !commandHeld else { return nil }
        switching = false
        return .commit
    }

    /// Watchdog for a Command release the tap never saw (and no later key revealed). The caller polls
    /// the hardware modifier state while a session is open and passes the serial it saw Command up in;
    /// only that same session commits.
    public mutating func commitIfCommandReleased(commandHeld: Bool, serial: UInt64) -> ShortcutAction? {
        guard switching, !commandHeld, serial == sessionSerial else { return nil }
        switching = false
        return .commit
    }

    public mutating func route(kind: ShortcutEventKind, keyCode: UInt16,
                               modifiers: ShortcutModifiers, isRepeat: Bool = false) -> ShortcutRoute {
        if kind == .up { return ShortcutRoute(suppress: ownedKeys.remove(keyCode) != nil) }
        if kind == .modifiersChanged {
            if switching && !modifiers.contains(.command) {
                switching = false
                return ShortcutRoute(action: .commit)
            }
            return ShortcutRoute()
        }
        // Arrow and F-key hardware may annotate them as secondary function keys.
        // Normalize only those; Command–Fn–Tab remains an unrelated chord.
        let isArrow = (123...126).contains(keyCode)
        let modifiers = isArrow || TilingShortcutRules.isFunctionKey(keyCode) ? modifiers.subtracting(.function) : modifiers
        // A key press without Command during a switch session means the Command release was
        // missed (tap interruption, secure input). Treat it as that release; never eat the key.
        if switching && !modifiers.contains(.command) && keyCode != 53 {
            switching = false
            return ShortcutRoute(action: .commit)
        }
        let chord = ShortcutChord(keyCode: keyCode, modifiers: modifiers)
        var action: ShortcutAction?
        if configuration.switcherEnabled && keyCode == 48 &&
            (modifiers == .command || modifiers == [.command, .shift]) {
            if !switching { sessionSerial &+= 1 }
            switching = true
            action = modifiers.contains(.shift) ? .switchBackward : .switchForward
        } else if switching && keyCode == 53 && modifiers.subtracting([.command, .shift]).isEmpty {
            switching = false; action = .cancel
        } else if surfaceVisible && !compositionActive && keyCode == 53 && modifiers.isEmpty {
            if isRepeat { return ShortcutRoute(suppress: ownedKeys.contains(keyCode)) }
            action = .cancel
        } else if switching && isArrow && modifiers == .command {
            switch keyCode {
            case 123: action = .navigate(.backward)
            case 124: action = .navigate(.forward)
            case 126: action = .navigateRow(.backward)
            default: action = .navigateRow(.forward)
            }
        } else if (switching || selectionContextActive) && isArrow && modifiers == [.command, .option] {
            switch keyCode {
            case 123: action = .tileSelected(.leftHalf)
            case 124: action = .tileSelected(.rightHalf)
            case 126: action = .tileSelected(.maximize)
            default: action = .restore
            }
        } else if (switching || selectionContextActive) && (keyCode == 36 || keyCode == 76)
                    && modifiers == [.command, .option] {
            // Opening is once per physical press; a held Return never reopens.
            if isRepeat { return ShortcutRoute(suppress: switching || ownedKeys.contains(keyCode)) }
            // Opening the pair commits the held switcher; the later Command release commits nothing.
            switching = false
            action = .openPair
        } else if switching && keyCode == 0 && modifiers == .command {
            // Command-A (ANSI A): open the selection alone, once per physical press; like Command–Option–Return it ends
            // the session, so the later Command release commits nothing. A held A stays swallowed.
            if isRepeat { return ShortcutRoute(suppress: true) }
            switching = false
            action = .openAlone
        }
        if action == nil && !switching && !dedicatedChordsSuspended {
            // Dedicated chords are recorded without Fn, which the keyboard also sets on Home, End, Page Up/Down,
            // Forward Delete and any key typed with Fn held; match them the same way.
            let chord = TilingShortcutRules.normalized(chord)
            if configuration.overview == chord { action = .overview }
            else { action = configuration.tiling[chord] }
            // A dedicated chord fires once per physical press, unlike switch cycling.
            if isRepeat && action != nil { return ShortcutRoute(suppress: ownedKeys.contains(keyCode)) }
        }
        if action == nil && switching {
            // Command is held (a key without it committed above). Nothing typed while the picker is up
            // may reach the app behind it; Command-W/M/H/Q act on the selection once per physical press.
            let command = modifiers == .command && !isRepeat ? SwitcherWindowCommand(keyCode: keyCode) : nil
            ownedKeys.insert(keyCode)
            return ShortcutRoute(suppress: true, windowCommand: command)
        }
        guard let action else { return ShortcutRoute(suppress: isRepeat && ownedKeys.contains(keyCode)) }
        // Arranging fires once per physical press; selection movement repeats like Tab.
        if isRepeat {
            switch action {
            case .tileSelected, .restore: return ShortcutRoute(suppress: switching || ownedKeys.contains(keyCode))
            default: break
            }
        }
        ownedKeys.insert(keyCode)
        return ShortcutRoute(suppress: true, action: action)
    }
}
