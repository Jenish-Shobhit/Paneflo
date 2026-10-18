import Testing
@testable import PanefloCore

/// ST-01: model-based fuzz of ShortcutSession. Fixed seeds; every failure prints its seed and step.
struct FuzzShortcutSessionTests {
    private static let tab: UInt16 = 48, esc: UInt16 = 53
    private static let keyPool: [UInt16] = [48, 48, 48, 53, 53, 123, 124, 125, 126, 36, 76, 49, 13, 46, 4, 12, 6, 0, 8]
    private static let cmd = ShortcutModifiers.command

    private static func configurations() -> [ShortcutConfiguration] {
        let overview = ShortcutChord(keyCode: 49, modifiers: [.control, .option])
        let tiling: [ShortcutChord: ShortcutAction] = [
            ShortcutChord(keyCode: 123, modifiers: [.control, .option]): .tile(.leftHalf),
            ShortcutChord(keyCode: 124, modifiers: [.control, .option]): .tile(.rightHalf),
            ShortcutChord(keyCode: 126, modifiers: [.control, .option]): .tile(.maximize),
        ]
        return [
            ShortcutConfiguration(),
            ShortcutConfiguration(switcherEnabled: true),
            ShortcutConfiguration(switcherEnabled: true, overview: overview, tiling: tiling),
            ShortcutConfiguration(switcherEnabled: false, overview: overview, tiling: tiling),
        ]
    }

    private static func randomModifiers(_ rng: inout FuzzRandom) -> ShortcutModifiers {
        ShortcutModifiers(rawValue: UInt8(rng.int(0...31)))
    }

    private func normalized(_ key: UInt16, _ mods: ShortcutModifiers) -> ShortcutModifiers {
        (123...126).contains(key) ? mods.subtracting(.function) : mods
    }

