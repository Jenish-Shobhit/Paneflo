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
        guard case .navigate(.forward)? = navigation.action else { Issue.record("Missing arrow selection"); return }
        let arrange = router.route(kind: .down, keyCode: 124, modifiers: [.command, .option, .function])
        guard case .tileSelected(.rightHalf)? = arrange.action else { Issue.record("Missing selected-window tiling"); return }
    }

    @Test func commandArrowsSelectInHeldSwitcherAndRepeatLikeTab() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let expected: [(UInt16, String)] = [(123, "back"), (124, "forward"), (126, "rowBack"), (125, "rowForward")]
        for (key, name) in expected {
            let route = router.route(kind: .down, keyCode: key, modifiers: .command)
            #expect(route.suppress, "Arrow \(name) must be owned while switching")
            switch (name, route.action) {
            case ("back", .navigate(.backward)?), ("forward", .navigate(.forward)?),
                 ("rowBack", .navigateRow(.backward)?), ("rowForward", .navigateRow(.forward)?): break
            default: Issue.record("Arrow \(name) produced \(String(describing: route.action))")
            }
            #expect(router.route(kind: .up, keyCode: key, modifiers: .command).suppress)
        }
        let repeated = router.route(kind: .down, keyCode: 124, modifiers: .command, isRepeat: true)
        guard case .navigate(.forward)? = repeated.action else { Issue.record("Held arrow must keep moving"); return }
        #expect(router.switching)
        let shifted = router.route(kind: .down, keyCode: 48, modifiers: [.command, .shift])
        guard case .switchBackward? = shifted.action else { Issue.record("Shift–Tab must still reverse"); return }
    }

    @Test func optionArrowsArrangeWhileSwitchingWithoutCommitting() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        #expect(!router.route(kind: .down, keyCode: 123, modifiers: [.command, .option]).suppress)
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let left = router.route(kind: .down, keyCode: 123, modifiers: [.command, .option])
        guard case .tileSelected(.leftHalf)? = left.action else { Issue.record("Missing left-half intent"); return }
        #expect(router.switching)
        #expect(router.route(kind: .up, keyCode: 123, modifiers: [.command, .option]).suppress)
        let fill = router.route(kind: .down, keyCode: 126, modifiers: [.command, .option])
        guard case .tileSelected(.maximize)? = fill.action else { Issue.record("Missing fill intent"); return }
        let undo = router.route(kind: .down, keyCode: 125, modifiers: [.command, .option])
        guard case .restore? = undo.action else { Issue.record("Missing undo intent"); return }
        // Other modifier mixes are not Paneflo's.
        #expect(!router.route(kind: .down, keyCode: 124, modifiers: [.command, .control]).suppress)
        let release = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        guard case .commit? = release.action else { Issue.record("Missing deferred commit intent"); return }
    }

    @Test func arrangingFiresOncePerPhysicalPress() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let unownedRepeat = router.route(kind: .down, keyCode: 123, modifiers: [.command, .option], isRepeat: true)
        #expect(!unownedRepeat.suppress && unownedRepeat.action == nil)
        let first = router.route(kind: .down, keyCode: 123, modifiers: [.command, .option])
        guard case .tileSelected(.leftHalf)? = first.action else { Issue.record("Missing first physical press"); return }
        let ownedRepeat = router.route(kind: .down, keyCode: 123, modifiers: [.command, .option], isRepeat: true)
        #expect(ownedRepeat.suppress && ownedRepeat.action == nil)
        #expect(router.route(kind: .up, keyCode: 123, modifiers: [.command, .option]).suppress)
        _ = router.route(kind: .down, keyCode: 125, modifiers: [.command, .option])
        let undoRepeat = router.route(kind: .down, keyCode: 125, modifiers: [.command, .option], isRepeat: true)
        #expect(undoRepeat.suppress && undoRepeat.action == nil)
        let cycle = router.route(kind: .down, keyCode: 48, modifiers: .command, isRepeat: true)
        guard case .switchForward? = cycle.action else { Issue.record("Tab repeat must still cycle"); return }
    }

    @Test func overviewArrangesWithCommandOptionArrowsOnlyWithKeyboardFocus() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        router.surfaceVisible = true
        router.selectionContextActive = true
        // Command–arrows are not arranging chords in the Overview; the panel treats them as selection.
        #expect(!router.route(kind: .down, keyCode: 123, modifiers: .command).suppress)
        let tile = router.route(kind: .down, keyCode: 123, modifiers: [.command, .option])
        guard case .tileSelected(.leftHalf)? = tile.action else { Issue.record("Missing Overview tiling"); return }
        _ = router.route(kind: .up, keyCode: 123, modifiers: [.command, .option])
        let fill = router.route(kind: .down, keyCode: 126, modifiers: [.command, .option])
        guard case .tileSelected(.maximize)? = fill.action else { Issue.record("Missing Overview fill"); return }
        let undo = router.route(kind: .down, keyCode: 125, modifiers: [.command, .option])
        guard case .restore? = undo.action else { Issue.record("Missing Overview undo"); return }
        _ = router.route(kind: .up, keyCode: 125, modifiers: [.command, .option])
        // Visible without keyboard focus: other apps keep their Command–Option–arrow shortcuts.
        router.selectionContextActive = false
        #expect(!router.route(kind: .down, keyCode: 124, modifiers: [.command, .option]).suppress)
        #expect(!router.switching)
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

    @Test func missedCommandReleaseIsRecoveredByNextKeyWithoutEatingIt() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        // The Command-up flagsChanged never arrived; the next key press reports no Command.
        let next = router.route(kind: .down, keyCode: 0, modifiers: [])
        guard case .commit? = next.action else { Issue.record("Missed release must commit"); return }
        #expect(!next.suppress)
        #expect(!router.switching)
        // Standalone chords work again instead of being blocked by a stuck session.
        let chord = ShortcutChord(keyCode: 49, modifiers: [.control, .option])
        router.configuration.overview = chord
        guard case .overview? = router.route(kind: .down, keyCode: 49, modifiers: chord.modifiers).action else {
            Issue.record("Overview chord must work after recovery"); return
        }
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let plainEscape = router.route(kind: .down, keyCode: 53, modifiers: [])
        guard case .cancel? = plainEscape.action else { Issue.record("Escape still cancels a held session"); return }
    }

    @Test func tapInterruptionRecoveryCommitsOnlyWhenCommandWasReleased() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let heldRecovery = router.recoverAfterTapInterruption(commandHeld: true)
        #expect(heldRecovery == nil)
        #expect(router.switching)
        #expect(!router.route(kind: .up, keyCode: 48, modifiers: .command).suppress, "Pairing state is dropped")
        guard case .commit? = router.recoverAfterTapInterruption(commandHeld: false) else {
            Issue.record("Released Command must commit after re-enable"); return
        }
        #expect(!router.switching)
        let idleRecovery = router.recoverAfterTapInterruption(commandHeld: false)
        #expect(idleRecovery == nil)
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

    @Test func visibleSurfaceOwnsEscapeEvenWithoutKeyboardFocus() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        let hidden = router.route(kind: .down, keyCode: 53, modifiers: [])
        #expect(!hidden.suppress && hidden.action == nil)
        let hiddenRepeat = router.route(kind: .down, keyCode: 53, modifiers: [], isRepeat: true)
        #expect(!hiddenRepeat.suppress && hiddenRepeat.action == nil)
        // Visible but neither key nor active (the activation flap): Escape is still Paneflo's.
        router.surfaceVisible = true
        router.selectionContextActive = false
        let owned = router.route(kind: .down, keyCode: 53, modifiers: [])
        #expect(owned.suppress)
        guard case .cancel? = owned.action else { Issue.record("Missing visible-surface cancel"); return }
        let repeated = router.route(kind: .down, keyCode: 53, modifiers: [], isRepeat: true)
        #expect(repeated.suppress && repeated.action == nil)
        router.surfaceVisible = false
        #expect(router.route(kind: .up, keyCode: 53, modifiers: []).suppress)
        #expect(!router.route(kind: .down, keyCode: 53, modifiers: []).suppress)
        router.surfaceVisible = true
        #expect(!router.route(kind: .down, keyCode: 53, modifiers: .option).suppress)
    }

    @Test func compositionEscapePassesThenNextPressCloses() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        router.surfaceVisible = true
        router.compositionActive = true
        let composing = router.route(kind: .down, keyCode: 53, modifiers: [])
        #expect(!composing.suppress && composing.action == nil)
        #expect(!router.route(kind: .up, keyCode: 53, modifiers: []).suppress)
        router.compositionActive = false
        let closing = router.route(kind: .down, keyCode: 53, modifiers: [])
        #expect(closing.suppress)
        guard case .cancel? = closing.action else { Issue.record("Expected cancel after composition ends"); return }
    }

    @Test func resetRelinquishesEscapeOwnership() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        router.surfaceVisible = true
        _ = router.route(kind: .down, keyCode: 53, modifiers: [])
        router.reset()
        #expect(!router.surfaceVisible && !router.selectionContextActive)
        #expect(!router.route(kind: .down, keyCode: 53, modifiers: []).suppress)
        #expect(!router.route(kind: .up, keyCode: 53, modifiers: []).suppress)
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

    @Test func standaloneTilingChordsDoNotCollideWithSwitcherArranging() {
        let left = ShortcutChord(keyCode: 123, modifiers: [.control, .option])
        var router = ShortcutSession(configuration: .init(switcherEnabled: true, tiling: [left: .tile(.leftHalf)]))
        guard case .tile(.leftHalf)? = router.route(kind: .down, keyCode: 123, modifiers: [.control, .option]).action else {
            Issue.record("Standalone tiling must keep its chord"); return
        }
        _ = router.route(kind: .up, keyCode: 123, modifiers: [.control, .option])
        #expect(!router.route(kind: .down, keyCode: 123, modifiers: [.command, .option]).suppress)
    }
}
