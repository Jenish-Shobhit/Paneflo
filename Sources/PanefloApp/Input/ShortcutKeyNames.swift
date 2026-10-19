import AppKit
import Carbon.HIToolbox
import PanefloCore

/// How a recorded chord reads on screen and in menus. Chords are stored by physical key code; the character shown is the
/// one the current keyboard layout puts on that key, so a chord recorded on one layout reads correctly on another.
@MainActor
enum ShortcutKeyNames {
    /// The current layout's character for a key with no modifiers, or nil for keys that print nothing.
    static func layoutCharacter(for keyCode: UInt16) -> String? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()] {
            guard let source, let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            }
            guard status == noErr, length > 0 else { continue }
            let text = String(utf16CodeUnits: characters, count: length)
            if let scalar = text.unicodeScalars.first, scalar.value > 0x20, !CharacterSet.controlCharacters.contains(scalar) { return text }
        }
        return nil
    }

    /// "⌃⌥←".
    static func glyphs(_ chord: ShortcutChord) -> String {
        ShortcutChordFormat.glyphs(chord, layoutLabel: label(chord))
    }

    /// "Control Option Left Arrow".
    static func spoken(_ chord: ShortcutChord) -> String {
        ShortcutChordFormat.spoken(chord, layoutLabel: label(chord))
    }

    private static func label(_ chord: ShortcutChord) -> String? {
        ShortcutChordFormat.fixedKey(chord.keyCode) == nil ? layoutCharacter(for: chord.keyCode) : nil
    }

    /// The modifiers of an event as a chord's modifier set. Fn is left out.
    static func modifiers(of flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// A menu item's key equivalent and modifier mask for a chord, or nil when the key has no menu character. Number-pad
    /// keys have none: a menu equivalent would match the top-row key instead, so the menu shows no key for them.
    static func menuKeyEquivalent(_ chord: ShortcutChord) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        if ShortcutChordFormat.isKeypadKey(chord.keyCode) { return nil }
        var mask: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { mask.insert(.command) }
        if chord.modifiers.contains(.shift) { mask.insert(.shift) }
        if chord.modifiers.contains(.option) { mask.insert(.option) }
        if chord.modifiers.contains(.control) { mask.insert(.control) }
        // Keys Settings names without the layout (Escape, arrows, F-keys, ...) have a fixed equivalent; the rest show the
        // layout's character, as Settings does.
        guard let key = ShortcutChordFormat.menuKeyEquivalent(chord.keyCode) ?? layoutCharacter(for: chord.keyCode)?.lowercased()
        else { return nil }
        return (key, mask)
    }
}
