import Foundation

/// User-facing text for the three-finger Overview gesture, for the Settings window.
public enum GestureGuidance {
    public static let toggleTitle = "Three-finger swipe up opens Overview"
    public static let requirements =
        "Experimental · macOS 26 or later on Apple silicon, built-in trackpad only. Requires Input Monitoring. Swipe down with three fingers, or press Escape, to close Overview."
    public static let conflictTitle = "Turn off the system three-finger swipes"
    public static let conflictExplanation =
        "macOS also uses three-finger swipes: up for Mission Control and down for App Exposé. While they stay on, macOS runs them at the same time as Paneflo. In System Settings › Trackpad › More Gestures, set both Mission Control and App Exposé to Off, or to the four-finger swipe."
    public static let missionControlStep = "Mission Control: Off, or Swipe Up with Four Fingers"
    public static let appExposeStep = "App Exposé: Off, or Swipe Down with Four Fingers"
    public static let threeFingerDragNote =
        "Three-finger drag is on (System Settings › Accessibility › Pointer Control › Trackpad Options). Vertical three-finger drags may open or close Overview."
    public static let openSettingsButton = "Open Trackpad Settings…"
    /// Best-effort deep link to the Trackpad pane; fall back to opening System Settings.
    public static let trackpadSettingsURL = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"

    public static let statusConflict =
        "Mission Control or App Exposé still uses a three-finger swipe. Change it in System Settings › Trackpad › More Gestures."
    public static let statusMissionControlConflict =
        "Mission Control still uses three fingers. Set it to Off or Swipe Up with Four Fingers in System Settings › Trackpad › More Gestures."
    public static let statusAppExposeConflict =
        "App Exposé still uses three fingers. Set it to Off or Swipe Down with Four Fingers in System Settings › Trackpad › More Gestures."
    public static let statusNoConflict = "The system three-finger swipes are off."

    public static func status(for conflict: SystemGestureConflict) -> String {
        switch (conflict.missionControl, conflict.appExpose) {
        case (true, true): return statusConflict
        case (true, false): return statusMissionControlConflict
        case (false, true): return statusAppExposeConflict
        case (false, false): return statusNoConflict
        }
    }
}

/// Raw values of the system gesture preferences, read-only. `nil` means the key is absent,
/// which means the system default applies.
public struct SystemGestureSettings: Sendable, Equatable {
    /// `TrackpadThreeFingerVertSwipeGesture`: 0 when no vertical system swipe uses three fingers.
    public var threeFingerVerticalSwipe: Int?
    /// Dock `showMissionControlGestureEnabled`.
    public var missionControlGestureEnabled: Bool?
    /// Dock `showAppExposeGestureEnabled`.
    public var appExposeGestureEnabled: Bool?
    /// `TrackpadThreeFingerDrag`.
    public var threeFingerDrag: Bool?

    public init(threeFingerVerticalSwipe: Int? = nil, missionControlGestureEnabled: Bool? = nil,
                appExposeGestureEnabled: Bool? = nil, threeFingerDrag: Bool? = nil) {
        self.threeFingerVerticalSwipe = threeFingerVerticalSwipe
        self.missionControlGestureEnabled = missionControlGestureEnabled
        self.appExposeGestureEnabled = appExposeGestureEnabled
        self.threeFingerDrag = threeFingerDrag
    }

    static let builtInTrackpadDomain = "com.apple.AppleMultitouchTrackpad"
    static let bluetoothTrackpadDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    static let dockDomain = "com.apple.dock"

    /// Reads the current user's preferences with CFPreferences. Read-only; never writes.
    /// Call off the gesture path (for example when Settings opens or Paneflo activates).
    public static func current() -> SystemGestureSettings {
        for domain in [builtInTrackpadDomain, bluetoothTrackpadDomain, dockDomain] {
            CFPreferencesAppSynchronize(domain as CFString)
        }
        func value(_ key: String, _ domain: String) -> CFPropertyList? {
            CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        }
        func integer(_ key: String) -> Int? {
            (value(key, builtInTrackpadDomain) ?? value(key, bluetoothTrackpadDomain)) as? Int
        }
        func boolean(_ key: String, _ domain: String) -> Bool? {
            (value(key, domain) as? NSNumber)?.boolValue
        }
        return SystemGestureSettings(
            threeFingerVerticalSwipe: integer("TrackpadThreeFingerVertSwipeGesture"),
            missionControlGestureEnabled: boolean("showMissionControlGestureEnabled", dockDomain),
            appExposeGestureEnabled: boolean("showAppExposeGestureEnabled", dockDomain),
            threeFingerDrag: boolean("TrackpadThreeFingerDrag", builtInTrackpadDomain)
                ?? boolean("TrackpadThreeFingerDrag", bluetoothTrackpadDomain))
    }

    /// Best-effort interpretation. Turning a gesture Off, or moving it to four fingers, sets the
    /// three-finger vertical key to 0. When that key is absent the macOS default (three fingers)
    /// applies, and an absent Dock key is treated as on so that guidance errs toward showing.
    public var conflict: SystemGestureConflict {
        let threeFingerVertical = (threeFingerVerticalSwipe ?? 2) != 0
        return SystemGestureConflict(
            missionControl: threeFingerVertical && (missionControlGestureEnabled ?? true),
            appExpose: threeFingerVertical && (appExposeGestureEnabled ?? true),
            threeFingerDrag: threeFingerDrag ?? false)
    }
}

public struct SystemGestureConflict: Sendable, Equatable {
    /// Mission Control is likely still on the three-finger swipe up.
    public var missionControl: Bool
    /// App Exposé is likely still on the three-finger swipe down.
    public var appExpose: Bool
    public var threeFingerDrag: Bool
    /// True while the Settings window should show the system-gesture guidance.
    public var conflictingSystemGesturesEnabled: Bool { missionControl || appExpose }
    public init(missionControl: Bool, appExpose: Bool, threeFingerDrag: Bool) {
        self.missionControl = missionControl; self.appExpose = appExpose; self.threeFingerDrag = threeFingerDrag
    }
}
