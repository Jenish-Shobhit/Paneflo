import Foundation
@testable import PanefloCore
import Testing

/// The setup window's steps, footer buttons, row presentation, the done-step summary, and the one-line app status.
@Suite struct SetupFlowTests {
    static let none = PermissionSetupTests.none
    static let required = PermissionSetupTests.required
    static let intent = PermissionSetupTests.defaults

    @Test func opensOnWelcomeOnlyOnAFreshFirstRun() {
        let fresh = SetupModel(permissions: Self.none, intent: Self.intent)
        #expect(SetupFlow.openingStep(for: fresh, welcomeSeen: false) == .welcome)
        #expect(SetupFlow.openingStep(for: fresh, welcomeSeen: true) == .permissions)
        let afterRestart = SetupModel(permissions: Self.none, intent: Self.intent, missingBeforeRelaunch: [.inputMonitoring])
        #expect(SetupFlow.openingStep(for: afterRestart, welcomeSeen: false) == .permissions)
        let requested = SetupModel(permissions: Self.none, intent: Self.intent, requested: [.accessibility])
        #expect(SetupFlow.openingStep(for: requested, welcomeSeen: false) == .permissions)
        let failed = SetupModel(permissions: Self.required, intent: Self.intent, serviceNeedsRestart: [.inputMonitoring])
        #expect(SetupFlow.openingStep(for: failed, welcomeSeen: false) == .permissions)
    }

    @Test func walksWelcomePermissionsGestureDone() {
        let complete = SetupModel(permissions: Self.required, intent: Self.intent)
        var flow = SetupFlow()
        #expect(!flow.showsBack)
        #expect(flow.primary(complete) == .getStarted && flow.secondary(complete) == nil)
        #expect(flow.perform(.getStarted, model: complete) == .none && flow.step == .permissions)
        #expect(flow.showsBack)
        #expect(flow.primary(complete) == .continueSetup && flow.isPrimaryEnabled(complete) && flow.secondary(complete) == nil)
        flow.perform(.continueSetup, model: complete)
        #expect(flow.step == .gesture)
        #expect(flow.primary(complete) == .continueSetup && flow.secondary(complete) == .skip)
        flow.perform(.skip, model: complete)
        #expect(flow.step == .done)
        #expect(flow.primary(complete) == .finish && flow.secondary(complete) == .openSettings)
        #expect(flow.perform(.finish, model: complete) == .close)
        #expect(flow.perform(.openSettings, model: complete) == .openSettings)
        flow.back(); flow.back()
        #expect(flow.step == .permissions)
        flow.back(); flow.back()
        #expect(flow.step == .welcome, "Back stops at the first step")
    }

    @Test func continueWaitsForTheRequiredPermissions() {
        let missing = SetupModel(permissions: Self.none, intent: Self.intent)
        var flow = SetupFlow(step: .permissions)
        #expect(flow.primary(missing) == .continueSetup)
        #expect(!flow.isPrimaryEnabled(missing))
        #expect(flow.secondary(missing) == .later)
        #expect(flow.perform(.continueSetup, model: missing) == .none)
        #expect(flow.step == .permissions, "Continue never skips missing required permissions")
        #expect(flow.perform(.later, model: missing) == .close)
    }

    @Test func restartBecomesThePrimaryButtonWhenOffered() {
        let waiting = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                                 intent: Self.intent, requested: [.inputMonitoring])
        let flow = SetupFlow(step: .permissions)
        #expect(waiting.offersRestart)
        #expect(flow.primary(waiting) == .restart && flow.isPrimaryEnabled(waiting))
        #expect(flow.secondary(waiting) == .later)
        var copy = flow
        #expect(copy.perform(.restart, model: waiting) == .restart)
        // Optional Screen Recording waiting for a restart: setup is complete, so Continue stays offered beside it.
        let optional = SetupModel(permissions: Self.required, intent: Self.intent, requested: [.screenRecording])
        #expect(optional.isComplete && optional.offersRestart)
        #expect(flow.primary(optional) == .restart && flow.secondary(optional) == .continueSetup)
    }

    @Test func rowsReadTheSameInSetupAndSettings() {
        let model = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                               intent: Self.intent, requested: [.inputMonitoring])
        let rows = model.rows
        #expect(rows.map(\.statusText) == ["On", "Switched on? Restart Paneflo to apply", "Off"])
        #expect(rows.map(\.tag) == ["Required", "Required", "Optional"])
        #expect(rows.map(\.tone) == [.granted, .attention, .neutral])
        #expect(rows.map(\.symbolName) == ["checkmark.circle.fill", "arrow.clockwise.circle.fill", "circle.dashed"])
        #expect(rows.map(\.showsGrant) == [false, true, true])
        let fresh = SetupModel(permissions: Self.none, intent: Self.intent)
        #expect(fresh.rows.first?.symbolName == "exclamationmark.circle.fill")
        #expect(fresh.prominentGrant == .accessibility)
        #expect(model.prominentGrant == nil, "A row waiting for a restart is not plainly off")
    }

    @Test func staleHintNamesTheStuckPermissions() {
        let stuck = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                               intent: Self.intent, missingBeforeRelaunch: [.inputMonitoring])
        #expect(stuck.staleHintText == "Input Monitoring still reads off. " + PermissionReset.explanation)
        #expect(SetupModel(permissions: Self.required, intent: Self.intent).staleHintText == nil)
    }

    @Test func checklistFollowsWhatActuallyStarts() {
        let complete = SetupModel(permissions: Self.required, intent: Self.intent)
        #expect(complete.checklist.map(\.title) == ["⌘Tab switcher on", "Tiling shortcuts on", "Gesture off"])
        #expect(complete.checklist.map(\.isOn) == [true, true, false])
        let gesture = SetupModel(permissions: Self.required, intent: SetupIntent(shortcuts: false, gesture: true, previews: true))
        #expect(gesture.checklist.map(\.title) == ["⌘Tab switcher off", "Tiling shortcuts off", "Gesture on"])
    }

    @Test func statusPrefersSetupThenRunningThenPause() {
        #expect(PanefloStatus(setupComplete: false, shortcutsWanted: true, shortcutsActive: true) == .setupNeeded)
        #expect(PanefloStatus(setupComplete: false, shortcutsWanted: false, shortcutsActive: false) == .setupNeeded)
        #expect(PanefloStatus(setupComplete: true, shortcutsWanted: true, shortcutsActive: true) == .ready)
        #expect(PanefloStatus(setupComplete: true, shortcutsWanted: false, shortcutsActive: false) == .paused)
        #expect(PanefloStatus(setupComplete: true, shortcutsWanted: true, shortcutsActive: false) == .starting)
        #expect(PanefloStatus.ready.title == "⌘Tab is ready")
        #expect(PanefloStatus.setupNeeded.title == "Setup needed")
        #expect(PanefloStatus.paused.title == "Shortcuts paused")
    }
}

@Suite final class SetupWelcomePreferenceTests {
    let suite = "dev.paneflo.Paneflo.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }

    @Test func welcomeShowsOnceAndNeverAfterAnEarlierSetup() {
        let preferences = SetupPreferences(defaults: defaults)
        #expect(!preferences.welcomeSeen)
        preferences.welcomeSeen = true
        #expect(SetupPreferences(defaults: defaults).welcomeSeen)
        defaults.removeObject(forKey: SetupPreferences.welcomeSeenKey)
        preferences.shortcutsEnabled = true
        #expect(preferences.welcomeSeen, "Someone who settled shortcuts in an earlier version skips Welcome")
    }
}
