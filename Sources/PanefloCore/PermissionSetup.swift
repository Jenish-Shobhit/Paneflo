import Foundation

/// The three macOS privacy permissions Paneflo uses, in the order the setup window lists them.
public enum SetupPermission: String, CaseIterable, Hashable, Sendable {
    case accessibility, inputMonitoring, screenRecording

    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen Recording"
        }
    }

    public var purpose: String {
        switch self {
        case .accessibility: "Finds your windows, focuses them and arranges them."
        case .inputMonitoring: "Lets ⌘Tab, the ⌃⌥ tiling shortcuts and the trackpad gesture reach Paneflo."
        case .screenRecording: "Shows window pictures in the switcher and Overview. Without it the switcher works without them."
        }
    }

    /// The System Settings pane that lists this permission.
    public var settingsURL: String {
        switch self {
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }

    /// The `tccutil` service name.
    public var tccService: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "ListenEvent"
        case .screenRecording: "ScreenCapture"
        }
    }

    /// macOS often applies this permission to a running app only after it relaunches.
    public var appliesAfterRelaunch: Bool { self != .accessibility }
}

/// What the system reports right now. Read from preflight calls only, which never prompt.
public struct PermissionState: Equatable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, inputMonitoring: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.screenRecording = screenRecording
    }

    public subscript(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        case .screenRecording: screenRecording
        }
    }
}

/// The user's saved choices that decide which permissions are required.
public struct SetupIntent: Equatable, Sendable {
    public var shortcuts: Bool
    public var gesture: Bool
    public var previews: Bool

    public init(shortcuts: Bool, gesture: Bool, previews: Bool) {
        self.shortcuts = shortcuts
        self.gesture = gesture
        self.previews = previews
    }
}

/// One row of the setup window.
public struct SetupRow: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case granted
        case missing
        /// Granted in System Settings (or asked for), but Paneflo has to restart before it applies.
        case needsRestart
    }

    public let permission: SetupPermission
    public let required: Bool
    public let status: Status

    public var isGranted: Bool { status == .granted }
}

/// The setup state machine: which rows show, whether setup is needed, when to offer a restart or the stale-entry reset,
/// and which features may start on their own. A value type rebuilt from fresh preflight readings on every poll.
public struct SetupModel: Equatable, Sendable {
    public var permissions: PermissionState
    public var intent: SetupIntent
    /// Permissions whose Grant button was used in this process.
    public var requested: Set<SetupPermission>
    /// Preflight says yes but the feature still failed (the event tap could not be created, or ScreenCaptureKit keeps
    /// refusing): a relaunch is the fix.
    public var serviceNeedsRestart: Set<SetupPermission>
    /// Permissions that were still off when the user chose Restart Paneflo, read back after the relaunch.
    public var missingBeforeRelaunch: Set<SetupPermission>
    /// The user came back to Paneflo after a Grant button sent them to System Settings.
    public var returnedFromSettings: Bool

    public init(permissions: PermissionState, intent: SetupIntent, requested: Set<SetupPermission> = [],
                serviceNeedsRestart: Set<SetupPermission> = [], missingBeforeRelaunch: Set<SetupPermission> = [],
                returnedFromSettings: Bool = false) {
        self.permissions = permissions
        self.intent = intent
        self.requested = requested
        self.serviceNeedsRestart = serviceNeedsRestart
        self.missingBeforeRelaunch = missingBeforeRelaunch
        self.returnedFromSettings = returnedFromSettings
    }

    /// Accessibility is always required. Input Monitoring is required while shortcuts or the gesture are wanted.
    /// Screen Recording is never required: without it the switcher works without pictures.
    public func isRequired(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .accessibility: true
        case .inputMonitoring: intent.shortcuts || intent.gesture
        case .screenRecording: false
        }
    }

    public var rows: [SetupRow] {
        SetupPermission.allCases.map { permission in
            let status: SetupRow.Status
            if serviceNeedsRestart.contains(permission) {
                status = .needsRestart
            } else if permissions[permission] {
                status = .granted
            } else if permission.appliesAfterRelaunch, requested.contains(permission) {
                status = .needsRestart
            } else {
                status = .missing
            }
            return SetupRow(permission: permission, required: isRequired(permission), status: status)
        }
    }

    /// Required permissions that are not working yet.
    public var missingRequired: [SetupPermission] {
        rows.filter { $0.required && !$0.isGranted }.map(\.permission)
    }

    /// Everything Paneflo needs for the user's choices works. The menu badge and "Finish setup…" follow this.
    public var isComplete: Bool { missingRequired.isEmpty }

    /// The setup window shows by itself at most once per launch, and only while something required is missing.
    public func showsAtLaunch(alreadyShownThisLaunch: Bool) -> Bool {
        !isComplete && !alreadyShownThisLaunch
    }

    /// "Restart Paneflo": a permission that applies after relaunch was asked for and still reads off, or a feature
    /// failed even though its permission reads on.
    public var offersRestart: Bool {
        !serviceNeedsRestart.isEmpty || rows.contains { $0.status == .needsRestart }
    }

    /// Permissions that look stuck: still off after the restart that should have applied them, or Accessibility
    /// (which applies at once) still off after the user came back from System Settings. The usual cause is an entry
    /// macOS keeps for an older build of Paneflo.
    public var likelyStale: Set<SetupPermission> {
        var stale = missingBeforeRelaunch.filter { !permissions[$0] }
        if returnedFromSettings, requested.contains(.accessibility), !permissions.accessibility { stale.insert(.accessibility) }
        return stale
    }

    public var showsStaleHint: Bool { !likelyStale.isEmpty }

    /// What to record before relaunching, so the next launch can tell a stuck permission from a working one.
    public var missingForRelaunch: Set<SetupPermission> {
        Set(rows.filter { !$0.isGranted && ($0.required || requested.contains($0.permission)) }.map(\.permission))
    }

    /// ⌘Tab and the tiling shortcuts may start without another click.
    public var startsShortcuts: Bool { intent.shortcuts && permissions.accessibility && permissions.inputMonitoring }
    /// The gesture stays opt-in; once chosen it starts as soon as its permissions allow.
    public var startsGesture: Bool { intent.gesture && permissions.accessibility && permissions.inputMonitoring }
    /// Previews run when wanted and Screen Recording works.
    public var runsPreviews: Bool { intent.previews && permissions.screenRecording }
}

