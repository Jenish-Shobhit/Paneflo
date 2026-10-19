import Foundation
import Testing
@testable import PanefloCore

struct TilingShortcutsTests {
    private func chord(_ key: UInt16, _ modifiers: ShortcutModifiers) -> ShortcutChord { .init(keyCode: key, modifiers: modifiers) }
    private func assigned(_ outcome: TilingAssignmentOutcome) -> TilingAssignment? {
        if case .assigned(let assignment) = outcome { return assignment }
        return nil
    }

    // MARK: Defaults

    @Test func defaultsMatchTheOriginalBindings() {
        let keymap = TilingKeymap.defaults
        let control: ShortcutModifiers = [.control, .option]
        #expect(keymap.chord(for: .leftHalf) == chord(123, control))
        #expect(keymap.chord(for: .rightHalf) == chord(124, control))
        #expect(keymap.chord(for: .topHalf) == chord(126, control))
        #expect(keymap.chord(for: .bottomHalf) == chord(125, control))
        #expect(keymap.chord(for: .maximize) == chord(36, control))
        #expect(keymap.chord(for: .restore) == chord(6, control))
        #expect(keymap.chords.count == 6)
        #expect(keymap.chord(for: .center) == nil)
        #expect(keymap.table.count == 6)
        #expect(TilingKeymap.defaults.isDefault)
    }

    @Test func defaultsAreValidAndDoNotCollide() {
        for (action, chord) in TilingKeymap.defaults.chords {
            #expect(TilingShortcutRules.rejection(of: chord, overview: TilingKeymap.overviewChord) == nil, "\(action)")
        }
        #expect(TilingKeymap.defaults.action(for: TilingKeymap.overviewChord) == nil)
    }

