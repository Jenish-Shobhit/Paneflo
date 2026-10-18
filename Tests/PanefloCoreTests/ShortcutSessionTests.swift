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
        // Other modifier mixes are not actions, but nothing reaches the app behind the held picker.
        let other = router.route(kind: .down, keyCode: 124, modifiers: [.command, .control])
        #expect(other.suppress && other.action == nil && other.windowCommand == nil)
        let release = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        guard case .commit? = release.action else { Issue.record("Missing deferred commit intent"); return }
    }

    @Test func arrangingFiresOncePerPhysicalPress() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        // A repeat whose first press was not seen is swallowed while switching, and never arranges.
        let unownedRepeat = router.route(kind: .down, keyCode: 123, modifiers: [.command, .option], isRepeat: true)
        #expect(unownedRepeat.suppress && unownedRepeat.action == nil)
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

    @Test func watchdogCommitsAMissedReleaseOnlyForTheSameSession() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        #expect(router.commitIfCommandReleased(commandHeld: false, serial: router.sessionSerial) == nil, "idle: nothing to commit")
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let first = router.sessionSerial
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        #expect(router.sessionSerial == first, "Tab within a session keeps its serial")
        #expect(router.commitIfCommandReleased(commandHeld: true, serial: first) == nil, "Command still held")
        // The Command release was never seen and no other key followed: the picker would stay up.
        guard case .commit? = router.commitIfCommandReleased(commandHeld: false, serial: first) else {
            Issue.record("A missed release must commit"); return
        }
        #expect(!router.switching)
        #expect(router.commitIfCommandReleased(commandHeld: false, serial: first) == nil, "commits once")
        // A stale observation from the previous session cannot end a new one.
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        #expect(router.sessionSerial == first + 1)
        #expect(router.commitIfCommandReleased(commandHeld: false, serial: first) == nil)
        #expect(router.switching)
        // A normal release already committed: the watchdog's later poll is a no-op.
        _ = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        #expect(router.commitIfCommandReleased(commandHeld: false, serial: first + 1) == nil)
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
        for code: UInt16 in [0, 36, 49, 102, 104, 12, 13] {
            #expect(!router.route(kind: .down, keyCode: code, modifiers: .command).suppress, "idle: Command chords belong to the app")
            _ = router.route(kind: .up, keyCode: code, modifiers: .command)
        }
    }

    @Test func heldSwitcherSwallowsEveryOtherKeyAndItsRelease() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        // Command-A is open alone (its own test); Command–Shift–A is just swallowed.
        for (code, modifiers) in [(UInt16(0), ShortcutModifiers([.command, .shift])), (36, .command), (49, .command), (102, .command),
                                  (104, .command), (50, .command), (45, .command), (12, [.command, .shift]),
                                  (13, [.command, .option]), (1, [.command, .control])] {
            let route = router.route(kind: .down, keyCode: code, modifiers: modifiers)
            #expect(route.suppress && route.action == nil && route.windowCommand == nil, "key \(code) must not reach the frontmost app")
            #expect(router.route(kind: .down, keyCode: code, modifiers: modifiers, isRepeat: true).suppress)
            #expect(router.route(kind: .up, keyCode: code, modifiers: modifiers).suppress, "its key-up is paired")
        }
        #expect(router.switching, "swallowed keys never end the session")
        let release = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        guard case .commit? = release.action else { Issue.record("Release must still commit"); return }
        #expect(!router.route(kind: .down, keyCode: 0, modifiers: .command).suppress, "after the session keys pass again")
    }

    @Test func commandChordsBecomeWindowCommandsWhileSwitching() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let expected: [(UInt16, SwitcherWindowCommand)] = [(12, .quitApplication), (13, .close), (46, .minimize), (4, .hideApplication)]
        for (code, command) in expected {
            let route = router.route(kind: .down, keyCode: code, modifiers: .command)
            #expect(route.suppress && route.windowCommand == command && route.action == nil)
            let repeated = router.route(kind: .down, keyCode: code, modifiers: .command, isRepeat: true)
            #expect(repeated.suppress && repeated.windowCommand == nil, "once per physical press")
            #expect(router.route(kind: .up, keyCode: code, modifiers: .command).suppress)
            #expect(router.switching, "the switcher stays open after a window command")
        }
        // Tab keeps cycling after a command; a Shift chord is not a window command.
        guard case .switchForward? = router.route(kind: .down, keyCode: 48, modifiers: .command).action else {
            Issue.record("Tab must keep cycling"); return
        }
        #expect(router.route(kind: .down, keyCode: 13, modifiers: [.command, .shift]).windowCommand == nil)
        // Without a held switcher the same chords belong to the frontmost app.
        _ = router.route(kind: .modifiersChanged, keyCode: 55, modifiers: [])
        let idle = router.route(kind: .down, keyCode: 12, modifiers: .command)
        #expect(!idle.suppress && idle.windowCommand == nil)
        // The Overview is not a held switcher: Command-Q there is the app's.
        router.surfaceVisible = true
        router.selectionContextActive = true
        #expect(router.route(kind: .down, keyCode: 13, modifiers: .command).windowCommand == nil)
    }

    @Test func windowCommandsNeverTargetPanefloOrQuitFinder() {
        for command in [SwitcherWindowCommand.close, .minimize, .hideApplication, .quitApplication] {
            #expect(!command.isPermitted(bundleIdentifier: "dev.paneflo.Paneflo", isPaneflo: true))
            #expect(command.isPermitted(bundleIdentifier: "com.example.editor", isPaneflo: false))
            #expect(command.isPermitted(bundleIdentifier: nil, isPaneflo: false))
        }
        #expect(!SwitcherWindowCommand.quitApplication.isPermitted(bundleIdentifier: "com.apple.finder", isPaneflo: false))
        #expect(SwitcherWindowCommand.close.isPermitted(bundleIdentifier: "com.apple.finder", isPaneflo: false))
        #expect(SwitcherWindowCommand.hideApplication.isPermitted(bundleIdentifier: "com.apple.finder", isPaneflo: false))
        #expect(SwitcherWindowCommand(keyCode: 0) == nil)
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
    @Test func commandOptionReturnOpensThePairAndEndsTheHeldSession() {
        let maximize = ShortcutChord(keyCode: 36, modifiers: [.control, .option])
        var router = ShortcutSession(configuration: .init(switcherEnabled: true, tiling: [maximize: .tile(.maximize)]))
        // Outside a surface the chord belongs to the frontmost app.
        #expect(!router.route(kind: .down, keyCode: 36, modifiers: [.command, .option]).suppress)
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let open = router.route(kind: .down, keyCode: 36, modifiers: [.command, .option])
        guard case .openPair? = open.action else { Issue.record("Missing open-pair intent"); return }
        #expect(open.suppress && !router.switching)
        // The Return key-up and the later Command release are owned or inert: no second commit.
        #expect(router.route(kind: .up, keyCode: 36, modifiers: [.command, .option]).suppress)
        #expect(router.route(kind: .modifiersChanged, keyCode: 55, modifiers: []).action == nil)
        // Keypad Enter works the same; a held Return never reopens.
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        guard case .openPair? = router.route(kind: .down, keyCode: 76, modifiers: [.command, .option]).action else {
            Issue.record("Keypad Enter must open the pair"); return
        }
        let held = router.route(kind: .down, keyCode: 76, modifiers: [.command, .option], isRepeat: true)
        #expect(held.suppress && held.action == nil)
        // Control–Option–Return still fills the screen; Command–Return in the picker stays swallowed and inert.
        guard case .tile(.maximize)? = router.route(kind: .down, keyCode: 36, modifiers: [.control, .option]).action else {
            Issue.record("Control–Option–Return must keep filling the screen"); return
        }
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let plain = router.route(kind: .down, keyCode: 36, modifiers: .command)
        #expect(plain.suppress && plain.action == nil && plain.windowCommand == nil && router.switching)
    }

    @Test func commandOptionReturnOpensThePairInAKeyboardFocusedOverviewOnly() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        router.surfaceVisible = true
        router.selectionContextActive = true
        guard case .openPair? = router.route(kind: .down, keyCode: 36, modifiers: [.command, .option]).action else {
            Issue.record("Missing Overview open-pair"); return
        }
        _ = router.route(kind: .up, keyCode: 36, modifiers: [.command, .option])
        router.selectionContextActive = false
        #expect(!router.route(kind: .down, keyCode: 36, modifiers: [.command, .option]).suppress)
    }

    @Test func commandAOpensTheSelectionAloneAndEndsTheHeldSession() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        // Outside the held switcher Command-A belongs to the frontmost app (Select All), Overview included.
        #expect(!router.route(kind: .down, keyCode: 0, modifiers: .command).suppress)
        router.surfaceVisible = true
        router.selectionContextActive = true
        #expect(!router.route(kind: .down, keyCode: 0, modifiers: .command).suppress)
        router.surfaceVisible = false
        router.selectionContextActive = false
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        let alone = router.route(kind: .down, keyCode: 0, modifiers: .command)
        guard case .openAlone? = alone.action else { Issue.record("Missing open-alone intent"); return }
        #expect(alone.suppress && alone.windowCommand == nil && !router.switching)
        // A held A neither reopens nor leaks; its key-up and the later Command release are inert.
        let held = router.route(kind: .down, keyCode: 0, modifiers: .command, isRepeat: true)
        #expect(held.suppress && held.action == nil)
        #expect(router.route(kind: .up, keyCode: 0, modifiers: .command).suppress)
        #expect(router.route(kind: .modifiersChanged, keyCode: 55, modifiers: []).action == nil)
    }

    @Test func openAloneLeavesTheOtherHeldSwitcherKeysAsTheyWere() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = router.route(kind: .down, keyCode: 48, modifiers: .command)
        // Shift, Option or Control with A is not open alone: swallowed, and the session keeps switching.
        for modifiers: ShortcutModifiers in [[.command, .shift], [.command, .option], [.command, .control]] {
            let route = router.route(kind: .down, keyCode: 0, modifiers: modifiers)
            #expect(route.suppress && route.action == nil && route.windowCommand == nil && router.switching)
            _ = router.route(kind: .up, keyCode: 0, modifiers: modifiers)
        }
        // Window commands are unchanged.
        #expect(router.route(kind: .down, keyCode: 13, modifiers: .command).windowCommand == .close && router.switching)
        _ = router.route(kind: .up, keyCode: 13, modifiers: .command)
        // A pressed after Command was released is the missed release: commit, and A reaches the app.
        let late = router.route(kind: .down, keyCode: 0, modifiers: [])
        guard case .commit? = late.action else { Issue.record("A without Command must commit"); return }
        #expect(!late.suppress && !router.switching)
    }
}
