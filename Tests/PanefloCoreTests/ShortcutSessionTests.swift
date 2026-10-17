import Testing
@testable import PanefloCore

struct ShortcutSessionTests {
    @Test func arrowFunctionAnnotationIsNormalizedOnlyForArrows() {
        let chord = ShortcutChord(keyCode: 123, modifiers: [.control, .option])
        var router = ShortcutSession(configuration: .init(switcherEnabled: true, tiling: [chord: .tile(.leftHalf)]))
        #expect(router.route(kind: .down, keyCode: 123, modifiers: [.control, .option, .function]).suppress)
        #expect(!router.route(kind: .down, keyCode: 48, modifiers: [.command, .function]).suppress)
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let navigation = router.route(kind: .down, keyCode: 124, modifiers: [.command, .function])
        guard case .tileSelected(.rightHalf)? = navigation.action else { Issue.record("Missing selected-window tiling"); return }
    }

    @Test func selectedTilingDoesNotCommitOrChangeSessionAndRequiresContext() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        #expect(!router.route(kind: .down, keyCode: 123, modifiers: .command).suppress)
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let tile = router.route(kind: .down, keyCode: 123, modifiers: .command)
        guard case .tileSelected(.leftHalf)? = tile.action else { Issue.record("Missing left-half intent"); return }
        #expect(router.switching)
        #expect(router.route(kind: .up, keyCode: 123, modifiers: .command).suppress)
        let fill = router.route(kind: .down, keyCode: 126, modifiers: .command)
        guard case .tileSelected(.maximize)? = fill.action else { Issue.record("Missing fill intent"); return }
        #expect(!router.route(kind: .down, keyCode: 125, modifiers: .command).suppress)
        #expect(!router.route(kind: .down, keyCode: 124, modifiers: [.command, .option]).suppress)
        let release = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        guard case .commit? = release.action else { Issue.record("Missing deferred commit intent"); return }
        router.selectionContextActive = true
        #expect(router.route(kind: .down, keyCode: 124, modifiers: .command).suppress)
        #expect(!router.switching)
        #expect(router.route(kind: .modifiersChanged, keyCode: 55, modifiers: []).action == nil)
    }

    @Test func inactiveOverviewReleasesCommandArrowsWhileOwnedSwitchSessionKeepsThem() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        router.selectionContextActive = true
        #expect(router.route(kind: .down, keyCode: 123, modifiers: .command).suppress)
        _ = router.route(kind: .up, keyCode: 123, modifiers: .command)
        router.selectionContextActive = false
        #expect(!router.route(kind: .down, keyCode: 124, modifiers: .command).suppress)
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        #expect(router.route(kind: .down, keyCode: 124, modifiers: .command).suppress)
        #expect(router.switching)
    }

    @Test func selectedArrowRepeatsOnlyConsumeOwnedPressAndNewPressFiresAgain() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let unownedRepeat = router.route(kind: .down, keyCode: 123, modifiers: .command, isRepeat: true)
        #expect(!unownedRepeat.suppress && unownedRepeat.action == nil)
        let first = router.route(kind: .down, keyCode: 123, modifiers: .command)
        guard case .tileSelected(.leftHalf)? = first.action else { Issue.record("Missing first physical press"); return }
        let ownedRepeat = router.route(kind: .down, keyCode: 123, modifiers: .command, isRepeat: true)
        #expect(ownedRepeat.suppress && ownedRepeat.action == nil)
        #expect(router.route(kind: .up, keyCode: 123, modifiers: .command).suppress)
        let next = router.route(kind: .down, keyCode: 123, modifiers: .command)
        guard case .tileSelected(.leftHalf)? = next.action else { Issue.record("Missing new physical press"); return }
        let cycle = router.route(kind: .down, keyCode: 48, modifiers: .command, isRepeat: true)
        guard case .switchForward? = cycle.action else { Issue.record("Tab repeat must still cycle"); return }
    }

    @Test func switchPairAndRelease() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        let forward = router.route(kind: .down, keyCode: 48, modifiers: .command)
        #expect(forward.suppress)
        guard case .switchForward? = forward.action else { Issue.record("Missing forward"); return }
        let reverse = router.route(kind: .down, keyCode: 48, modifiers: [.command, .shift], isRepeat: true)
        guard case .switchBackward? = reverse.action else { Issue.record("Missing reverse"); return }
        #expect(router.route(kind: .up, keyCode: 48, modifiers: .command).suppress)
        let release = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        #expect(!release.suppress)
        guard case .commit? = release.action else { Issue.record("Missing commit"); return }
        #expect(router.route(kind: .modifiersChanged, keyCode: 54, modifiers: []).action == nil)
    }

    @Test func unrelatedAndInputMethodKeysPass() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        for modifiers: ShortcutModifiers in [[], [.command, .option], [.command, .control], [.command, .function]] {
            #expect(!router.route(kind: .down, keyCode: 48, modifiers: modifiers).suppress)
        }
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        for code: UInt16 in [0, 36, 49, 102, 104] {
            #expect(!router.route(kind: .down, keyCode: code, modifiers: .command).suppress)
        }
    }

    @Test func cancellationOwnsOnlyPairedKeys() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let cancel = router.route(kind: .down, keyCode: 53, modifiers: .command)
        guard case .cancel? = cancel.action else { Issue.record("Missing cancel"); return }
        #expect(router.route(kind: .modifiersChanged, keyCode: 55, modifiers: []).action == nil)
        #expect(router.route(kind: .up, keyCode: 53, modifiers: []).suppress)
        #expect(!router.route(kind: .up, keyCode: 0, modifiers: []).suppress)
        router.reset()
        #expect(!router.route(kind: .up, keyCode: 48, modifiers: []).suppress)
    }

    @Test func persistentKeyContextOwnsEscapeAndItsPairOnlyWhileActive() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        let inactive = router.route(kind: .down, keyCode: 53, modifiers: [])
        #expect(!inactive.suppress && inactive.action == nil)
        let inactiveRepeat = router.route(kind: .down, keyCode: 53, modifiers: [], isRepeat: true)
        #expect(!inactiveRepeat.suppress && inactiveRepeat.action == nil)
        router.selectionContextActive = true
        let owned = router.route(kind: .down, keyCode: 53, modifiers: [])
        #expect(owned.suppress)
        guard case .cancel? = owned.action else { Issue.record("Missing persistent-context cancel"); return }
        let repeated = router.route(kind: .down, keyCode: 53, modifiers: [], isRepeat: true)
        #expect(repeated.suppress && repeated.action == nil)
        router.selectionContextActive = false
        #expect(router.route(kind: .up, keyCode: 53, modifiers: []).suppress)
        #expect(!router.route(kind: .down, keyCode: 53, modifiers: []).suppress)
        router.selectionContextActive = true
        #expect(!router.route(kind: .down, keyCode: 53, modifiers: .option).suppress)
    }

    @Test func dedicatedChordDoesNotRepeatOrMatchExtraModifiers() {
        let chord = ShortcutChord(keyCode: 49, modifiers: [.control, .option])
        var router = ShortcutSession(configuration: .init(overview: chord))
        #expect(router.route(kind: .down, keyCode: 49, modifiers: chord.modifiers).suppress)
        let repeated = router.route(kind: .down, keyCode: 49, modifiers: chord.modifiers, isRepeat: true)
        #expect(repeated.suppress && repeated.action == nil)
        #expect(!router.route(kind: .down, keyCode: 49, modifiers: [.control, .option, .shift]).suppress)
        #expect(!router.route(kind: .down, keyCode: 48, modifiers: .command).suppress)
    }
}
