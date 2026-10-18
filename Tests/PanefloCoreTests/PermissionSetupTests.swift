import Foundation
@testable import PanefloCore
import Testing

/// The setup state machine: rows, when setup shows, restart and stale-entry offers, auto-start, and saved choices.
@Suite struct PermissionSetupTests {
    static let none = PermissionState(accessibility: false, inputMonitoring: false, screenRecording: false)
    static let required = PermissionState(accessibility: true, inputMonitoring: true, screenRecording: false)
    static let all = PermissionState(accessibility: true, inputMonitoring: true, screenRecording: true)
    static let defaults = SetupIntent(shortcuts: true, gesture: false, previews: true)

    @Test func freshMachineListsAllThreeRowsWithScreenRecordingOptional() {
        let model = SetupModel(permissions: Self.none, intent: Self.defaults)
        #expect(model.rows.map(\.permission) == [.accessibility, .inputMonitoring, .screenRecording])
        #expect(model.rows.map(\.required) == [true, true, false])
        #expect(model.rows.allSatisfy { $0.status == .missing })
        #expect(model.missingRequired == [.accessibility, .inputMonitoring])
        #expect(!model.isComplete)
        #expect(!model.offersRestart)
        #expect(!model.showsStaleHint)
    }

    @Test func setupShowsOncePerLaunchAndNeverWhenComplete() {
        let missing = SetupModel(permissions: Self.none, intent: Self.defaults)
        #expect(missing.showsAtLaunch(alreadyShownThisLaunch: false))
        #expect(!missing.showsAtLaunch(alreadyShownThisLaunch: true))
        let complete = SetupModel(permissions: Self.required, intent: Self.defaults)
        #expect(complete.isComplete)
        #expect(!complete.showsAtLaunch(alreadyShownThisLaunch: false))
    }

    @Test func screenRecordingNeverBlocksSetup() {
        let model = SetupModel(permissions: Self.required, intent: SetupIntent(shortcuts: true, gesture: true, previews: true))
        #expect(model.isComplete)
        #expect(model.rows.last?.status == .missing)
        #expect(!model.runsPreviews)
    }

    @Test func inputMonitoringIsRequiredOnlyForShortcutsOrGesture() {
        let accessibilityOnly = PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false)
        let neither = SetupModel(permissions: accessibilityOnly, intent: SetupIntent(shortcuts: false, gesture: false, previews: false))
        #expect(neither.isComplete)
        let gesture = SetupModel(permissions: accessibilityOnly, intent: SetupIntent(shortcuts: false, gesture: true, previews: false))
        #expect(gesture.missingRequired == [.inputMonitoring])
        let shortcuts = SetupModel(permissions: accessibilityOnly, intent: Self.defaults)
        #expect(shortcuts.missingRequired == [.inputMonitoring])
    }

    @Test func requestedRelaunchPermissionOffersRestart() {
        var model = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                               intent: Self.defaults)
        #expect(!model.offersRestart)
        model.requested = [.inputMonitoring]
        #expect(model.rows[1].status == .needsRestart)
        #expect(model.offersRestart)
        #expect(!model.isComplete)
        // Granted live: no restart needed any more.
        model.permissions.inputMonitoring = true
        #expect(model.rows[1].status == .granted)
        #expect(!model.offersRestart)
        #expect(model.isComplete)
    }

    @Test func requestedAccessibilityNeverOffersRestart() {
        let model = SetupModel(permissions: Self.none, intent: Self.defaults, requested: [.accessibility])
        #expect(model.rows[0].status == .missing)
        #expect(!model.offersRestart)
    }

    @Test func featureFailureDespitePermissionOffersRestart() {
        let model = SetupModel(permissions: Self.all, intent: Self.defaults, serviceNeedsRestart: [.inputMonitoring])
        #expect(model.rows[1].status == .needsRestart)
        #expect(model.offersRestart)
        #expect(!model.isComplete)
        let previews = SetupModel(permissions: Self.all, intent: Self.defaults, serviceNeedsRestart: [.screenRecording])
        #expect(previews.offersRestart)
        #expect(previews.isComplete)
    }

    @Test func stillMissingAfterRelaunchSuggestsStaleEntries() {
        let model = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                               intent: Self.defaults, missingBeforeRelaunch: [.accessibility, .inputMonitoring])
        #expect(model.likelyStale == [.inputMonitoring])
        #expect(model.showsStaleHint)
        let fixed = SetupModel(permissions: Self.required, intent: Self.defaults, missingBeforeRelaunch: [.inputMonitoring])
        #expect(!fixed.showsStaleHint)
    }

    @Test func accessibilityStillOffAfterReturningFromSettingsSuggestsStaleEntries() {
        var model = SetupModel(permissions: Self.none, intent: Self.defaults, requested: [.accessibility])
        #expect(!model.showsStaleHint)
        model.returnedFromSettings = true
        #expect(model.likelyStale == [.accessibility])
        model.permissions.accessibility = true
        #expect(!model.showsStaleHint)
    }

    @Test func missingForRelaunchRecordsRequiredAndRequestedRows() {
        let model = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                               intent: Self.defaults, requested: [.screenRecording])
        #expect(model.missingForRelaunch == [.inputMonitoring, .screenRecording])
    }

    @Test func autoStartFollowsPermissionsAndIntent() {
        let missing = SetupModel(permissions: Self.none, intent: Self.defaults)
        #expect(!missing.startsShortcuts && !missing.startsGesture && !missing.runsPreviews)
        let ready = SetupModel(permissions: Self.all, intent: Self.defaults)
        #expect(ready.startsShortcuts)
        #expect(!ready.startsGesture)
        #expect(ready.runsPreviews)
        let off = SetupModel(permissions: Self.all, intent: SetupIntent(shortcuts: false, gesture: true, previews: false))
        #expect(!off.startsShortcuts && off.startsGesture && !off.runsPreviews)
    }

    @Test func permissionMetadataPointsAtTheRightPanes() {
        #expect(SetupPermission.accessibility.settingsURL.hasSuffix("Privacy_Accessibility"))
        #expect(SetupPermission.inputMonitoring.settingsURL.hasSuffix("Privacy_ListenEvent"))
        #expect(SetupPermission.screenRecording.settingsURL.hasSuffix("Privacy_ScreenCapture"))
        #expect(SetupPermission.allCases.map(\.tccService) == ["Accessibility", "ListenEvent", "ScreenCapture"])
        #expect(SetupPermission.allCases.filter(\.appliesAfterRelaunch) == [.inputMonitoring, .screenRecording])
    }
}

