import AppKit
import Observation
import PanefloCore
import SwiftUI

/// The Settings panes, in sidebar order. Only panes with something real to show are listed; controls whose feature
/// has not shipped are omitted rather than shown as dead toggles (design spec §11.2). The switcher's appearance
/// (card size, the selected-window title) lives in General; it has no key hints to show or hide, and minimized and
/// hidden-app windows are always listed, so neither has a control.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, help, tiling, overviewGesture, previews, desktop, permissions, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .help: "Shortcuts & Help"
        case .tiling: "Tiling"
        case .overviewGesture: "Overview & Gesture"
        case .previews: "Previews"
        case .desktop: "Desktop"
        case .permissions: "Permissions"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    /// The one-sentence description under the pane title.
    var summary: String {
        switch self {
        case .general: "Turn Paneflo on, choose how it starts, and how ⌘Tab looks."
        case .help: "Every key and gesture Paneflo understands."
        case .tiling: "Arrange windows from anywhere, and keep pairs together."
        case .overviewGesture: "Your windows in slots you arrange, one swipe away."
        case .previews: "Window pictures in the switcher and Overview."
        case .desktop: "A Desktop card to clear the screen and bring everything back."
        case .permissions: "What Paneflo needs from macOS, and why."
        case .updates: "Get new versions from GitHub."
        case .about: "Every window. In its place."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .help: "keyboard.fill"
        case .tiling: "rectangle.split.2x1.fill"
        case .overviewGesture: "square.grid.2x2.fill"
        case .previews: "eye.fill"
        case .desktop: "menubar.dock.rectangle"
        case .permissions: "lock.shield.fill"
        case .updates: "arrow.down.circle.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: Color(nsColor: .systemGray)
        case .help: PanefloWindowStyle.brandTile
        case .tiling: Color(nsColor: .systemBlue)
        case .overviewGesture: Color(nsColor: .systemPurple)
        case .previews: Color(nsColor: .systemPink)
        case .desktop: Color(nsColor: .systemCyan)
        case .permissions: Color(nsColor: .systemGreen)
        case .updates: Color(nsColor: .systemIndigo)
        }
    }

    /// The sidebar's two groups: features, then housekeeping.
    static let featurePanes: [SettingsPane] = [.general, .help, .tiling, .overviewGesture, .previews, .desktop]
    static let systemPanes: [SettingsPane] = [.permissions, .updates, .about]
}

/// Everything a Settings control can ask for. Views send these; `SettingsWindowController` updates the model and calls
/// the app's closures, so the UI and the own-window checks share one path.
enum SettingsAction: Equatable {
    case selectPane(SettingsPane)
    case toggleShortcuts(Bool)
    case toggleLaunchAtLogin(Bool)
    case openLoginItems
    case setMenuBarIcon(Bool)
    case toggleGesture(Bool)
    case openTrackpadSettings
    case togglePreviews(Bool)
    case toggleDesktopEntry(Bool)
    case toggleSystemShowDesktop(Bool)
    case grant(SetupPermission)
    case openPermissionSettings(SetupPermission)
    case restart
    case resetPermissions
    case openSetup
    case toggleAutomaticUpdates(Bool)
    case checkForUpdates
    case openURL(URL)
    /// Switcher card size (`SurfacePreferences.Key.cardSize`).
    case setCardSize(CardSizePreference)
    /// Overview › Keep empty places for closed windows (`SurfacePreferences.Key.freeSlots`).
    case setFreeSlots(FreeSlotRetention)
    /// A switcher, tile-pair or Overview on/off preference, written to its `SurfacePreferences` key.
    case setSurfaceOption(SurfacePreferences.Option, Bool)
    /// Overview › Remove Free Slots.
    case removeFreeSlots
    /// Overview › Reset Slot Order… (asks first).
    case resetSlots
    /// Tiling › Keyboard Shortcuts: a recorder captured a chord (nil clears the action's shortcut).
    case setTilingShortcut(TilingShortcutAction, ShortcutChord?)
    /// Tiling › Keyboard Shortcuts › Reset to Defaults.
    case resetTilingShortcuts
    /// A recorder started (an action) or stopped (nil). While one records, the global tiling chords pass through.
    case setShortcutRecording(TilingShortcutAction?)
}

