import Foundation
import Testing
@testable import PanefloCore

/// ST-04: random window churn across WindowRegistry, SwitcherSession, OverviewSlotStore,
/// TileGroupRegistry and DesktopSession. Fixed seeds; failures print the seed and step.
struct StressWindowChurnTests {
    private static let displays: [DisplayArea] = [
        DisplayArea(frame: WindowRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: WindowRect(x: 0, y: 25, width: 1920, height: 1055), backingScale: 2),
        DisplayArea(frame: WindowRect(x: 1920, y: 0, width: 1440, height: 900),
                    visibleFrame: WindowRect(x: 1920, y: 25, width: 1440, height: 875), backingScale: 1),
    ]

    private static func randomFrame(_ rng: inout FuzzRandom) -> WindowRect {
        let d = displays[rng.int(0...1)].visibleFrame
        switch rng.int(0...7) {
        case 0: return WindowRect(x: d.x, y: d.y, width: d.width / 2, height: d.height)
        case 1: return WindowRect(x: d.centerX, y: d.y, width: d.width / 2, height: d.height)
        case 2: return WindowRect(x: d.x, y: d.y, width: d.width, height: d.height / 2)
        case 3: return WindowRect(x: d.x, y: d.centerY, width: d.width, height: d.height / 2)
        case 4: return d
        default:
            return WindowRect(x: d.x + rng.double(0...800), y: d.y + rng.double(0...400),
                              width: rng.double(100...900), height: rng.double(100...600))
        }
    }

    private struct World {
        var live: [WindowIdentity: WindowRecord] = [:]
        var launch: [Int32: UInt64] = [:]
        var dead: Set<Int32> = []
        var lastIncarnation: [String: UInt64] = [:]
        var graveyard: [WindowIdentity] = []
        func process(_ pid: Int32) -> ProcessIdentity { .init(pid: pid, launchToken: launch[pid] ?? 1) }
    }

