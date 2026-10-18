import Foundation

/// The switcher, Overview and tile-pair preferences the surfaces read. Settings writes the same `UserDefaults` keys;
/// the surfaces re-read them only when told the preferences changed, never on input.
public struct SurfacePreferences: Equatable, Sendable {
    public enum Key {
        public static let cardSize = "switcher.cardSize"
        public static let showsFreeSlots = "overview.showsFreeSlots"
        public static let raiseTogether = "pairs.raiseTogether"
        public static let snapAssist = "pairs.snapAssist"
        public static let sideBySide = "pairs.sideBySide"
        /// The tile-pairs branch stored raise-together here before the shared contract; still honoured when the
        /// contract key is unset.
        public static let legacyRaiseTogether = "tilePairs.raiseTogether"
    }

    public var cardSize: CardSizePreference = .automatic
    public var showsFreeSlots = true
    public var raiseTogether = true
    public var snapAssist = true
    public var sideBySide = true

    public init() {}

    public init(defaults: UserDefaults) {
        cardSize = defaults.string(forKey: Key.cardSize).flatMap(CardSizePreference.init(rawValue:)) ?? .automatic
        showsFreeSlots = defaults.object(forKey: Key.showsFreeSlots) as? Bool ?? true
        raiseTogether = defaults.object(forKey: Key.raiseTogether) as? Bool
            ?? defaults.object(forKey: Key.legacyRaiseTogether) as? Bool ?? true
        snapAssist = defaults.object(forKey: Key.snapAssist) as? Bool ?? true
        sideBySide = defaults.object(forKey: Key.sideBySide) as? Bool ?? true
    }
}
