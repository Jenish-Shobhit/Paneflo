import Testing
@testable import PanefloCore

struct GestureGuidanceTests {
    @Test func absentKeysAssumeTheThreeFingerSystemDefault() {
        let conflict = SystemGestureSettings().conflict
        #expect(conflict.missionControl && conflict.appExpose && !conflict.threeFingerDrag)
        #expect(conflict.conflictingSystemGesturesEnabled)
        #expect(GestureGuidance.status(for: conflict) == GestureGuidance.statusConflict)
    }

    @Test func gesturesTurnedOffOrMovedToFourFingersClearTheConflict() {
        // Off, or four fingers, sets the three-finger vertical key to 0 regardless of Dock keys.
        for dock in [nil, true, false] as [Bool?] {
            let settings = SystemGestureSettings(threeFingerVerticalSwipe: 0, missionControlGestureEnabled: dock,
                                                 appExposeGestureEnabled: dock)
            #expect(!settings.conflict.conflictingSystemGesturesEnabled)
            #expect(GestureGuidance.status(for: settings.conflict) == GestureGuidance.statusNoConflict)
        }
    }

    @Test func eachRemainingThreeFingerGestureIsNamed() {
        let appExposeOnly = SystemGestureSettings(threeFingerVerticalSwipe: 2, missionControlGestureEnabled: false)
        #expect(!appExposeOnly.conflict.missionControl && appExposeOnly.conflict.appExpose)
        #expect(GestureGuidance.status(for: appExposeOnly.conflict) == GestureGuidance.statusAppExposeConflict)

        let missionControlOnly = SystemGestureSettings(threeFingerVerticalSwipe: 2, missionControlGestureEnabled: true,
                                                       appExposeGestureEnabled: false)
        #expect(GestureGuidance.status(for: missionControlOnly.conflict) == GestureGuidance.statusMissionControlConflict)

        let bothOff = SystemGestureSettings(threeFingerVerticalSwipe: 2, missionControlGestureEnabled: false,
                                            appExposeGestureEnabled: false)
        #expect(!bothOff.conflict.conflictingSystemGesturesEnabled)

        let drag = SystemGestureSettings(threeFingerVerticalSwipe: 0, threeFingerDrag: true)
        #expect(drag.conflict.threeFingerDrag && !drag.conflict.conflictingSystemGesturesEnabled)
    }

    @Test func guidanceNamesBothSystemGesturesAndWhereToChangeThem() {
        for text in [GestureGuidance.conflictExplanation, GestureGuidance.statusConflict] {
            #expect(text.contains("Mission Control") && text.contains("App Exposé"))
            #expect(text.contains("System Settings › Trackpad › More Gestures"))
        }
        #expect(GestureGuidance.missionControlStep.contains("Four Fingers"))
        #expect(GestureGuidance.appExposeStep.contains("Four Fingers"))
        #expect(GestureGuidance.requirements.contains("macOS 26"))
    }

    @Test func readingCurrentPreferencesDoesNotCrash() {
        // Values are machine-specific; only the read path is exercised.
        _ = SystemGestureSettings.current().conflict
    }
}
