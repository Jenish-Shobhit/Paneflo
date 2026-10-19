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
            Section {
                Picker("Card size", selection: model.cardSizeBinding) {
                    ForEach(CardSizePreference.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }
                SubtitledToggle("Show selected window title",
                                subtitle: "The full title of the selected window, on one line under the cards.",
                                isOn: model.surfaceToggle(.showsSelectedTitle))
            } header: {
                Text("Switcher")
            } footer: {
                Footnote("Automatic picks the largest cards that fit your windows on screen. Every key is in Shortcuts & Help.")
            }
            Section {
                SubtitledToggle("Show menu bar icon",
                                subtitle: "When it’s hidden, open Paneflo again from Spotlight, Launchpad or Applications to bring it back.",
                                isOn: model.toggle(\.menuBarIconVisible, SettingsAction.setMenuBarIcon))
            } header: {
                Text("Menu Bar")
            } footer: {
                if let note = model.menuBarNote { Footnote(note) }
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

    var body: some View {
        PaneForm(pane: .tiling) {
            Section {
                SubtitledToggle("Snap windows by dragging to screen edges",
                                subtitle: "Drag a window by its title bar to the top edge to fill the screen, to a side for half, or into a corner for a quarter. An outline shows where it will go; release to place it. Drag it away again to get its size back.",
                                isOn: model.surfaceToggle(.dragToSnap))
                if model.surface.dragToSnap, model.systemEdgeTiling, let url = URL(string: SystemEdgeTiling.settingsURL) {
                    StatusRow(tone: .attention, title: "macOS also tiles dragged windows",
                              detail: "Turn off “Drag windows to screen edges to tile” and “Drag windows to menu bar to fill screen” in Desktop & Dock, so only one of them acts.") {
                        Button("Open Desktop & Dock…") { model.perform(.openURL(url)) }
                    }
                }
            } header: {
                Text("Snap Areas")
            } footer: {
                Footnote("Only the outer edges of your displays count; an edge shared with another display doesn’t. Needs Accessibility.")
            }
            Section {
                SubtitledToggle("Raise tile pairs together",
                                subtitle: "When you switch to a tiled window, bring its pair forward too.",
                                isOn: model.surfaceToggle(.raiseTogether))
                SubtitledToggle("Show pairs side by side",
                                subtitle: "In ⌘Tab, the two halves of a pair sit next to each other, linked.",
                                isOn: model.surfaceToggle(.sideBySide))
                SubtitledToggle("Snap assist",
                                subtitle: "After you tile a window to a half from the switcher or Overview, the selected card shows an outline of the other half. Tile another window there to pair them.",
                                isOn: model.surfaceToggle(.snapAssist))
            } header: {
                Text("Tile Pairs")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Footnote("Tile one window left with ⌘⌥←, then pick another and press ⌘⌥→ to pair them. ⌘⌥Return in the switcher or Overview opens a pair together; ⌘A while switching, or ⌥Return in Overview, opens just the selected window.")
                    Button("All tiling keys are in Shortcuts & Help") { model.perform(.selectPane(.help)) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
            TilingShortcutsSection(model: model)
        }
    }
}

extension CardSizePreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
