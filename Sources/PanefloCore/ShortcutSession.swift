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
    public init(suppress: Bool = false, action: ShortcutAction? = nil) { self.suppress = suppress; self.action = action }
}

/// Only owned chords and their paired key-ups are suppressed. No text/IME interception.
///
/// Escape belongs to Paneflo whenever one of its surfaces is visible, independent of
/// key-window or application-active state; the only exception is marked IME text.
/// While Command is held in the switcher, arrows select. Command–Option–arrows arrange the selection
/// in the switcher and in a keyboard-focused Overview (Down undoes).
public struct ShortcutSession: Sendable {
    public var configuration: ShortcutConfiguration
    public private(set) var switching = false
    /// A switcher or Overview surface is on screen.
    public var surfaceVisible = false
    /// A persistent surface (Overview) holds real keyboard focus. Gates Command–Option–arrow arranging there.
    public var selectionContextActive = false
    public var compositionActive = false
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
        // Arrow hardware may annotate navigation keys as secondary function keys.
        // Normalize only arrows; Command–Fn–Tab remains an unrelated chord.
        let isArrow = (123...126).contains(keyCode)
        let modifiers = isArrow ? modifiers.subtracting(.function) : modifiers
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
        }
        if action == nil && !switching {
            if configuration.overview == chord { action = .overview }
            else { action = configuration.tiling[chord] }
            // A dedicated chord fires once per physical press, unlike switch cycling.
            if isRepeat && action != nil { return ShortcutRoute(suppress: ownedKeys.contains(keyCode)) }
        }
        guard let action else { return ShortcutRoute(suppress: isRepeat && ownedKeys.contains(keyCode)) }
        // Arranging fires once per physical press; selection movement repeats like Tab.
        if isRepeat {
            switch action {
            case .tileSelected, .restore: return ShortcutRoute(suppress: ownedKeys.contains(keyCode))
            default: break
            }
        }
        ownedKeys.insert(keyCode)
        return ShortcutRoute(suppress: true, action: action)
    }
}
