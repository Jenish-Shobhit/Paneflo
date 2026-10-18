import AppKit
import Observation
import PanefloCore
import SwiftUI

/// What the setup window's controls can ask for.
enum SetupUIAction: Equatable {
    case footer(SetupAction)
    case back
    case grant(SetupPermission)
    case reset
    case toggleGesture(Bool)
    case openTrackpadSettings
    case openPreviewSettings
}

/// The setup window's state: the latest `SetupModel` from the app, the step machine, and the system-gesture reading.
/// The view renders only these values, so the own-window checks read exactly what is on screen.
@MainActor @Observable
final class SetupViewModel {
    var setup: SetupModel?
    var flow = SetupFlow(step: .permissions)
    var gestureConflict = SystemGestureConflict(missionControl: false, appExpose: false, threeFingerDrag: false)
    @ObservationIgnored var perform: (SetupUIAction) -> Void = { _ in }

    /// Before the first reading, nothing is granted and nothing is asked for.
    var current: SetupModel {
        setup ?? SetupModel(permissions: PermissionState(accessibility: false, inputMonitoring: false, screenRecording: false),
                            intent: SetupIntent(shortcuts: true, gesture: false, previews: true))
    }

    var step: SetupStep { flow.step }

    var title: String {
        switch flow.step {
        case .welcome: "Welcome to Paneflo"
        case .permissions: "Give Paneflo access"
        case .gesture: "Swipe up for Overview"
        case .done: "You’re set"
        }
    }

    var body: String {
        switch flow.step {
        case .welcome: "Switch between windows, not apps. Tile them from the keyboard. Keep them in an Overview you arrange."
        case .permissions: "Click Grant, switch Paneflo on in the System Settings window that opens, then come back. Each row updates by itself."
        case .gesture: "Use a three-finger swipe up to open Overview, and down to close it. macOS uses the same swipe for Mission Control, so turn that off first."
        case .done: "Hold ⌘ and press Tab to try it."
        }
    }

    var primary: SetupAction { flow.primary(current) }
    var primaryEnabled: Bool { flow.isPrimaryEnabled(current) }
    var secondary: SetupAction? { flow.secondary(current) }
    var showsRestartCallout: Bool { flow.step == .permissions && current.offersRestart }
    var staleHint: String? { flow.step == .permissions ? current.staleHintText : nil }
}

struct SetupView: View {
    @Bindable var model: SetupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    switch model.step {
                    case .welcome: WelcomeStep(model: model)
                    case .permissions: PermissionsStep(model: model)
                    case .gesture: GestureStep(model: model)
                    case .done: DoneStep(model: model)
                    }
                }
                .id(model.step)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 12)),
                    removal: .opacity.combined(with: .offset(x: -12))))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                StepDots(step: model.step).padding(.top, 34)
            }
            .clipped()
            SetupFooter(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(edges: .top)
    }
}

/// Four 6 pt dots; the current step is an 18 pt accent capsule.
struct StepDots: View {
    let step: SetupStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.number) of \(SetupStep.allCases.count)")
    }
}

struct SetupFooter: View {
    let model: SetupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.flow.showsBack {
                    Button("Back") { send(.back) }.buttonStyle(.borderless)
                }
                Spacer()
                if let secondary = model.secondary {
                    Button(secondary.title) { send(.footer(secondary)) }
                        .controlSize(.large)
                        .modifier(CancelShortcutIf(secondary == .later || secondary == .skip))
                }
                Button(model.primary.title) { send(.footer(model.primary)) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.primaryEnabled)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
    }

    private func send(_ action: SetupUIAction) {
        withAnimation(PanefloWindowStyle.stepAnimation(reduceMotion: reduceMotion)) { model.perform(action) }
    }
}

/// Esc for Later / Skip.
struct CancelShortcutIf: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut(.cancelAction) } else { content }
    }
}

/// Title + body, shared by the steps.
struct StepHeader: View {
    let model: SetupViewModel
    var tag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.title).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let tag { RequirementTag(text: tag, required: false) }
            }
            Text(model.body).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Steps

struct WelcomeStep: View {
    let model: SetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomeHero().frame(height: 180)
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(model: model)
                VStack(alignment: .leading, spacing: 10) {
                    feature("command", "⌘Tab shows every window")
                    feature("rectangle.split.2x1", "⌃⌥ with the arrows tiles the front window")
                    feature("square.grid.2x2", "⌃⌥Space opens your Overview")
                }
            }
            .padding(.horizontal, 32)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(PanefloWindowStyle.brand).accessibilityHidden(true)
            Text(text).font(.system(size: 13))
        }
    }
}

