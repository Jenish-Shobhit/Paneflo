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
    case navigate(CycleDirection), overview, tile(LayoutZone), tileSelected(LayoutZone), restore
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
}

/// Only owned chords and their paired key-ups are suppressed. No text/IME interception.
public struct ShortcutSession: Sendable {
    public var configuration: ShortcutConfiguration
    public private(set) var switching = false
    public var selectionContextActive = false
    private var ownedKeys: Set<UInt16> = []
    public init(configuration: ShortcutConfiguration) { self.configuration = configuration }

    public mutating func reset() { switching = false; ownedKeys.removeAll() }
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
        let modifiers = (123...126).contains(keyCode) ? modifiers.subtracting(.function) : modifiers
        let chord = ShortcutChord(keyCode: keyCode, modifiers: modifiers)
        var action: ShortcutAction?
        if configuration.switcherEnabled && keyCode == 48 &&
            (modifiers == .command || modifiers == [.command, .shift]) {
            switching = true
            action = modifiers.contains(.shift) ? .switchBackward : .switchForward
        } else if switching && keyCode == 53 && modifiers.subtracting([.command, .shift]).isEmpty {
            switching = false; action = .cancel
        } else if (switching || selectionContextActive) && modifiers == .command {
            if keyCode == 123 { action = .tileSelected(.leftHalf) }
            if keyCode == 124 { action = .tileSelected(.rightHalf) }
            if keyCode == 126 { action = .tileSelected(.maximize) }
        }
        if action == nil && !switching {
            if configuration.overview == chord { action = .overview }
            else { action = configuration.tiling[chord] }
            // A dedicated chord fires once per physical press, unlike switch cycling.
            if isRepeat && action != nil { return ShortcutRoute(suppress: ownedKeys.contains(keyCode)) }
        }
        guard let action else { return ShortcutRoute(suppress: isRepeat && ownedKeys.contains(keyCode)) }
        if case .tileSelected = action, isRepeat {
            return ShortcutRoute(suppress: ownedKeys.contains(keyCode))
        }
        ownedKeys.insert(keyCode)
        return ShortcutRoute(suppress: true, action: action)
    }
}