    @Test func registrySessionSlotsPairsAndDesktopSurviveChurn() {
        for seed in UInt64(0)..<120 {
            var rng = FuzzRandom(seed: seed)
            var world = World()
            for pid in Int32(100)...Int32(104) { world.launch[pid] = 1 }
            var registry = WindowRegistry()
            var slots = OverviewSlotStore()
            var tiles = TileGroupRegistry()
            var revision: UInt64 = 0, sequence: UInt64 = 0
            var now = 0.0
            var session: SwitcherSession?
            var frozenOrder: [SwitchTarget] = []
            var removedFromSession: Set<WindowIdentity> = []

            func openWindow(_ pid: Int32) {
                guard !world.dead.contains(pid) else { return }
                let proc = world.process(pid)
                let free = (1...6).map(UInt32.init).filter { n in !world.live.keys.contains { $0.process == proc && $0.number == n } }
                guard let number = free.randomElement(using: &rng) else { return }
                let key = "\(pid)-\(proc.launchToken)-\(number)"
                let inc = (world.lastIncarnation[key] ?? 0) + 1
                world.lastIncarnation[key] = inc
                let id = WindowIdentity(process: proc, number: number, incarnation: inc)
                let record = WindowRecord(id: id, appIdentifier: "com.test.\(pid)", appName: "App\(pid)",
                                          title: rng.chance(0.3) ? "Same" : "Doc \(rng.int(0...3))",
                                          frame: Self.randomFrame(&rng), isMinimized: rng.chance(0.1))
                revision += 1
                let fresh = registry.upsert(record, revision: revision); #expect(fresh, "seed \(seed): fresh window rejected")
                world.live[id] = record
            }

            for step in 0..<300 {
                let ctx: Comment = "seed \(seed) step \(step)"
                now += rng.double(0...2)
                var closedNow: [WindowIdentity] = []
                switch rng.int(0...99) {
                case 0..<22:
                    openWindow(Int32(rng.int(100...104)))
                case 22..<36:
                    guard let id = world.live.keys.sorted(by: Self.order).randomElement(using: &rng) else { break }
                    revision += 1
                    registry.remove(id, revision: revision)
                    world.live[id] = nil; world.graveyard.append(id); closedNow.append(id)
                case 36..<50: // move or minimize
                    guard let id = world.live.keys.sorted(by: Self.order).randomElement(using: &rng), var rec = world.live[id] else { break }
                    if rng.chance(0.3) { rec.isMinimized.toggle() } else { rec.frame = Self.randomFrame(&rng) }
                    revision += 1
                    let ok2 = registry.upsert(rec, revision: revision); #expect(ok2, "live update rejected; \(ctx)")
                    world.live[id] = rec
                case 50..<62: // focus
                    guard let id = world.live.keys.sorted(by: Self.order).randomElement(using: &rng) else { break }
                    sequence += 1
                    if rng.chance(0.5) { _ = registry.requestFocus(id, sequence: sequence); if rng.chance(0.7) { registry.finishFocusRequest(sequence: sequence) } }
                    else { _ = registry.observeFocus(id, sequence: sequence) }
                case 62..<68: // app quit
                    let pid = Int32(rng.int(100...104))
                    guard !world.dead.contains(pid) else { break }
                    registry.processEnded(world.process(pid))
                    for id in world.live.keys where id.process.pid == pid { world.live[id] = nil; world.graveyard.append(id); closedNow.append(id) }
                    world.dead.insert(pid)
                case 68..<73: // relaunch with a new launch token (PID reuse)
                    guard let pid = world.dead.sorted().randomElement(using: &rng) else { break }
                    world.launch[pid, default: 1] += 1
                    world.dead.remove(pid)
                    openWindow(pid)
                case 73..<82: // stale / zombie events must never resurrect anything
                    guard let id = world.graveyard.suffix(40).randomElement(using: &rng) else { break }
                    let before = registry.snapshot
                    revision += 1
                    let zombie = WindowRecord(id: id, appIdentifier: "com.test.\(id.process.pid)", appName: "Zombie",
                                              title: "Zombie", frame: Self.randomFrame(&rng))
                    let revived = registry.upsert(zombie, revision: revision); #expect(!revived, "closed window resurrected; \(ctx)")
                    #expect(registry.snapshot == before, "stale event changed the registry; \(ctx)")
                    if let live = world.live.values.first(where: { _ in true }) {
                        let staleOK = registry.upsert(live, revision: 0); #expect(!staleOK, "stale revision accepted; \(ctx)")
                    }
                case 82..<87:
                    registry.updateStacking(frontToBack: (world.live.keys.sorted(by: Self.order) + world.graveyard.suffix(3)).shuffled(using: &rng))
                case 87..<93: // open a switcher session from a prepared snapshot
                    let direction: CycleDirection = rng.chance(0.5) ? .forward : .backward
                    let mode = rng.pick([DesktopLoopMode.hidden, .trailing, .current])
                    let snap = registry.snapshot
                    let opened = SwitcherSession(snapshot: snap, direction: direction, desktop: mode)
                    #expect(Set(opened.orderedIDs) == Set(world.live.keys), "session misses live windows; \(ctx)")
                    #expect(opened.orderedTargets.count == Set(opened.orderedTargets).count, "duplicate target; \(ctx)")
                    if mode == .current, direction == .forward, let first = opened.orderedTargets.first {
                        #expect(opened.selectedTarget == first, "current-desktop forward must start at index 0; \(ctx)")
                    }
                    if mode == .current, opened.orderedTargets.count > 1 { #expect(opened.orderedTargets[1] == .desktop, ctx) }
                    session = opened
                    frozenOrder = opened.orderedTargets
                    removedFromSession = []
                case 93..<97:
                    guard var s = session else { break }
                    switch rng.int(0...3) {
                    case 0: s.advance(.forward)
                    case 1: s.advance(.backward)
                    case 2: s.setSearchQuery(rng.pick(["", "App10", "same", "doc 1", "desktop", "zzz"]))
                    default: if let t = s.filteredTargets.randomElement(using: &rng) { let ok = s.select(t); #expect(ok, ctx) }
                    }
                    session = s
                default:
                    if var s = session {
                        let committed = s.commitTarget()
                        let again = s.commitTarget(); let again2 = s.commit(); #expect(again == nil && again2 == nil, "double commit; \(ctx)")
                        session = nil
                    }
                }

                // The app removes closed windows from an open session; nothing else may reorder it.
                for id in closedNow { session?.remove(id); removedFromSession.insert(id) }

                // --- Invariants ---
                let snap = registry.snapshot
                let ids = snap.records.map(\.id)
                #expect(ids.count == Set(ids).count, "duplicate identity in registry; \(ctx)")
                #expect(Set(ids) == Set(world.live.keys), "registry drifted from world; \(ctx)")
                #expect(Set(snap.mostRecent).isSubset(of: Set(ids)) && snap.mostRecent.count == Set(snap.mostRecent).count, "MRU invalid; \(ctx)")
                let ordered = snap.orderedRecords.map(\.id)
                #expect(ordered.count == ids.count && Set(ordered) == Set(ids), "orderedRecords lost windows; \(ctx)")

                if let s = session {
                    let expected = frozenOrder.filter { target in target.windowID.map { !removedFromSession.contains($0) } ?? true }
                    #expect(s.orderedTargets == expected, "MRU order changed mid-session; \(ctx)")
                    if let selected = s.selectedTarget { #expect(s.filteredTargets.contains(selected), "selection ineligible; \(ctx)") }
                    else { #expect(s.filteredTargets.isEmpty, "selection nil with eligible targets; \(ctx)") }
                }

                let previousSlotIDs = slots.slots.map(\.id)
                slots.reconcile(snap.records)
                let bindings = slots.slots.compactMap(\.binding)
                #expect(bindings.count == Set(bindings).count, "window bound to two slots; \(ctx)")
                #expect(Set(bindings).isSubset(of: Set(ids)), "slot references closed window; \(ctx)")
                #expect(Set(bindings) == Set(ids), "live window without a slot; \(ctx)")
                #expect(Array(slots.slots.map(\.id).prefix(previousSlotIDs.count)) == previousSlotIDs, "slots reordered by reconcile; \(ctx)")

                let mruRecords = snap.orderedRecords
                tiles.reconcile(records: mruRecords, displays: Self.displays, now: now)
                if rng.chance(0.05), let g = tiles.groups.randomElement(using: &rng) { tiles.ungroup(g.first) }
                if rng.chance(0.05), mruRecords.count >= 2 {
                    _ = tiles.form(mruRecords[0].id, mruRecords[1].id, records: mruRecords, displays: Self.displays, now: now)
                }
                var grouped = Set<WindowIdentity>()
                for group in tiles.groups {
                    for member in group.members {
                        #expect(grouped.insert(member).inserted, "window in two pairs; \(ctx)")
                        guard let rec = world.live[member] else { fail("pair member closed/gone; \(ctx)"); continue }
                        #expect(!rec.isMinimized, "minimized pair member; \(ctx)")
                        let di = DisplayPlacement.displayIndex(for: rec.frame, in: Self.displays) ?? 0
                        #expect(TileGroupRegistry.role(of: rec.frame, on: Self.displays[di]) == group.role(of: member), "moved member kept pair; \(ctx)")
                    }
                    #expect(group.first != group.second, ctx)
                }
            }
        }
    }

    private static func order(_ a: WindowIdentity, _ b: WindowIdentity) -> Bool {
        (a.process.pid, a.process.launchToken, a.number, a.incarnation) < (b.process.pid, b.process.launchToken, b.number, b.incarnation)
    }

    @Test func desktopSessionNeverRestoresMoreThanItHid() {
        for seed in UInt64(0)..<400 {
            var rng = FuzzRandom(seed: seed)
            let protected: Set<Int32> = [1, 2]
            let initial = Set((1...12).filter { _ in rng.chance(0.6) }.map(Int32.init))
            let start = Date(timeIntervalSinceReferenceDate: 1000)
            var session = DesktopSession(generation: 1, startedAt: start, hidden: initial, protected: protected)
            var everHidden = initial.subtracting(protected)
            var terminated: Set<Int32> = []
            var clock = 0.0
            #expect(session.hiddenPIDs.isDisjoint(with: protected), "seed \(seed): protected app tracked")
            for step in 0..<200 {
                let ctx: Comment = "seed \(seed) step \(step)"
                clock += rng.double(0...0.4)
                let pid = Int32(rng.int(0...14))
                let before = session.hiddenPIDs
                switch rng.int(0...9) {
                case 0, 1, 2:
                    let signal: DesktopSignal = rng.pick([.didActivate(pid: pid), .didUnhide(pid: pid)])
                    let ended = session.apply(signal, at: start.addingTimeInterval(clock))
                    #expect(ended == !session.isActive, ctx)
                case 3:
                    terminated.insert(pid)
                    let ended = session.apply(.didTerminate(pid: pid), at: start.addingTimeInterval(clock))
                    #expect(ended == !session.isActive && !session.hiddenPIDs.contains(pid), ctx)
                case 4, 5:
                    let restored = session.restore(for: rng.chance(0.2) ? nil : pid)
                    #expect(restored.isSubset(of: before) && restored.isSubset(of: everHidden), "restored an app it did not hide; \(ctx)")
                    #expect(restored.isDisjoint(with: terminated), "restored a terminated app; \(ctx)")
                    #expect(!session.isCurrent, ctx)
                case 6:
                    let all = session.restoreAll()
                    #expect(all == before && all.isSubset(of: everHidden), "restoreAll mismatch; \(ctx)")
                    let second = session.restoreAll(); #expect(second.isEmpty && !session.isActive, "restoreAll not idempotent; \(ctx)")
                case 7:
                    let refused = Set((0..<3).map { _ in Int32(rng.int(0...14)) })
                    session.noteRefused(refused)
                    #expect(session.hiddenPIDs.isDisjoint(with: refused), ctx)
                case 8:
                    let extra = Set((0..<3).map { _ in Int32(rng.int(0...14)) })
                    let merged = session.merging(newlyHidden: extra.subtracting(terminated), generation: session.generation + 1, at: start.addingTimeInterval(clock))
                    #expect(merged.refusedPIDs == session.refusedPIDs && merged.generation > session.generation, ctx)
                    everHidden.formUnion(extra.subtracting(terminated).subtracting(protected))
                    #expect(merged.hiddenPIDs.isSubset(of: everHidden) && merged.hiddenPIDs.isDisjoint(with: protected), "merge leaked; \(ctx)")
                    session = merged
                default: break
                }
                #expect(session.hiddenPIDs.isDisjoint(with: protected), "protected PID hidden; \(ctx)")
                #expect(session.hiddenPIDs.isSubset(of: everHidden), "restore set exceeds hidden set; \(ctx)")
                #expect(session.isActive == (session.isCurrent || !session.hiddenPIDs.isEmpty), ctx)
            }
        }
    }
}