/// Paneflo's saved setup choices in `UserDefaults`. Pass a throwaway suite in tests.
///
/// Shortcuts are on by default: until the choice is settled (the first completed setup, or the user switching them on
/// or off) they count as wanted, whatever an older build saved after a failed start. The gesture stays opt-in.
/// Previews default on and run only with Screen Recording.
public struct SetupPreferences {
    public static let shortcutsKey = "shortcuts.enabled.v1"
    public static let shortcutsSettledKey = "shortcuts.choiceSettled.v1"
    public static let gestureKey = "gesture.enabled.v1"
    public static let previewsKey = "previews.enabled.v1"
    public static let missingBeforeRelaunchKey = "setup.missingBeforeRelaunch.v1"
    public static let menuBarIconHiddenKey = "menuBar.iconHidden.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The shortcuts choice has been made, by a completed setup or by the user.
    public var shortcutsChoiceSettled: Bool { defaults.bool(forKey: Self.shortcutsSettledKey) }

    /// Writing it settles the choice.
    public var shortcutsEnabled: Bool {
        get { !shortcutsChoiceSettled || (defaults.object(forKey: Self.shortcutsKey) as? Bool ?? true) }
        nonmutating set {
            defaults.set(newValue, forKey: Self.shortcutsKey)
            defaults.set(true, forKey: Self.shortcutsSettledKey)
        }
    }

    public var gestureEnabled: Bool {
        get { defaults.bool(forKey: Self.gestureKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.gestureKey) }
    }

    public var previewsEnabled: Bool {
        get { defaults.object(forKey: Self.previewsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.previewsKey) }
    }

    public var menuBarIconHidden: Bool {
        get { defaults.bool(forKey: Self.menuBarIconHiddenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.menuBarIconHiddenKey) }
    }

    public var intent: SetupIntent {
        SetupIntent(shortcuts: shortcutsEnabled, gesture: gestureEnabled, previews: previewsEnabled)
    }

    /// Recorded by Restart Paneflo; read once by the next launch (`takeMissingBeforeRelaunch`).
    public var missingBeforeRelaunch: Set<SetupPermission> {
        get { Set((defaults.stringArray(forKey: Self.missingBeforeRelaunchKey) ?? []).compactMap(SetupPermission.init(rawValue:))) }
        nonmutating set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.missingBeforeRelaunchKey) }
            else { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.missingBeforeRelaunchKey) }
        }
    }

    /// Returns what the previous copy recorded before relaunching and clears it, so the hint applies to one launch.
    public func takeMissingBeforeRelaunch() -> Set<SetupPermission> {
        let value = missingBeforeRelaunch
        missingBeforeRelaunch = []
        return value
    }

    /// Call on every permission reading. The first time Accessibility and Input Monitoring are both granted while the
    /// shortcuts choice is unsettled, shortcuts are turned on. Returns true on that first completion.
    @discardableResult
    public func noteSetup(_ model: SetupModel) -> Bool {
        guard !shortcutsChoiceSettled, model.permissions.accessibility, model.permissions.inputMonitoring else { return false }
        shortcutsEnabled = true
        return true
    }
}

/// "Permissions stuck? Reset and grant again": the `tccutil` invocations that clear Paneflo's own entries.
public enum PermissionReset {
    public static let tool = "/usr/bin/tccutil"

    /// Arguments for `/usr/bin/tccutil`, one invocation per permission, always scoped to `bundleID`. Empty when the
    /// bundle identifier is not a plausible reverse-DNS identifier: a reset without one would clear every app's
    /// entries, so it is never produced.
    public static func invocations(bundleID: String?) -> [[String]] {
        guard let bundleID, isScopedBundleID(bundleID) else { return [] }
        return SetupPermission.allCases.map { ["reset", $0.tccService, bundleID] }
    }

    static func isScopedBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        // Never an option to tccutil: the identifier starts with a letter or digit.
        guard parts.count >= 2, value.count <= 255, value.first?.isASCII == true,
              value.first?.isLetter == true || value.first?.isNumber == true else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    public static let explanation = "macOS keeps permission entries for older builds of Paneflo, so a switch can look on without applying to this copy. Resetting removes Paneflo’s entries (no other app’s) so you can grant them again."
}

/// The detached relaunch helper: wait for this process to exit (bounded), then open the app again.
public enum RelaunchHelper {
    /// Run as `/bin/sh -c script paneflo-relaunch <bundle path> <pid>`.
    public static let script = """
        i=0; while /bin/kill -0 "$2" 2>/dev/null && [ "$i" -lt 100 ]; do /bin/sleep 0.1; i=$((i+1)); done
        /bin/sleep 0.3
        /usr/bin/open "$1"
        """

    /// Nil when Paneflo is not running from an app bundle (a bare development binary cannot be reopened).
    public static func arguments(bundlePath: String, pid: Int32) -> [String]? {
        guard bundlePath.hasSuffix(".app") else { return nil }
        return ["-c", script, "paneflo-relaunch", bundlePath, String(pid)]
    }
}
