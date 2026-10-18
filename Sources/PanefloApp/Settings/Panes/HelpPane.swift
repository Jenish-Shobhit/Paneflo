import SwiftUI

/// One line of Shortcuts & Help: keycaps (none for a gesture or mouse note) and a one-line description.
struct HelpEntry: Hashable {
    let keys: [String]
    let text: String
    init(_ keys: [String], _ text: String) { self.keys = keys; self.text = text }
}

struct HelpGroup: Hashable {
    let title: String
    let entries: [HelpEntry]
}

/// Every key and gesture, checked against `ShortcutSession` (held ⌘ routing, ⌘⌥ tiling while a surface has a
/// selection, ⌃⌥ standalone chords), `SwitcherWindowCommand` (W/M/H/Q), the ⌃⌥ chords `AppDelegate.setShortcuts`
/// installs, and the Overview panel. Tile-pair keys come from the tiled-pairs feature (⌘⌥Return, keypad Enter too).
enum HelpContent {
    static let groups: [HelpGroup] = [
        HelpGroup(title: "Switcher", entries: [
            HelpEntry(["⌘", "⇥"], "Open the switcher; keep holding ⌘"),
            HelpEntry(["⇥", "⇧⇥"], "Next or previous window"),
            HelpEntry(["←", "→", "↑", "↓"], "Choose a window; ↑ and ↓ move by row"),
            HelpEntry(["release ⌘"], "Open the selected window"),
            HelpEntry(["esc"], "Cancel"),
            HelpEntry([], "Switch Windows… in the menu opens it with a search field: type to filter."),
        ]),
        HelpGroup(title: "Window Actions While Switching", entries: [
            HelpEntry(["⌘", "W"], "Close the selected window"),
            HelpEntry(["⌘", "M"], "Minimize it"),
            HelpEntry(["⌘", "H"], "Hide its app"),
            HelpEntry(["⌘", "Q"], "Quit its app (never Finder)"),
            HelpEntry([], "Other keys you press while switching never reach the app behind it."),
        ]),
        HelpGroup(title: "Tiling", entries: [
            HelpEntry(["⌘⌥←", "⌘⌥→"], "In the switcher or Overview: left or right half"),
            HelpEntry(["⌘⌥↑"], "Fill the display"),
            HelpEntry(["⌘⌥↓"], "Undo the last change"),
            HelpEntry([], "Press the same half again to move the window to the next display."),
            HelpEntry(["⌃⌥←", "⌃⌥→", "⌃⌥↑", "⌃⌥↓"], "Anywhere: tile the focused window to a half"),
            HelpEntry(["⌃⌥↩"], "Fill its display"),
            HelpEntry(["⌃⌥Z"], "Undo"),
        ]),
        HelpGroup(title: "Tile Pairs", entries: [
            HelpEntry(["⌘⌥←", "⌘⌥→"], "Tile one window left, choose another, tile it right: they pair"),
            HelpEntry(["⌘⌥↩"], "Open a pair together (keypad Enter too)"),
            HelpEntry([], "Switching to a tiled window brings its pair forward while Raise tile pairs together is on."),
        ]),
        HelpGroup(title: "Overview", entries: [
            HelpEntry(["⌃⌥Space"], "Open or close Overview"),
            HelpEntry([], "Three-finger swipe up opens it and down closes it, once turned on in Overview & Gesture."),
            HelpEntry(["←", "→", "↑", "↓"], "Move between slots"),
            HelpEntry([], "Type to search; slots stay where they are."),
            HelpEntry(["↩"], "Open the selected window (or click it)"),
            HelpEntry(["esc"], "Close"),
            HelpEntry([], "Drag a window onto another slot to move it; right-click for Move Slot and Pin Slot."),
        ]),
        HelpGroup(title: "Desktop", entries: [
            HelpEntry([], "The Desktop card ends the ⌘Tab loop and the Desktop tile starts Overview: choose it to see the desktop."),
            HelpEntry([], "Choose it again, or any window, to bring your windows back."),
        ]),
    ]

    /// Groups whose entries match `query` (description or spoken key names), empty groups dropped.
    static func filtered(_ query: String) -> [HelpGroup] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let groupMatches = group.title.localizedCaseInsensitiveContains(query)
            let entries = groupMatches ? group.entries : group.entries.filter { entry in
                entry.text.localizedCaseInsensitiveContains(query)
                    || entry.keys.contains { $0.localizedCaseInsensitiveContains(query) || KeyNames.spoken($0).localizedCaseInsensitiveContains(query) }
            }
            return entries.isEmpty ? nil : HelpGroup(title: group.title, entries: entries)
        }
    }
}

struct HelpPane: View {
    @Bindable var model: SettingsModel
    private var query: String { model.helpQuery }

    var body: some View {
        PaneForm(pane: .help) {
            Section {
                TextField("Search shortcuts", text: $model.helpQuery, prompt: Text("Search shortcuts"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Search shortcuts")
            }
            let groups = HelpContent.filtered(query)
            if groups.isEmpty {
                Section { Text("No shortcuts match “\(query)”.").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries, id: \.self) { entry in
                        if entry.keys.isEmpty {
                            Text(entry.text).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            KeycapRow(label: entry.text, keys: entry.keys)
                        }
                    }
                }
            }
        }
    }
}