    @Test func everyActionHasATitleAndARoutedAction() {
        for action in TilingShortcutAction.allCases { #expect(!action.title.isEmpty) }
        #expect(Set(TilingShortcutAction.allCases.compactMap(\.zone)) == Set(LayoutZone.allCases))
        guard case .restore = TilingShortcutAction.restore.shortcutAction else { Issue.record("restore"); return }
        guard case .tile(.center) = TilingShortcutAction.center.shortcutAction else { Issue.record("center"); return }
    }

    // MARK: Validation

    @Test func requiresCommandControlOrOption() {
        #expect(TilingShortcutRules.rejection(of: chord(0, []), overview: nil) == .needsModifier)
        #expect(TilingShortcutRules.rejection(of: chord(0, .shift), overview: nil) == .needsModifier)
        #expect(TilingShortcutRules.rejection(of: chord(0, [.function]), overview: nil) == .needsModifier)
        #expect(TilingShortcutRules.rejection(of: chord(0, .control), overview: nil) == nil)
        #expect(TilingShortcutRules.rejection(of: chord(0, .option), overview: nil) == nil)
        #expect(TilingShortcutRules.rejection(of: chord(0, [.command, .shift]), overview: nil) == nil)
    }

    @Test func functionKeysNeedNoModifier() {
        #expect(TilingShortcutRules.rejection(of: chord(96, []), overview: nil) == nil)
        #expect(TilingShortcutRules.rejection(of: chord(96, .function), overview: nil) == nil)
        #expect(TilingShortcutRules.rejection(of: chord(122, .shift), overview: nil) == nil)
    }

    @Test func switcherChordsAreReserved() {
        for modifiers: ShortcutModifiers in [.command, [.command, .shift]] {
            #expect(TilingShortcutRules.rejection(of: chord(48, modifiers), overview: nil) == .reservedBySwitcher)
            #expect(TilingShortcutRules.rejection(of: chord(50, modifiers), overview: nil) == .reservedBySwitcher)
        }
        #expect(TilingShortcutRules.rejection(of: chord(53, []), overview: nil) == .reservedBySwitcher)
        #expect(TilingShortcutRules.rejection(of: chord(53, .command), overview: nil) == .reservedBySwitcher)
        for key: UInt16 in [123, 124, 125, 126, 36, 76] {
            #expect(TilingShortcutRules.rejection(of: chord(key, [.command, .option]), overview: nil) == .reservedBySwitcher)
        }
        // ⌘⌥ with another key, and ⌃Tab, are free.
        #expect(TilingShortcutRules.rejection(of: chord(6, [.command, .option]), overview: nil) == nil)
        #expect(TilingShortcutRules.rejection(of: chord(48, .control), overview: nil) == nil)
    }

    @Test func overviewChordIsRejectedWithAnnotatedFunctionBit() {
        let overview = TilingKeymap.overviewChord
        #expect(TilingShortcutRules.rejection(of: overview, overview: overview) == .overviewChord)
        #expect(TilingShortcutRules.rejection(of: chord(49, [.control, .option, .function]), overview: overview) == .overviewChord)
        #expect(TilingShortcutRules.rejection(of: chord(49, [.control, .option, .shift]), overview: overview) == nil)
    }

    @Test func wellKnownSystemChordsWarn() {
        #expect(TilingShortcutRules.warning(for: chord(12, .command)) == .quit)
        #expect(TilingShortcutRules.warning(for: chord(13, .command)) == .closeWindow)
        #expect(TilingShortcutRules.warning(for: chord(49, .command)) == .spotlight)
        #expect(TilingShortcutRules.warning(for: chord(49, .control)) == .inputSource)
        for key: UInt16 in [20, 21, 23] { #expect(TilingShortcutRules.warning(for: chord(key, [.command, .shift])) == .screenshot) }
        #expect(TilingShortcutRules.warning(for: chord(12, [.command, .option])) == nil)
        #expect(TilingShortcutRules.warning(for: chord(123, [.control, .option])) == nil)
    }

    // MARK: Assignment

    @Test func assigningANewChordReplacesTheOldOne() throws {
        let result = try #require(assigned(TilingKeymap.defaults.assigning(chord(0, [.control, .option]), to: .leftHalf)))
        #expect(result.keymap.chord(for: .leftHalf) == chord(0, [.control, .option]))
        #expect(result.keymap.action(for: chord(123, [.control, .option])) == nil)
        #expect(result.displaced == nil)
        #expect(result.note(for: .leftHalf) == nil)
    }

    @Test func assigningATakenChordMovesItAndUnassignsTheOldAction() throws {
        let taken = chord(124, [.control, .option])
        let result = try #require(assigned(TilingKeymap.defaults.assigning(taken, to: .center)))
        #expect(result.displaced == .rightHalf)
        #expect(result.keymap.chord(for: .center) == taken)
        #expect(result.keymap.chord(for: .rightHalf) == nil)
        #expect(result.keymap.table.count == TilingKeymap.defaults.table.count)
        #expect(result.note(for: .center)?.contains("Right Half is now unassigned") == true)
    }

    @Test func reassigningTheSameChordToTheSameActionChangesNothing() throws {
        let same = chord(123, [.control, .option])
        let result = try #require(assigned(TilingKeymap.defaults.assigning(same, to: .leftHalf)))
        #expect(result.keymap == .defaults)
        #expect(result.displaced == nil)
    }

    @Test func rejectedAssignmentLeavesTheKeymapAlone() {
        let outcome = TilingKeymap.defaults.assigning(chord(48, .command), to: .center)
        #expect(outcome == .rejected(.reservedBySwitcher))
        #expect(TilingKeymap.defaults.assigning(TilingKeymap.overviewChord, to: .center) == .rejected(.overviewChord))
        #expect(TilingKeymap.defaults.assigning(chord(0, []), to: .center) == .rejected(.needsModifier))
    }

    @Test func warningsDoNotBlockAssignment() throws {
        let result = try #require(assigned(TilingKeymap.defaults.assigning(chord(12, .command), to: .center)))
        #expect(result.warning == .quit)
        #expect(result.keymap.chord(for: .center) == chord(12, .command))
        #expect(result.note(for: .center)?.contains("⌘Q") == true)
    }

    @Test func assignmentStripsTheFunctionBit() throws {
        let result = try #require(assigned(TilingKeymap.defaults.assigning(chord(126, [.control, .function]), to: .center)))
        #expect(result.keymap.chord(for: .center) == chord(126, .control))
    }

    @Test func clearingUnassigns() {
        let keymap = TilingKeymap.defaults.clearing(.restore)
        #expect(keymap.chord(for: .restore) == nil)
        #expect(keymap.table.count == 5)
    }

    // MARK: Persistence

    @Test func roundTripsThroughJSON() throws {
        var keymap = TilingKeymap.defaults.clearing(.maximize)
        keymap = try #require(assigned(keymap.assigning(chord(8, [.command, .shift, .control]), to: .center))).keymap
        #expect(TilingKeymap.decode(keymap.encoded()) == keymap)
    }

    @Test func missingOrCorruptDataGivesDefaults() {
        #expect(TilingKeymap.decode(nil) == .defaults)
        #expect(TilingKeymap.decode(Data("not json".utf8)) == .defaults)
        #expect(TilingKeymap.decode(Data(#"{"version":0,"entries":[]}"#.utf8)) == .defaults)
        #expect(TilingKeymap.decode(Data(#"{"entries":[]}"#.utf8)) == .defaults)
    }

    @Test func clearedActionsStayClearedAndUnmentionedActionsTakeTheirDefault() {
        // Only Left Half is mentioned, and cleared: the other defaults still apply.
        let data = Data(#"{"version":1,"entries":[{"action":"leftHalf","modifiers":0}]}"#.utf8)
        let keymap = TilingKeymap.decode(data)
        #expect(keymap.chord(for: .leftHalf) == nil)
        #expect(keymap.chord(for: .rightHalf) == chord(124, [.control, .option]))
        #expect(keymap.chord(for: .restore) == chord(6, [.control, .option]))
    }

    @Test func aDefaultTakenByAnotherActionStaysUnassigned() {
        // Center holds ⌃⌥← (a stored chord); Left Half isn't mentioned and its default is taken.
        let data = Data(#"{"version":1,"entries":[{"action":"center","keyCode":123,"modifiers":12}]}"#.utf8)
        let keymap = TilingKeymap.decode(data)
        #expect(keymap.chord(for: .center) == chord(123, [.control, .option]))
        #expect(keymap.chord(for: .leftHalf) == nil)
    }

    @Test func unknownInvalidAndDuplicateEntriesAreDropped() {
        let data = Data("""
        {"version":2,"entries":[
          {"action":"teleport","keyCode":5,"modifiers":8},
          {"action":"center","keyCode":0,"modifiers":0},
          {"action":"firstThird","keyCode":48,"modifiers":1},
          {"action":"lastThird","keyCode":0,"modifiers":4},
          {"action":"middleThird","keyCode":0,"modifiers":4},
          {"action":"leftHalf","keyCode":49,"modifiers":12}
        ]}
        """.utf8)
        let keymap = TilingKeymap.decode(data)
        #expect(keymap.chord(for: .center) == nil)
        #expect(keymap.chord(for: .firstThird) == nil)
        #expect(keymap.chord(for: .lastThird) == chord(0, .option))
        #expect(keymap.chord(for: .middleThird) == nil)
        #expect(keymap.chord(for: .leftHalf) == nil)
        #expect(Set(keymap.chords.values).count == keymap.chords.count)
    }

    @Test func storePersistsAndFallsBackToDefaults() throws {
        let suite = "paneflo.tests.tiling.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TilingKeymapStore(defaults: defaults)
        #expect(store.load() == .defaults)
        let custom = TilingKeymap.defaults.clearing(.topHalf)
        store.save(custom)
        #expect(store.load() == custom)
        store.save(.defaults)
        #expect(defaults.data(forKey: TilingKeymapStore.key) == nil)
        defaults.set(Data([0xFF, 0x00]), forKey: TilingKeymapStore.key)
        #expect(store.load() == .defaults)
    }

    // MARK: Display

    @Test func glyphsUseStandardModifierOrder() {
        #expect(ShortcutChordFormat.modifierGlyphs([.command, .shift, .option, .control]) == "⌃⌥⇧⌘")
        #expect(ShortcutChordFormat.glyphs(chord(123, [.control, .option])) == "⌃⌥←")
        #expect(ShortcutChordFormat.glyphs(chord(36, [.control, .option])) == "⌃⌥↩")
        #expect(ShortcutChordFormat.glyphs(chord(6, [.control, .option])) == "⌃⌥Z")
        #expect(ShortcutChordFormat.glyphs(chord(96, [])) == "F5")
        #expect(ShortcutChordFormat.glyphs(chord(49, .command)) == "⌘Space")
    }

    @Test func layoutLabelWinsForPrintableKeysOnly() {
        #expect(ShortcutChordFormat.glyphs(chord(6, .control), layoutLabel: "y") == "⌃Y")
        #expect(ShortcutChordFormat.glyphs(chord(123, .control), layoutLabel: "x") == "⌃←")
        #expect(ShortcutChordFormat.glyphs(chord(200, .control)) == "⌃Key 200")
    }

    @Test func spokenNamesAreFullWords() {
        #expect(ShortcutChordFormat.spoken(chord(123, [.control, .option])) == "Control Option Left Arrow")
        #expect(ShortcutChordFormat.spoken(chord(36, [.command, .shift])) == "Shift Command Return")
        #expect(ShortcutChordFormat.spoken(chord(6, .command), layoutLabel: "z") == "Command Z")
    }

    // MARK: Routing

    @Test func routingUsesTheKeymapTableAndPausesForRecording() {
        let keymap = TilingKeymap.defaults.clearing(.leftHalf)
        var router = ShortcutSession(configuration: .init(switcherEnabled: true, overview: TilingKeymap.overviewChord, tiling: keymap.table))
        // Cleared: passes through.
        #expect(!router.route(kind: .down, keyCode: 123, modifiers: [.control, .option]).suppress)
        let right = router.route(kind: .down, keyCode: 124, modifiers: [.control, .option])
        guard case .tile(.rightHalf)? = right.action else { Issue.record("Right Half"); return }
        _ = router.route(kind: .up, keyCode: 124, modifiers: [.control, .option])
        router.dedicatedChordsSuspended = true
        #expect(!router.route(kind: .down, keyCode: 124, modifiers: [.control, .option]).suppress)
        #expect(!router.route(kind: .down, keyCode: 49, modifiers: [.control, .option]).suppress)
        router.dedicatedChordsSuspended = false
        #expect(router.route(kind: .down, keyCode: 49, modifiers: [.control, .option]).suppress)
    }

    @Test func updatedConfigurationAppliesToTheNextKey() {
        var router = ShortcutSession(configuration: .init(tiling: TilingKeymap.defaults.table))
        let custom = chord(8, [.control, .option])
        #expect(!router.route(kind: .down, keyCode: 8, modifiers: [.control, .option]).suppress)
        router.configuration.tiling = [custom: .tile(.center)]
        guard case .tile(.center)? = router.route(kind: .down, keyCode: 8, modifiers: [.control, .option]).action else {
            Issue.record("Center"); return
        }
    }

    @Test func functionKeyShortcutsMatchWithTheFunctionBit() {
        var router = ShortcutSession(configuration: .init(tiling: [chord(96, []): .tile(.center)]))
        guard case .tile(.center)? = router.route(kind: .down, keyCode: 96, modifiers: .function).action else {
            Issue.record("F5"); return
        }
    }

    /// The recorder never keeps Fn, but the keyboard sets it on Home, End, Page Up/Down, Forward Delete and Help (and on
    /// any key while Fn is held, e.g. Fn–Return for Enter on a laptop). Such a recorded chord must still fire.
    @Test func navigationKeyShortcutsMatchWithTheFunctionBit() {
        let table: [ShortcutChord: ShortcutAction] = [
            chord(115, [.control, .option]): .tile(.leftHalf), chord(119, [.control, .option]): .tile(.rightHalf),
            chord(116, [.control, .option]): .tile(.topHalf), chord(121, [.control, .option]): .tile(.bottomHalf),
            chord(117, [.control, .option]): .tile(.center), chord(76, [.control, .option]): .tile(.maximize),
        ]
        var router = ShortcutSession(configuration: .init(switcherEnabled: true, overview: TilingKeymap.overviewChord, tiling: table))
        for (chord, expected) in table {
            let route = router.route(kind: .down, keyCode: chord.keyCode, modifiers: [.control, .option, .function])
            guard case .tile(let zone)? = route.action, case .tile(let wanted) = expected, zone == wanted else {
                Issue.record("key \(chord.keyCode) with Fn did not fire"); continue
            }
            #expect(route.suppress)
            #expect(router.route(kind: .up, keyCode: chord.keyCode, modifiers: [.control, .option, .function]).suppress)
        }
        guard case .overview? = router.route(kind: .down, keyCode: 49, modifiers: [.control, .option, .function]).action else {
            Issue.record("Overview with Fn"); return
        }
    }

    @Test func fnTabIsStillNotTheSwitcher() {
        var router = ShortcutSession(configuration: .init(switcherEnabled: true))
        #expect(router.route(kind: .down, keyCode: 48, modifiers: [.command, .function]).action == nil)
        #expect(!router.switching)
    }
}