/// Teal → coral band with three tiled panes and a ⌘Tab card row, drawn (no real windows).
struct WelcomeHero: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [PanefloWindowStyle.brand.opacity(0.35), PanefloWindowStyle.coral.opacity(0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 28) {
                HStack(spacing: 5) {
                    pane.frame(width: 70, height: 92)
                    VStack(spacing: 5) {
                        pane.frame(width: 70, height: 43.5)
                        pane.opacity(0.55).frame(width: 70, height: 43.5)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(index == 1 ? Color.accentColor : .clear, lineWidth: 2))
                            .frame(width: 46, height: 38)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.35)))
            }
            .padding(.top, 24)
        }
        .accessibilityHidden(true)
    }

    private var pane: some View {
        RoundedRectangle(cornerRadius: 6).fill(PanefloWindowStyle.brandTile.opacity(0.85))
    }
}

struct PermissionsStep: View {
    let model: SetupViewModel

    var body: some View {
        // Fits the default window in every state, the stuck-permission note included. Scrolling remains only as a
        // fallback for larger accessibility text sizes; the footer stays put.
        ScrollView {
            PermissionsStepContent(model: model)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct PermissionsStepContent: View {
    let model: SetupViewModel

    var body: some View {
        let setup = model.current
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(model: model).padding(.bottom, 4)
            ForEach(setup.rows, id: \.permission) { row in
                PermissionRow(row: row, prominent: setup.prominentGrant == row.permission,
                              onGrant: { model.perform(.grant(row.permission)) })
            }
            if model.showsRestartCallout {
                Callout {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    Text("macOS applies Input Monitoring and Screen Recording after Paneflo restarts.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            if let hint = model.staleHint {
                // The button sits under the note, so the note takes the full width and stays short.
                Callout(tint: PanefloWindowStyle.attention) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PanefloWindowStyle.attention)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(hint).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        Button("Reset and Grant Again…") { model.perform(.reset) }.buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)
            } else if !model.showsRestartCallout {
                Button("Permissions stuck? Reset and grant again") { model.perform(.reset) }
                    .buttonStyle(.link).font(.system(size: 12))
                    .help(PermissionReset.explanation)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 54)
        .padding(.bottom, 16)
    }
}

struct GestureStep: View {
    let model: SetupViewModel

    var body: some View {
        let conflict = model.gestureConflict
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(model: model, tag: "Optional")
            TrackpadIllustration().frame(maxWidth: .infinity).frame(height: 120)
            if conflict.missionControl || conflict.appExpose {
                StatusRow(tone: .attention, title: conflict.missionControl ? "Mission Control uses three-finger swipe up."
                          : "App Exposé uses three-finger swipe down.") {
                    Button(GestureGuidance.openSettingsButton) { model.perform(.openTrackpadSettings) }
                }
            } else {
                StatusRow(tone: .granted, title: GestureGuidance.statusNoConflict)
            }
            Toggle("Use the three-finger swipe", isOn: Binding(get: { model.current.intent.gesture },
                                                             set: { model.perform(.toggleGesture($0)) }))
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }
}

/// A trackpad outline with three finger dots and an up arrow.
struct TrackpadIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(PanefloWindowStyle.brand.opacity(0.6), lineWidth: 2)
                .frame(width: 180, height: 116)
            VStack(spacing: 8) {
                Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).foregroundStyle(PanefloWindowStyle.coral)
                HStack(spacing: 14) {
                    ForEach(0..<3) { _ in Circle().fill(PanefloWindowStyle.brand).frame(width: 14, height: 14) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct DoneStep: View {
    let model: SetupViewModel

    var body: some View {
        let setup = model.current
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(model: model)
            HStack(spacing: 10) {
                Keycap(text: "⌘", height: 36, fontSize: 17)
                Text("+").foregroundStyle(.secondary)
                Keycap(text: "⇥", height: 36, fontSize: 17)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Command plus Tab")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(setup.checklist, id: \.title) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isOn ? PanefloWindowStyle.granted : Color.secondary)
                            .accessibilityHidden(true)
                        Text(item.title).font(.system(size: 13))
                    }
                }
            }
            if !setup.permissions.screenRecording {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Want window pictures? Turn on Previews in Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Open Previews Settings") { model.perform(.openPreviewSettings) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }
}
