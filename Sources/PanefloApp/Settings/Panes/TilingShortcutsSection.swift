import AppKit
import PanefloCore
import SwiftUI

/// Tiling › Keyboard Shortcuts: one recorder per arrangement. Click a recorder, press the chord; Delete clears it and
/// Escape cancels. The global tiling chords pass through while one records (`SettingsAction.setShortcutRecording`).
struct TilingShortcutsSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            ForEach(TilingShortcutAction.allCases, id: \.self) { action in
                ShortcutRecorderRow(model: model, action: action)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Reset to Defaults") { model.perform(.resetTilingShortcuts) }
                    .disabled(model.tilingKeymap.isDefault && model.recordingAction == nil)
            }
        } header: {
            Text("Keyboard Shortcuts")
        } footer: {
            Text(model.tilingNote ?? "Click a shortcut, then press the keys you want. Delete clears it; Escape cancels.")
                .font(.system(size: 11))
                .foregroundStyle(model.tilingNoteIsProblem ? Color(nsColor: .systemOrange) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutRecorderRow: View {
    let model: SettingsModel
    let action: TilingShortcutAction

    private var chord: ShortcutChord? { model.tilingKeymap.chord(for: action) }
    private var isRecording: Bool { model.recordingAction == action }

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                Button { model.perform(.setShortcutRecording(isRecording ? nil : action)) } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isRecording ? Color.accentColor : chord == nil ? .secondary : .primary)
                        .frame(minWidth: 92)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: isRecording ? 1.5 : 0))
                .accessibilityLabel("\(action.title) shortcut")
                .accessibilityValue(spokenValue)
                .accessibilityHint(isRecording ? "Press the new shortcut, Delete to clear, Escape to cancel."
                                               : "Activate to record a new shortcut.")
                Button { model.perform(.setTilingShortcut(action, nil)) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(chord == nil ? 0 : 1)
                .disabled(chord == nil)
                .accessibilityLabel("Clear \(action.title) shortcut")
                .accessibilityHidden(chord == nil)
            }
        }
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        return chord.map(ShortcutKeyNames.glyphs) ?? "Record Shortcut"
    }

    private var spokenValue: String {
        if isRecording { return "Recording" }
        return chord.map(ShortcutKeyNames.spoken) ?? "Not set"
    }
}

/// Listens for the key being recorded while Settings is key. Swallows it so ⌘Q, ⌘W and the menu never see it.
@MainActor
final class ShortcutRecordingMonitor {
    static let shared = ShortcutRecordingMonitor()
    private var token: Any?

    func start(model: SettingsModel) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let (keyCode, flags, isRepeat) = (event.keyCode, event.modifierFlags.rawValue, event.isARepeat)
            let taken = MainActor.assumeIsolated {
                Self.handle(keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: flags), isRepeat: isRepeat, model: model)
            }
            return taken ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    isolated deinit { stop() }

    /// True when the event was taken.
    private static func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool, model: SettingsModel) -> Bool {
        guard let action = model.recordingAction else { return false }
        if isRepeat { return true }
        let modifiers = ShortcutKeyNames.modifiers(of: flags)
        switch keyCode {
        case 53 where modifiers.isEmpty:
            model.perform(.setShortcutRecording(nil))
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty:
            model.perform(.setTilingShortcut(action, nil))
        case let keyCode:
            model.perform(.setTilingShortcut(action, ShortcutChord(keyCode: keyCode, modifiers: modifiers)))
        }
        return true
    }
}