/// Settings state. Exists from launch (cheap, no views); the window and its SwiftUI views are built on first open.
@MainActor @Observable
final class SettingsModel {
    var pane: SettingsPane = .general
    /// Shortcuts & Help search text.
    var helpQuery = ""

    // General
    /// The user's saved choice ("Use Paneflo shortcuts").
    var shortcutsWanted = true
    /// The event tap is running.
    var shortcutsActive = false
    var appStatus: PanefloStatus = .starting
    /// The latest one-line diagnostic (tap installed, update installed, why shortcuts are waiting).
    var status = ""
    var launchAtLogin = false
    var launchAtLoginNote: String?
    var launchAtLoginNeedsApproval = false
    var menuBarIconVisible = true
    /// "Menu bar icon restored" and similar, under the Menu Bar section; nil hides it.
    var menuBarNote: String?

    // Switcher appearance, tile pairs and Overview slots: the keys the surfaces read.
    var surface = SurfacePreferences()
    /// What the last Remove Free Slots or Reset Slot Order did; nil until one runs.
    var slotNote: String?

    // Tiling
    /// macOS's own drag-to-edge tiling is on (read when Settings opens or becomes key).
    var systemEdgeTiling = false

    // Tiling › Keyboard Shortcuts
    var tilingKeymap = TilingKeymap.defaults
    /// The action whose recorder is waiting for a key. The key listener follows it here, not in a view, so scrolling a
    /// recorder off screen never ends a recording; the window controller clears it on close, resign key and pane change.
    var recordingAction: TilingShortcutAction? {
        didSet {
            if recordingAction == nil { ShortcutRecordingMonitor.shared.stop() }
            else if recordingAction != oldValue { ShortcutRecordingMonitor.shared.start(model: self) }
        }
    }
    /// What the last assignment did or why it was refused; cleared by the next recording or reset.
    var tilingNote: String?
    var tilingNoteIsProblem = false

    // Overview & Gesture
    var gestureEnabled = false
    var gestureStatus = "Off"
    var gestureConflict = SystemGestureConflict(missionControl: false, appExpose: false, threeFingerDrag: false)

    // Previews
    var previewsEnabled = false
    var previewControlEnabled = false
    var previewPermissionMessage: String?

    // Desktop
    var desktopEntry = false
    var systemShowDesktop = false

    // Permissions
    /// Nil until the first permission reading.
    var setup: SetupModel?

    // Updates
    var automaticUpdates = true
    var lastUpdateCheck: Date?

    @ObservationIgnored var perform: (SettingsAction) -> Void = { _ in }

    var setupNeeded: Bool { setup.map { !$0.isComplete } ?? false }

    func row(_ permission: SetupPermission) -> SetupRow? { setup?.rows.first { $0.permission == permission } }

    /// A toggle bound to one surface preference.
    func surfaceToggle(_ option: SurfacePreferences.Option) -> Binding<Bool> {
        Binding(get: { self.surface[option] }, set: { self.perform(.setSurfaceOption(option, $0)) })
    }

    var cardSizeBinding: Binding<CardSizePreference> {
        Binding(get: { self.surface.cardSize }, set: { self.perform(.setCardSize($0)) })
    }

    var freeSlotsBinding: Binding<FreeSlotRetention> {
        Binding(get: { self.surface.freeSlots }, set: { self.perform(.setFreeSlots($0)) })
    }

    /// The note after Remove Free Slots.
    static func removedNote(_ count: Int) -> String {
        switch count {
        case 0: "There were no free slots to remove."
        case 1: "Removed 1 free slot."
        default: "Removed \(count) free slots."
        }
    }

    /// "1.1.0 (42)", from the bundle.
    var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "Development build"
        }
    }

    var lastUpdateCheckText: String {
        guard let lastUpdateCheck else { return "Not checked yet" }
        let calendar = Calendar.current
        let time = lastUpdateCheck.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(lastUpdateCheck) { return "Last checked today at \(time)" }
        if calendar.isDateInYesterday(lastUpdateCheck) { return "Last checked yesterday at \(time)" }
        return "Last checked \(lastUpdateCheck.formatted(date: .abbreviated, time: .shortened))"
    }
}
