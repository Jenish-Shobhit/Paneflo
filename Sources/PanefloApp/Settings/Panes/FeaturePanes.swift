import PanefloCore
import SwiftUI

struct OverviewGesturePane: View {
    let model: SettingsModel

    var body: some View {
        PaneForm(pane: .overviewGesture) {
            // TODO(workstream A): an "Overview" section with Show free slots (`overview.showsFreeSlots`), "Remove Free
            // Slots" and "Reset Slot Order…" once DesktopController exposes removeFreeSlots() / resetSlots(). The
            // Overview keys are in Shortcuts & Help.
            Section {
                Toggle(GestureGuidance.toggleTitle, isOn: model.toggle(\.gestureEnabled, SettingsAction.toggleGesture))
                LabeledContent("Status") {
                    Text(model.gestureStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            } header: {
                HStack(spacing: 6) { Text("Trackpad Gesture"); ExperimentalTag() }
            } footer: {
                Footnote(GestureGuidance.requirements)
            }
            Section("System Gestures") {
                let conflict = model.gestureConflict
                if conflict.conflictingSystemGesturesEnabled {
                    StatusRow(tone: .attention, title: GestureGuidance.conflictTitle,
                              detail: GestureGuidance.status(for: conflict)) { trackpadButton }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• " + GestureGuidance.missionControlStep)
                        Text("• " + GestureGuidance.appExposeStep)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else {
                    StatusRow(tone: .granted, title: GestureGuidance.status(for: conflict)) { trackpadButton }
                }
                if conflict.threeFingerDrag {
                    StatusRow(tone: .neutral, symbol: "info.circle", title: GestureGuidance.threeFingerDragNote)
                }
            }
        }
    }

    private var trackpadButton: some View {
        Button(GestureGuidance.openSettingsButton) { model.perform(.openTrackpadSettings) }
    }
}

struct PreviewsPane: View {
    let model: SettingsModel

    var body: some View {
        PaneForm(pane: .previews) {
            Section {
                SubtitledToggle("Window previews",
                                subtitle: "The selected window updates live while the others show recent snapshots.",
                                isOn: model.toggle(\.previewsEnabled, SettingsAction.togglePreviews))
                    .disabled(!model.previewControlEnabled)
                screenRecordingRow
            } footer: {
                Footnote("Window pictures stay in memory. They’re never saved to disk or sent anywhere.")
            }
        }
    }

    @ViewBuilder private var screenRecordingRow: some View {
        if let row = model.row(.screenRecording) {
            switch row.status {
            case .granted:
                StatusRow(tone: .granted, title: "Screen Recording", detail: "On")
            case .missing:
                StatusRow(tone: model.previewsEnabled ? .attention : .neutral, title: "Screen Recording",
                          detail: model.previewPermissionMessage ?? "Off — needed for previews") {
                    Button("Grant…") { model.perform(.grant(.screenRecording)) }
                        .accessibilityLabel("Grant Screen Recording")
                }
            case .needsRestart:
                StatusRow(tone: .attention, symbol: "arrow.clockwise.circle.fill", title: "Screen Recording",
                          detail: model.previewPermissionMessage ?? "Restart Paneflo to apply") {
                    Button("Restart Paneflo") { model.perform(.restart) }
                }
            }
        }
    }

}

struct DesktopPane: View {
    let model: SettingsModel

    var body: some View {
        PaneForm(pane: .desktop) {
            Section {
                SubtitledToggle("Show Desktop in ⌘Tab and Overview",
                                subtitle: "Choosing it hides other apps so you see the desktop. Choose it again, or any window, to bring them back.",
                                isOn: model.toggle(\.desktopEntry, SettingsAction.toggleDesktopEntry))
                SubtitledToggle(isOn: model.toggle(\.systemShowDesktop, SettingsAction.toggleSystemShowDesktop),
                                subtitle: "Sends your Show Desktop shortcut instead of hiding apps. Needs permission to post keys.") {
                    HStack(spacing: 6) { Text("Use macOS Show Desktop"); ExperimentalTag() }
                }
                .accessibilityLabel("Use macOS Show Desktop, experimental")
            }
        }
    }
}
