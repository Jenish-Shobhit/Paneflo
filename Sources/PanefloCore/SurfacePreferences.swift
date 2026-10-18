import Foundation

/// The switcher, Overview and tile-pair preferences the surfaces read. Settings writes the same `UserDefaults` keys;
/// the coordinator re-reads them when the defaults change, never on input.
public struct SurfacePreferences: Equatable, Sendable {
    public enum Key {
        public static let cardSize = "switcher.cardSize"
        public static let showsSelectedTitle = "switcher.showsSelectedTitle"
        /// `FreeSlotRetention` raw value (replaces 1.0's display-only "overview.showsFreeSlots").
        public static let freeSlots = "overview.keepFreeSlots"
        /// The key Settings › Tiling already writes (shipped with tile pairs).
        public static let raiseTogether = "tilePairs.raiseTogether"
        public static let snapAssist = "pairs.snapAssist"
        public static let sideBySide = "pairs.sideBySide"
    }

    /// The on/off preferences, each with its key. Every option defaults to on.
    public enum Option: String, CaseIterable, Sendable {
        /// The selected window's full title on one line under the switcher's cards.
        case showsSelectedTitle
        case raiseTogether, snapAssist, sideBySide

        public var key: String {
            switch self {
            case .showsSelectedTitle: Key.showsSelectedTitle
            case .raiseTogether: Key.raiseTogether
            case .snapAssist: Key.snapAssist
            case .sideBySide: Key.sideBySide
            }
        }
    }

    public var cardSize: CardSizePreference = .automatic
    public var showsSelectedTitle = true
    /// How long a closed window's empty place stays in the Overview (default off).
    public var freeSlots: FreeSlotRetention = .off
    public var raiseTogether = true
    public var snapAssist = true
    public var sideBySide = true

    public init() {}

    public init(defaults: UserDefaults) {
        cardSize = defaults.string(forKey: Key.cardSize).flatMap(CardSizePreference.init(rawValue:)) ?? .automatic
        freeSlots = defaults.string(forKey: Key.freeSlots).flatMap(FreeSlotRetention.init(rawValue:)) ?? .off
        for option in Option.allCases {
            self[option] = defaults.object(forKey: option.key) as? Bool ?? true
        }
    }

    public subscript(option: Option) -> Bool {
        get {
            switch option {
            case .showsSelectedTitle: showsSelectedTitle
            case .raiseTogether: raiseTogether
            case .snapAssist: snapAssist
            case .sideBySide: sideBySide
            }
        }
        set {
            switch option {
            case .showsSelectedTitle: showsSelectedTitle = newValue
            case .raiseTogether: raiseTogether = newValue
            case .snapAssist: snapAssist = newValue
            case .sideBySide: sideBySide = newValue
            }
        }
    }

    /// Writes one option where `init(defaults:)` reads it.
    public static func write(_ option: Option, _ value: Bool, to defaults: UserDefaults) {
        defaults.set(value, forKey: option.key)
    }

    public static func write(cardSize: CardSizePreference, to defaults: UserDefaults) {
        defaults.set(cardSize.rawValue, forKey: Key.cardSize)
    }

    public static func write(freeSlots: FreeSlotRetention, to defaults: UserDefaults) {
        defaults.set(freeSlots.rawValue, forKey: Key.freeSlots)
    }
}
