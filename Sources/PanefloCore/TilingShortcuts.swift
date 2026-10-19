import Foundation

/// The arrangements that can have a user-chosen global shortcut, in the order Settings lists them.
public enum TilingShortcutAction: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case firstThird, middleThird, lastThird
    case maximize, center, restore

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeftQuarter: "Top Left Quarter"
        case .topRightQuarter: "Top Right Quarter"
        case .bottomLeftQuarter: "Bottom Left Quarter"
        case .bottomRightQuarter: "Bottom Right Quarter"
        case .firstThird: "First Third"
        case .middleThird: "Middle Third"
        case .lastThird: "Last Third"
        case .maximize: "Fill"
        case .center: "Center"
        case .restore: "Restore"
        }
    }

    public var zone: LayoutZone? {
        switch self {
        case .leftHalf: .leftHalf
        case .rightHalf: .rightHalf
        case .topHalf: .topHalf
        case .bottomHalf: .bottomHalf
        case .topLeftQuarter: .topLeftQuarter
        case .topRightQuarter: .topRightQuarter
        case .bottomLeftQuarter: .bottomLeftQuarter
        case .bottomRightQuarter: .bottomRightQuarter
        case .firstThird: .firstThird
        case .middleThird: .middleThird
        case .lastThird: .lastThird
        case .maximize: .maximize
        case .center: .center
        case .restore: nil
        }
    }

    public var shortcutAction: ShortcutAction {
        if let zone { .tile(zone) } else { .restore }
    }

    /// The chord Paneflo has always used: ⌃⌥ with the arrows, Return (Fill) and Z (Restore). Nothing else starts bound.
    public var defaultChord: ShortcutChord? {
        let modifiers: ShortcutModifiers = [.control, .option]
        switch self {
        case .leftHalf: return ShortcutChord(keyCode: 123, modifiers: modifiers)
        case .rightHalf: return ShortcutChord(keyCode: 124, modifiers: modifiers)
        case .topHalf: return ShortcutChord(keyCode: 126, modifiers: modifiers)
        case .bottomHalf: return ShortcutChord(keyCode: 125, modifiers: modifiers)
        case .maximize: return ShortcutChord(keyCode: 36, modifiers: modifiers)
        case .restore: return ShortcutChord(keyCode: 6, modifiers: modifiers)
        default: return nil
        }
    }
}

/// Why a chord cannot be a tiling shortcut.
public enum ShortcutRejection: Equatable, Sendable {
    /// Needs ⌘, ⌃ or ⌥ (F-keys excepted); a bare key or Shift alone would fire while typing.
    case needsModifier
    /// ⌘Tab, ⌘⇧Tab, ⌘`, Escape and ⌘⌥ arrows/Return belong to the switcher and its surfaces.
    case reservedBySwitcher
    case overviewChord
    /// ⌥ (with or without ⇧) on a key that types a character would swallow typing system-wide.
    case optionTypesCharacters

    public var message: String {
        switch self {
        case .needsModifier: "Include ⌘, ⌃ or ⌥ so the shortcut doesn’t fire while you type."
        case .reservedBySwitcher: "Paneflo’s switcher uses that shortcut."
        case .overviewChord: "That opens the Overview."
        case .optionTypesCharacters: "Option alone types characters; add ⌃ or ⌘."
        }
    }
}

/// A chord the system or most apps already use; allowed, with a note.
public enum SystemChordWarning: Equatable, Sendable {
    case quit, closeWindow, hide, minimize, spotlight, inputSource, screenshot

    public var message: String {
        switch self {
        case .quit: "⌘Q quits apps, so this shortcut will stop working there."
        case .closeWindow: "⌘W closes windows in most apps."
        case .hide: "⌘H hides the front app in most apps."
        case .minimize: "⌘M minimizes windows in most apps."
        case .spotlight: "⌘Space opens Spotlight by default."
        case .inputSource: "⌃Space switches input sources by default."
        case .screenshot: "macOS uses this for screenshots by default."
        }
    }
}

