import Foundation

/// Desktop feature switches in `UserDefaults`. Pass a throwaway suite in tests.
public struct DesktopSettings {
    public static let inLoopKey = "desktop.inLoop.v1"
    public static let systemShowDesktopKey = "desktop.useSystemShowDesktop.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The Desktop entry in the switcher loop and the Overview home tile. On by default.
    public var showsDesktopEntry: Bool {
        get { defaults.object(forKey: Self.inLoopKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.inLoopKey) }
    }

    /// Trigger the system Show Desktop instead of hiding apps. Off by default; unverified on real hardware.
    public var usesSystemShowDesktop: Bool {
        get { defaults.object(forKey: Self.systemShowDesktopKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.systemShowDesktopKey) }
    }

    /// The loop mode for a new switcher session.
    public func loopMode(desktopIsCurrent: Bool) -> DesktopLoopMode {
        DesktopLoopMode.make(enabled: showsDesktopEntry, desktopIsCurrent: desktopIsCurrent)
    }
}

/// A keyboard shortcut as stored in `com.apple.symbolichotkeys`: virtual key code plus modifier bits that match both
/// `NSEvent.ModifierFlags` and `CGEventFlags` for fn, shift, control, option and command.
public struct SystemHotkey: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifierMask: UInt64

    public init(keyCode: UInt16, modifierMask: UInt64) {
        self.keyCode = keyCode
        self.modifierMask = modifierMask
    }
}

public enum SystemShowDesktopHotkey {
    /// `AppleSymbolicHotKeys` identifier of "Show Desktop".
    public static let symbolicHotkeyID = "36"
    /// F11 with the fn bit, the factory default when the preference has no entry.
    public static let factoryDefault = SystemHotkey(keyCode: 103, modifierMask: 0x0080_0000)

    /// Resolves the user's Show Desktop shortcut from the `AppleSymbolicHotKeys` dictionary, or nil when the shortcut
    /// is disabled or has no key assigned. A missing entry means the factory default.
    public static func resolve(symbolicHotkeys: [String: Any]?) -> SystemHotkey? {
        guard let entry = symbolicHotkeys?[symbolicHotkeyID] as? [String: Any] else { return factoryDefault }
        if let enabled = entry["enabled"] as? NSNumber, enabled.intValue == 0 { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let key = (parameters[1] as? NSNumber)?.intValue,
              let modifiers = (parameters[2] as? NSNumber)?.int64Value,
              key >= 0, key < 0xFFFF, modifiers >= 0 else { return nil }
        return SystemHotkey(keyCode: UInt16(key), modifierMask: UInt64(modifiers))
    }
}