@Suite final class SetupPreferencesTests {
    let suite = "dev.paneflo.Paneflo.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: SetupPreferences

    init() {
        defaults = UserDefaults(suiteName: suite)!
        preferences = SetupPreferences(defaults: defaults)
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    @Test func defaultsAreShortcutsOnGestureOffPreviewsOnIconShown() {
        #expect(preferences.intent == SetupIntent(shortcuts: true, gesture: false, previews: true))
        #expect(!preferences.menuBarIconHidden)
        #expect(preferences.missingBeforeRelaunch.isEmpty)
    }

    @Test func anOlderBuildsFailedStartDoesNotKeepShortcutsOff() {
        defaults.set(false, forKey: SetupPreferences.shortcutsKey)
        #expect(preferences.shortcutsEnabled)
        let partial = SetupModel(permissions: PermissionState(accessibility: true, inputMonitoring: false, screenRecording: false),
                                 intent: preferences.intent)
        #expect(!preferences.noteSetup(partial))
        #expect(!preferences.shortcutsChoiceSettled)
        let complete = SetupModel(permissions: PermissionSetupTests.required, intent: preferences.intent)
        #expect(preferences.noteSetup(complete))
        #expect(preferences.shortcutsChoiceSettled)
        #expect(defaults.bool(forKey: SetupPreferences.shortcutsKey))
        #expect(!preferences.noteSetup(complete), "Only the first completion turns shortcuts on")
    }

    @Test func theUsersChoiceSticksAfterSetup() {
        preferences.shortcutsEnabled = false
        #expect(preferences.shortcutsChoiceSettled)
        #expect(!preferences.shortcutsEnabled)
        #expect(!preferences.noteSetup(SetupModel(permissions: PermissionSetupTests.all, intent: preferences.intent)))
        #expect(!SetupPreferences(defaults: defaults).shortcutsEnabled)
    }

    @Test func menuBarIconAndPreviewChoicesRoundTrip() {
        preferences.menuBarIconHidden = true
        preferences.previewsEnabled = false
        preferences.gestureEnabled = true
        let again = SetupPreferences(defaults: defaults)
        #expect(again.menuBarIconHidden)
        #expect(!again.previewsEnabled)
        #expect(again.gestureEnabled)
        again.menuBarIconHidden = false
        #expect(!preferences.menuBarIconHidden)
    }

    @Test func relaunchRecordIsReadOnce() {
        preferences.missingBeforeRelaunch = [.inputMonitoring, .screenRecording]
        #expect(SetupPreferences(defaults: defaults).takeMissingBeforeRelaunch() == [.inputMonitoring, .screenRecording])
        #expect(preferences.takeMissingBeforeRelaunch().isEmpty)
        defaults.set(["inputMonitoring", "bogus"], forKey: SetupPreferences.missingBeforeRelaunchKey)
        #expect(preferences.missingBeforeRelaunch == [.inputMonitoring])
    }
}

@Suite struct PermissionResetTests {
    @Test func resetsOnlyPanefloEntriesForEachPermission() {
        let invocations = PermissionReset.invocations(bundleID: "dev.paneflo.Paneflo")
        #expect(invocations == [
            ["reset", "Accessibility", "dev.paneflo.Paneflo"],
            ["reset", "ListenEvent", "dev.paneflo.Paneflo"],
            ["reset", "ScreenCapture", "dev.paneflo.Paneflo"],
        ])
        #expect(invocations.allSatisfy { $0.count == 3 && $0.last == "dev.paneflo.Paneflo" })
    }

    @Test func neverProducesAnUnscopedReset() {
        for bad in [nil, "", "Paneflo", "All", ".", "dev..Paneflo", "dev.paneflo Paneflo", "dev.paneflo;rm", "-dev.x\n", "-dev.paneflo"] as [String?] {
            #expect(PermissionReset.invocations(bundleID: bad).isEmpty, "\(String(describing: bad))")
        }
    }

    @Test func relaunchNeedsAnAppBundleAndWaitsForThisProcess() {
        #expect(RelaunchHelper.arguments(bundlePath: "/usr/local/bin/Paneflo", pid: 42) == nil)
        let arguments = RelaunchHelper.arguments(bundlePath: "/Applications/Paneflo.app", pid: 42)
        #expect(arguments?.suffix(3) == ["paneflo-relaunch", "/Applications/Paneflo.app", "42"])
        #expect(RelaunchHelper.script.contains("kill -0 \"$2\""))
        #expect(RelaunchHelper.script.contains("/usr/bin/open \"$1\""))
    }
}