    @Test func routerAgreesWithModelAndInvariants() {
        let configs = Self.configurations()
        for seed in UInt64(0)..<2000 {
            var rng = FuzzRandom(seed: seed)
            let config = configs[Int(seed % UInt64(configs.count))]
            var session = ShortcutSession(configuration: config)
            var owned: Set<UInt16> = []      // definite: non-repeat suppressed downs
            var possible: Set<UInt16> = []   // any suppressed down
            var sticky: ShortcutModifiers = []
            let count = rng.int(1...200)
            for step in 0..<count {
                let ctx: Comment = "seed \(seed) step \(step)"
                let roll = rng.int(0...99)
                let pre = (switching: session.switching, visible: session.surfaceVisible,
                           selection: session.selectionContextActive, composing: session.compositionActive)
                switch roll {
                case 0..<8: // modifier change, usually coherent with the sticky set
                    sticky = rng.chance(0.7) ? sticky.symmetricDifference(ShortcutModifiers(rawValue: UInt8(1 << rng.int(0...4)))) : Self.randomModifiers(&rng)
                    let route = session.route(kind: .modifiersChanged, keyCode: 55, modifiers: sticky)
                    if !sticky.contains(.command) {
                        #expect(!session.switching, "switching survived a no-command flags event; \(ctx)")
                    }
                    if pre.switching && !sticky.contains(.command) {
                        guard case .commit? = route.action else { fail("missing commit; \(ctx)"); return }
                    } else {
                        #expect(route.action == nil && !route.suppress, "flags event acted; \(ctx)")
                    }
                case 8..<10:
                    session.reset(); owned.removeAll(); possible.removeAll()
                    #expect(!session.switching && !session.surfaceVisible && !session.compositionActive, "reset; \(ctx)")
                    #expect(session.commitIfCommandReleased(commandHeld: false, serial: session.sessionSerial) == nil, "action after reset; \(ctx)")
                case 10..<13:
                    let held = rng.chance(0.5)
                    let action = session.recoverAfterTapInterruption(commandHeld: held)
                    owned.removeAll(); possible.removeAll()
                    if pre.switching && !held {
                        guard case .commit? = action else { fail("recover must commit; \(ctx)"); return }
                        #expect(!session.switching, ctx)
                    } else {
                        #expect(action == nil && session.switching == pre.switching, "recover changed state; \(ctx)")
                    }
                case 13..<16:
                    let serial = rng.chance(0.7) ? session.sessionSerial : session.sessionSerial &+ 1
                    let held = rng.chance(0.4)
                    let action = session.commitIfCommandReleased(commandHeld: held, serial: serial)
                    if action != nil { #expect(pre.switching && !held && serial == session.sessionSerial && !session.switching, ctx) }
                    else { #expect(session.switching == pre.switching, ctx) }
                case 16..<20:
                    switch rng.int(0...2) {
                    case 0: session.surfaceVisible.toggle()
                    case 1: session.selectionContextActive.toggle()
                    default: session.compositionActive.toggle()
                    }
                case 20..<42: // key up
                    let key = rng.pick(Self.keyPool)
                    let route = session.route(kind: .up, keyCode: key, modifiers: sticky)
                    if owned.contains(key) { #expect(route.suppress, "owned key-up leaked; \(ctx)") }
                    if !possible.contains(key) { #expect(!route.suppress, "unowned key-up eaten; \(ctx)") }
                    owned.remove(key); possible.remove(key)
                    #expect(route.action == nil && route.windowCommand == nil, "up acted; \(ctx)")
                default: // key down
                    let key = rng.chance(0.9) ? rng.pick(Self.keyPool) : UInt16(rng.int(0...200))
                    let mods = rng.chance(0.75) ? sticky : Self.randomModifiers(&rng)
                    let isRepeat = rng.chance(0.25)
                    var twin = session
                    let route = session.route(kind: .down, keyCode: key, modifiers: mods, isRepeat: isRepeat)
                    let again = twin.route(kind: .down, keyCode: key, modifiers: mods, isRepeat: isRepeat)
                    #expect(route.suppress == again.suppress && route.windowCommand == again.windowCommand
                            && "\(String(describing: route.action))" == "\(String(describing: again.action))", "nondeterministic; \(ctx)")
                    let eff = normalized(key, mods)
                    let hasCommand = eff.contains(.command)
                    let describe: Comment = "key \(key) mods \(eff.rawValue) repeat \(isRepeat) pre \(pre); \(ctx)"

                    if route.suppress { possible.insert(key); if !isRepeat { owned.insert(key) } }

                    if pre.switching && !hasCommand && key != Self.esc {
                        guard case .commit? = route.action else { fail("lost-command key must commit; \(describe)"); return }
                        #expect(!route.suppress && !session.switching, "commit key was eaten; \(describe)")
                        continue
                    }
                    if pre.switching && hasCommand {
                        #expect(route.suppress, "key leaked to app behind held switcher; \(describe)")
                    }
                    if key == Self.esc && !isRepeat && eff.subtracting([.command, .shift]).isEmpty && pre.switching {
                        guard case .cancel? = route.action else { fail("Esc must cancel held switcher; \(describe)"); return }
                        #expect(route.suppress && !session.switching, describe)
                    }
                    if key == Self.esc && !isRepeat && eff.isEmpty && !pre.switching {
                        if pre.visible && !pre.composing {
                            guard case .cancel? = route.action, route.suppress else { fail("visible Esc must cancel and be suppressed; \(describe)"); return }
                        } else if pre.visible && pre.composing {
                            #expect(route.action == nil && !route.suppress, "IME Esc intercepted; \(describe)")
                        }
                    }
                    if key == Self.esc && route.suppress && !isRepeat && eff.subtracting([.command, .shift]).isEmpty && (pre.switching || pre.visible) && !pre.composing {
                        #expect(route.action != nil, "suppressed Esc without action; \(describe)")
                    }
                    // Starting a session needs Tab + Command (no Fn, no other modifiers) and the switcher enabled.
                    if session.switching && !pre.switching {
                        #expect(key == Self.tab && config.switcherEnabled && (eff == Self.cmd || eff == [.command, .shift]), "switching started without Tab; \(describe)")
                    }
                    if !config.switcherEnabled { #expect(!session.switching, "switching with switcher disabled; \(describe)") }
                    // Idle session: only owned chords are suppressed.
                    if !pre.switching && !pre.visible && !pre.selection && route.suppress && !route.action.isNil {
                        let chord = ShortcutChord(keyCode: key, modifiers: eff)
                        let tabStart = config.switcherEnabled && key == Self.tab && (eff == Self.cmd || eff == [.command, .shift])
                        #expect(tabStart || config.overview == chord || config.tiling[chord] != nil, "suppressed foreign chord; \(describe)")
                    }
                    if !pre.switching && !pre.visible && !pre.selection && route.suppress && route.action.isNil {
                        #expect(isRepeat, "suppressed without action and not a repeat; \(describe)")
                    }
                    if isRepeat && !pre.switching, let action = route.action {
                        // Dedicated chords never re-fire; only Tab, arrows (navigation) and Esc-cancel-free paths repeat.
                        switch action {
                        case .overview, .tile, .tileSelected, .restore, .openPair, .cancel: fail("repeat re-fired \(action); \(describe)")
                        default: break
                        }
                    }
                    if route.windowCommand != nil { #expect(pre.switching && eff == Self.cmd && !isRepeat, "window command outside held switcher; \(describe)") }
                }
            }
        }
    }

    @Test func everyKeyCodeIsHandledWithoutTrapping() {
        let configs = Self.configurations()
        let combos: [ShortcutModifiers] = [[], .command, [.command, .shift], [.command, .option], [.control, .option], [.command, .function], [.command, .control, .option, .shift, .function]]
        for config in configs {
            for key in UInt16.min...UInt16.max {
                for mods in combos {
                    var session = ShortcutSession(configuration: config)
                    _ = session.route(kind: .down, keyCode: key, modifiers: mods, isRepeat: key % 2 == 0)
                    session.surfaceVisible = true; session.selectionContextActive = true
                    _ = session.route(kind: .down, keyCode: key, modifiers: mods)
                    _ = session.route(kind: .up, keyCode: key, modifiers: mods)
                }
            }
        }
    }

    @Test func emptyConfigurationNeverSuppressesIdleKeys() {
        var session = ShortcutSession(configuration: ShortcutConfiguration())
        var rng = FuzzRandom(seed: 99)
        for _ in 0..<5000 {
            let key = UInt16(rng.int(0...200)), mods = Self.randomModifiers(&rng)
            let route = session.route(kind: rng.chance(0.3) ? .up : .down, keyCode: key, modifiers: mods, isRepeat: rng.chance(0.3))
            #expect(!route.suppress && route.action == nil)
        }
    }

    @Test func recoverWithCommandHeldNeverEmitsAndResetIsIdempotent() {
        var session = ShortcutSession(configuration: .init(switcherEnabled: true))
        _ = session.route(kind: .down, keyCode: 48, modifiers: .command)
        #expect(session.recoverAfterTapInterruption(commandHeld: true) == nil && session.switching)
        session.reset(); session.reset()
        #expect(!session.switching && session.recoverAfterTapInterruption(commandHeld: false) == nil)
    }
}

private extension Optional {
    var isNil: Bool { self == nil }
}