public enum TilingShortcutRules {
    /// Fn is added by the keyboard to arrows and F-keys; it never takes part in a chord.
    public static func normalized(_ chord: ShortcutChord) -> ShortcutChord {
        ShortcutChord(keyCode: chord.keyCode, modifiers: chord.modifiers.subtracting(.function))
    }

    /// Physical key codes of F1 to F20.
    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeyCodes.contains(keyCode) }

    /// Keys that print nothing, so ⌥ with them is safe: Return, Enter, Tab, Delete, Forward Delete, Escape, Home, End,
    /// Page Up/Down, the arrows and the F-keys. Every other key (letters, digits, punctuation, Space, keypad) types.
    static let nonCharacterKeyCodes: Set<UInt16> = [36, 76, 48, 51, 117, 53, 115, 119, 116, 121, 123, 124, 125, 126]

    public static func producesCharacter(_ keyCode: UInt16) -> Bool {
        !nonCharacterKeyCodes.contains(keyCode) && !isFunctionKey(keyCode)
    }

    public static func rejection(of chord: ShortcutChord, overview: ShortcutChord?) -> ShortcutRejection? {
        let chord = normalized(chord)
        let modifiers = chord.modifiers
        let isArrow = (123...126).contains(chord.keyCode)
        // What `ShortcutSession` routes before the dedicated chords: ⌘Tab, Escape, ⌘⌥ arrows and Return.
        if chord.keyCode == 48 && (modifiers == .command || modifiers == [.command, .shift]) { return .reservedBySwitcher }
        if chord.keyCode == 50 && modifiers.contains(.command) { return .reservedBySwitcher }
        if chord.keyCode == 53 && modifiers.subtracting([.command, .shift]).isEmpty { return .reservedBySwitcher }
        if modifiers == [.command, .option] && (isArrow || chord.keyCode == 36 || chord.keyCode == 76) { return .reservedBySwitcher }
        if let overview, normalized(overview) == chord { return .overviewChord }
        if modifiers.isDisjoint(with: [.command, .control, .option]) && !isFunctionKey(chord.keyCode) { return .needsModifier }
        if modifiers.subtracting(.shift) == .option && producesCharacter(chord.keyCode) { return .optionTypesCharacters }
        return nil
    }

    public static func warning(for chord: ShortcutChord) -> SystemChordWarning? {
        let chord = normalized(chord)
        switch (chord.keyCode, chord.modifiers) {
        case (12, .command): return .quit
        case (13, .command): return .closeWindow
        case (4, .command): return .hide
        case (46, .command): return .minimize
        case (49, .command): return .spotlight
        case (49, .control): return .inputSource
        case (20, [.command, .shift]), (21, [.command, .shift]), (23, [.command, .shift]): return .screenshot
        default: return nil
        }
    }
}

/// What assigning a chord did.
public struct TilingAssignment: Equatable, Sendable {
    public var keymap: TilingKeymap
    /// The action that had this chord and is now unassigned.
    public var displaced: TilingShortcutAction?
    public var warning: SystemChordWarning?

