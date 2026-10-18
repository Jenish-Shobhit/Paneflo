import PanefloCore
import SwiftUI

extension SettingsModel {
    /// A toggle binding that reads the model and sends `action` on change.
    func toggle(_ keyPath: KeyPath<SettingsModel, Bool>, _ action: @escaping (Bool) -> SettingsAction) -> Binding<Bool> {
        Binding(get: { self[keyPath: keyPath] }, set: { self.perform(action($0)) })
    }
}

struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        PaneForm(pane: .general) {
            Section {
                SubtitledToggle("Use Paneflo shortcuts",
                                subtitle: "⌘Tab switches windows, ⌃⌥ with the arrows tiles, and ⌃⌥Space opens Overview.",
                                isOn: model.toggle(\.shortcutsWanted, SettingsAction.toggleShortcuts))
                if let blocker = shortcutBlocker {
                    StatusRow(tone: .attention, title: blocker.text) {
                        Button(blocker.button) { model.perform(blocker.action) }.buttonStyle(.link)
                    }
                }
                Toggle("Launch at login", isOn: model.toggle(\.launchAtLogin, SettingsAction.toggleLaunchAtLogin))
                if model.launchAtLoginNeedsApproval {
                    StatusRow(tone: .attention, title: "Approve Paneflo in System Settings › General › Login Items.") {
                        Button("Open Login Items") { model.perform(.openLoginItems) }.buttonStyle(.link)
                    }
                } else if let note = model.launchAtLoginNote {
                    StatusRow(tone: .attention, title: note)
                }
            } header: {
                Text("Paneflo")
            } footer: {
                if !model.status.isEmpty { Footnote(model.status).accessibilityLabel("Status: \(model.status)") }
            }
            Section("Menu Bar") {
                SubtitledToggle("Show menu bar icon",
                                subtitle: "When it’s hidden, open Paneflo from Finder or Spotlight to come back here.",
                                isOn: model.toggle(\.menuBarIconVisible, SettingsAction.setMenuBarIcon))
            }
        }
    }

    /// Why the shortcuts are wanted but not running, and the one button that fixes it.
    private var shortcutBlocker: (text: String, button: String, action: SettingsAction)? {
        guard model.shortcutsWanted, !model.shortcutsActive, let setup = model.setup else { return nil }
        if setup.serviceNeedsRestart.contains(.inputMonitoring)
            || (setup.permissions.inputMonitoring && model.row(.inputMonitoring)?.status == .needsRestart) {
            return ("Restart Paneflo to finish turning on Input Monitoring.", "Restart Paneflo", .restart)
        }
        if !setup.isComplete {
            return ("Starts once Accessibility and Input Monitoring are on.", "Finish Setup…", .openSetup)
        }
        return nil
    }
}

struct TilingPane: View {
    let model: SettingsModel
    /// Read by the tiled-pairs feature (branch feat/tile-pairs): default on.
    static let raiseTogetherKey = "tilePairs.raiseTogether"
    @AppStorage(TilingPane.raiseTogetherKey) private var raiseTogether = true

    var body: some View {
        PaneForm(pane: .tiling) {
            Section {
                SubtitledToggle("Raise tile pairs together",
                                subtitle: "When you switch to a tiled window, bring its pair forward too.",
                                isOn: $raiseTogether)
            } header: {
                Text("Tile Pairs")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Footnote("Tile one window left with ⌘⌥←, then pick another and press ⌘⌥→ to pair them. ⌘⌥Return in the switcher or Overview opens a pair together.")
                    Button("All tiling keys are in Shortcuts & Help") { model.perform(.selectPane(.help)) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
            // TODO(workstream A): Snap assist (`pairs.snapAssist`), Also after ⌃⌥ shortcuts (`pairs.snapAssistGlobal`)
            // and Show pairs side by side (`pairs.sideBySide`) once those ship.
        }
    }
}
