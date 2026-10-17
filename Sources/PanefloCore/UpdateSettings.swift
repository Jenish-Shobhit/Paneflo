import Foundation

/// The updater's bookkeeping in `UserDefaults`: whether automatic checks run, when one last ran, the version the user
/// chose Skip This Version for, and an install that is under way. Pass a throwaway suite in tests.
public struct UpdateSettings {
    public static let checksKey = "updates.automatic.v1"
    public static let skippedKey = "updates.skipped.v1"
    public static let lastCheckKey = "updates.lastCheck.v1"
    public static let pendingVersionKey = "updates.pending.version.v1"
    public static let pendingDateKey = "updates.pending.date.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Automatic checks (at most once a day). On until the user turns it off; with it off nothing is requested unless
    /// the user asks with Check for Updates….
    public var checksAutomatically: Bool {
        get { defaults.object(forKey: Self.checksKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.checksKey) }
    }

    /// The version an automatic check no longer offers (a manual check still does).
    public var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.skippedKey) } else { defaults.removeObject(forKey: Self.skippedKey) }
        }
    }

    public var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.lastCheckKey) } else { defaults.removeObject(forKey: Self.lastCheckKey) }
        }
    }

    /// The version being installed and when the helper was started: the next launch reports how it went.
    public var pendingUpdate: (version: String, date: Date)? {
        get {
            guard let version = defaults.string(forKey: Self.pendingVersionKey),
                  let date = defaults.object(forKey: Self.pendingDateKey) as? Date else { return nil }
            return (version, date)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.version, forKey: Self.pendingVersionKey)
                defaults.set(newValue.date, forKey: Self.pendingDateKey)
            } else {
                defaults.removeObject(forKey: Self.pendingVersionKey)
                defaults.removeObject(forKey: Self.pendingDateKey)
            }
        }
    }
}