    /// The inline line under the list, or nil when nothing needs saying.
    public func note(for action: TilingShortcutAction) -> String? {
        var parts: [String] = []
        if let displaced { parts.append("Moved from \(displaced.title) to \(action.title); \(displaced.title) is now unassigned.") }
        if let warning { parts.append(warning.message) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public enum TilingAssignmentOutcome: Equatable, Sendable {
    case assigned(TilingAssignment)
    case rejected(ShortcutRejection)
}

/// The effective tiling shortcuts: at most one action per chord, every chord valid.
public struct TilingKeymap: Equatable, Sendable {
    /// The Overview's chord (⌃⌥Space). Not configurable, so no tiling action may take it.
    public static let overviewChord = ShortcutChord(keyCode: 49, modifiers: [.control, .option])

    public private(set) var chords: [TilingShortcutAction: ShortcutChord]

    public static let defaults = TilingKeymap(chords: Dictionary(uniqueKeysWithValues:
        TilingShortcutAction.allCases.compactMap { action in action.defaultChord.map { (action, $0) } }))

    private init(chords: [TilingShortcutAction: ShortcutChord]) { self.chords = chords }

    public func chord(for action: TilingShortcutAction) -> ShortcutChord? { chords[action] }

    public func action(for chord: ShortcutChord) -> TilingShortcutAction? {
        let chord = TilingShortcutRules.normalized(chord)
        return TilingShortcutAction.allCases.first { chords[$0] == chord }
    }

    /// The table `ShortcutConfiguration.tiling` takes.
    public var table: [ShortcutChord: ShortcutAction] {
        Dictionary(uniqueKeysWithValues: chords.map { ($0.value, $0.key.shortcutAction) })
    }

    /// Assigns `chord` to `action`. A chord another action holds moves: that action becomes unassigned.
    public func assigning(_ chord: ShortcutChord, to action: TilingShortcutAction,
                          overview: ShortcutChord? = TilingKeymap.overviewChord) -> TilingAssignmentOutcome {
        let chord = TilingShortcutRules.normalized(chord)
        if let rejection = TilingShortcutRules.rejection(of: chord, overview: overview) { return .rejected(rejection) }
        var next = self
        let displaced = self.action(for: chord).flatMap { $0 == action ? nil : $0 }
        if let displaced { next.chords[displaced] = nil }
        next.chords[action] = chord
        return .assigned(TilingAssignment(keymap: next, displaced: displaced, warning: TilingShortcutRules.warning(for: chord)))
    }

    public func clearing(_ action: TilingShortcutAction) -> TilingKeymap {
        var next = self
        next.chords[action] = nil
        return next
    }

    public var isDefault: Bool { self == .defaults }

    // MARK: Persistence

    /// Bumped when the stored layout changes incompatibly. Actions added later need no bump: those missing from the
    /// stored list take their default.
    static let storageVersion = 1

    private struct Stored: Codable {
        struct Entry: Codable {
            var action: String
            var keyCode: UInt16?
            var modifiers: UInt8
        }
        var version: Int
        var entries: [Entry]
    }

    public func encoded() -> Data? {
        let entries = TilingShortcutAction.allCases.map { action -> Stored.Entry in
            let chord = chords[action]
            return Stored.Entry(action: action.rawValue, keyCode: chord?.keyCode, modifiers: chord?.modifiers.rawValue ?? 0)
        }
        return try? JSONEncoder().encode(Stored(version: Self.storageVersion, entries: entries))
    }

    /// Undecodable or unversioned data gives the defaults. Entries for unknown actions are ignored; invalid or duplicate
    /// chords become unassigned; actions the data doesn't mention take their default when it is free.
    public static func decode(_ data: Data?, overview: ShortcutChord? = TilingKeymap.overviewChord) -> TilingKeymap {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version >= 1 else { return .defaults }
        var keymap = TilingKeymap(chords: [:])
        var mentioned: Set<TilingShortcutAction> = []
        for entry in stored.entries {
            guard let action = TilingShortcutAction(rawValue: entry.action), mentioned.insert(action).inserted else { continue }
            guard let keyCode = entry.keyCode else { continue }
            let chord = TilingShortcutRules.normalized(ShortcutChord(keyCode: keyCode, modifiers: ShortcutModifiers(rawValue: entry.modifiers)))
            guard TilingShortcutRules.rejection(of: chord, overview: overview) == nil, keymap.action(for: chord) == nil else { continue }
            keymap.chords[action] = chord
        }
        for action in TilingShortcutAction.allCases where !mentioned.contains(action) {
            if let chord = action.defaultChord, keymap.action(for: chord) == nil { keymap.chords[action] = chord }
        }
        return keymap
    }
}

/// UserDefaults persistence for the keymap.
public struct TilingKeymapStore {
    public static let key = "tiling.shortcuts.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> TilingKeymap { TilingKeymap.decode(defaults.data(forKey: Self.key)) }

    public func save(_ keymap: TilingKeymap) {
        if keymap.isDefault { defaults.removeObject(forKey: Self.key) }
        else if let data = keymap.encoded() { defaults.set(data, forKey: Self.key) }
    }
}

/// Glyphs and spoken names for chords. Layout-dependent key labels come from the caller; this holds what never changes.
public enum ShortcutChordFormat {
    public static func modifierGlyphs(_ modifiers: ShortcutModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    public static func spokenModifiers(_ modifiers: ShortcutModifiers) -> [String] {
        var names: [String] = []
        if modifiers.contains(.control) { names.append("Control") }
        if modifiers.contains(.option) { names.append("Option") }
        if modifiers.contains(.shift) { names.append("Shift") }
        if modifiers.contains(.command) { names.append("Command") }
        return names
    }

    private static let fixed: [UInt16: (glyph: String, spoken: String)] = [
        36: ("↩", "Return"), 76: ("⌤", "Enter"), 48: ("⇥", "Tab"), 49: ("Space", "Space"), 51: ("⌫", "Delete"),
        117: ("⌦", "Forward Delete"), 53: ("⎋", "Escape"), 115: ("↖", "Home"), 119: ("↘", "End"),
        116: ("⇞", "Page Up"), 121: ("⇟", "Page Down"),
        123: ("←", "Left Arrow"), 124: ("→", "Right Arrow"), 125: ("↓", "Down Arrow"), 126: ("↑", "Up Arrow"),
    ]

    private static let functionNumbers: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// US-layout characters, for when the current layout can't name a key.
    private static let ansi: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// Number-pad keys by physical code. They print the same characters as the top row, so they get their own names:
    /// "Num1" on screen, "Keypad 1" spoken.
    private static let keypad: [UInt16: String] = [
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 78: "-", 81: "=",
    ]

    /// True for number-pad keys other than Enter (which already has its own name).
    public static func isKeypadKey(_ keyCode: UInt16) -> Bool { keypad[keyCode] != nil }

    /// 1 to 20 for F1 to F20.
    public static func functionKeyNumber(_ keyCode: UInt16) -> Int? { functionNumbers[keyCode] }

    /// The key's name when it doesn't depend on the layout (arrows, Return, Space, F-keys, ...).
    public static func fixedKey(_ keyCode: UInt16) -> (glyph: String, spoken: String)? {
        if let key = fixed[keyCode] { return key }
        if let number = functionNumbers[keyCode] { return ("F\(number)", "F\(number)") }
        if let name = keypad[keyCode] { return ("Num\(name)", "Keypad \(name)") }
        return nil
    }

    /// `layoutLabel` is the current keyboard layout's character for the key, when it has one.
    public static func keyLabel(_ keyCode: UInt16, layoutLabel: String? = nil) -> (glyph: String, spoken: String) {
        if let key = fixedKey(keyCode) { return key }
        if let label = layoutLabel?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !label.isEmpty { return (label, label) }
        if let label = ansi[keyCode] { return (label, label) }
        return ("Key \(keyCode)", "Key \(keyCode)")
    }

    public static func glyphs(_ chord: ShortcutChord, layoutLabel: String? = nil) -> String {
        modifierGlyphs(chord.modifiers) + keyLabel(chord.keyCode, layoutLabel: layoutLabel).glyph
    }

    /// "Control Option Left Arrow", for VoiceOver.
    public static func spoken(_ chord: ShortcutChord, layoutLabel: String? = nil) -> String {
        (spokenModifiers(chord.modifiers) + [keyLabel(chord.keyCode, layoutLabel: layoutLabel).spoken]).joined(separator: " ")
    }
}
