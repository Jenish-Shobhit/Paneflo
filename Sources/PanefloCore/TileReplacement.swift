import Foundation

/// The last floating frame Paneflo saw for each window (this process only): where a window displaced from a tile
/// pair goes back to. A frame counts as floating when it is neither a half nor filling its display.
public struct TileHomeFrames: Sendable {
    private var frames: [WindowIdentity: WindowRect] = [:]

    public init() {}

    public func frame(for id: WindowIdentity) -> WindowRect? { frames[id] }

    /// `before` is a window's frame read just before a Paneflo placement. A floating frame becomes the window's home;
    /// a tiled one keeps the earlier home.
    public mutating func note(_ id: WindowIdentity, before: WindowRect, displays: [DisplayArea]) {
        if Self.isFloating(before, displays: displays) { frames[id] = before }
    }

    /// Registry snapshot: every visible floating window's frame is its latest home (covers windows tiled by a drag
    /// or another tool). Windows that are gone are forgotten.
    public mutating func observe(_ records: [WindowRecord], displays: [DisplayArea]) {
        let alive = Set(records.map(\.id))
        frames = frames.filter { alive.contains($0.key) }
        for record in records where !record.isMinimized && Self.isFloating(record.frame, displays: displays) {
            frames[record.id] = record.frame
        }
    }

    /// Where a displaced window goes: its home while at least 95 % of it is on the current displays; nil keeps the
    /// window where it is.
    public func restoreTarget(for id: WindowIdentity, displays: [DisplayArea]) -> WindowRect? {
        guard let home = frames[id], home.isValid, !displays.isEmpty else { return nil }
        let onScreen = displays.reduce(0.0) { $0 + $1.frame.intersectionArea(home) }
        return onScreen >= home.width * home.height * 0.95 ? home : nil
    }

    public static func isFloating(_ frame: WindowRect, displays: [DisplayArea],
                                  tolerance: Double = TileGroupRegistry.defaultTolerance) -> Bool {
        guard frame.isValid, let index = DisplayPlacement.displayIndex(for: frame, in: displays) else { return false }
        let display = displays[index]
        if TileGroupRegistry.role(of: frame, on: display, tolerance: tolerance) != nil { return false }
        let v = display.visibleFrame
        let fills = abs(frame.x - v.x) <= tolerance && abs(frame.maxX - v.maxX) <= tolerance
            && abs(frame.y - v.y) <= tolerance && abs(frame.maxY - v.maxY) <= tolerance
        return !fills
    }
}

/// Where a Paneflo tile actually landed: the placement's own readback.
public struct TileLanding: Equatable, Sendable {
    public let window: WindowIdentity
    public let zone: LayoutZone
    /// Display index (in the caller's display order) the placement used.
    public let display: Int
    public let frame: WindowRect
    /// The rectangle Paneflo asked for; a different `frame` means the window limits its own size.
    public let requested: WindowRect?

    public init(window: WindowIdentity, zone: LayoutZone, display: Int, frame: WindowRect, requested: WindowRect? = nil) {
        self.window = window; self.zone = zone; self.display = display; self.frame = frame; self.requested = requested
    }
}

/// A follow-up placement a tile needs to keep its pair complete.
public struct TileMove: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The partner takes the half the window left (a true swap).
        case swap
        /// A member replaced by another window goes back to its last floating frame.
        case restoreDisplaced
        /// The partner of a size-limited window takes the rest of the display.
        case remainder
        /// A size-limited window moves against its outer edge so its partner can take the rest.
        case alignEdge
    }

    public let window: WindowIdentity
    /// The planned frame. It stands in as the window's frame until its placement reports.
    public let frame: WindowRect
    public let display: Int
    /// For `swap`: the half to tile on `display` (the executor plans it exactly and honours size limits); otherwise
    /// `frame` is applied as given.
    public let zone: LayoutZone?
    public let reason: Reason

    public init(window: WindowIdentity, frame: WindowRect, display: Int, zone: LayoutZone? = nil, reason: Reason) {
        self.window = window; self.frame = frame; self.display = display; self.zone = zone; self.reason = reason
    }
}

/// What one tile did to the pairs.
public struct TileResolution: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// No pair involves the window.
        case unpaired
        /// The window was already in this half of its pair.
        case unchanged
        /// Paired with an unpaired window in the other half.
        case formed
        /// Took a pair member's half: paired with that member's partner; the member is displaced.
        case replaced
        /// Took its partner's half; the partner took the window's old half.
        case swapped
        /// Left its pair (Fill, another display, another layout); the partner keeps its frame.
        case left
    }

    public var kind: Kind = .unpaired
    /// The pair now holding the window, if any.
    public var group: TileGroup?
    /// The pair member whose half the window took.
    public var displaced: WindowIdentity?
    /// Placements to issue now, in order.
    public var moves: [TileMove] = []
    /// Pairs this tile ended; an undo of the tile forms them again.
    public var dissolved: [TilePairMembers] = []
}

extension TileGroup {
    public var pairMembers: TilePairMembers { TilePairMembers(first: first, second: second) }
}

extension TileGroupRegistry {
    /// Request-time half of a swap: `id` is about to tile into its partner's half on the pair's display. Returns the
    /// partner's move into the half `id` leaves, so both run at once instead of one after the other (no moment with
    /// an empty half). Nil when the request is not a swap (the window would land elsewhere, or has no pair).
    public func plannedSwap(for id: WindowIdentity, zone: LayoutZone, records: [WindowRecord], displays: [DisplayArea],
                            explicitDisplay: Int? = nil, gap: Double = 8, now: Double) -> TileMove? {
        guard let group = group(containing: id), let role = TileGroupRole(zone: zone), let old = group.role(of: id),
              role == old.complement, let partner = group.partner(of: id),
              let pairDisplay = displays.firstIndex(where: { $0.frame.isClose(to: group.display, tolerance: 1) }) else { return nil }
        let frames = peekFrames(records: records, now: now)
        guard let frame = frames[id] else { return nil }
        let landing = explicitDisplay ?? DisplayPlacement.planTile(zone: zone, window: frame, displays: displays, gap: gap)?.displayIndex
        guard landing == pairDisplay, let rect = Self.half(old, on: displays[pairDisplay], gap: gap) else { return nil }
        return TileMove(window: partner, frame: rect, display: pairDisplay, zone: old.zone, reason: .swap)
    }

    /// Resolves a finished tile against where it landed and updates the pairs at once (decision matrix rows 1–26):
    /// the window leaves its old pair, swaps with its partner, replaces the member holding the target half (that
    /// member's partner becomes its partner; the member goes back to its home frame when one is known and on screen,
    /// otherwise it keeps its frame), or pairs with an unpaired window already in the other half. A size-limited
    /// window keeps its accepted size and its partner takes the rest when that stays at least `minimumShare`.
    ///
    /// `busy` windows have a newer placement in flight: no follow-up moves them. `preferredPartner` (the snap-assist
    /// anchor) wins over other unpaired windows in the other half. Returned moves carry planned frames, already
    /// standing in as those windows' frames.
    @discardableResult
    public mutating func resolve(_ landing: TileLanding, records: [WindowRecord], displays: [DisplayArea], now: Double,
                                 busy: Set<WindowIdentity> = [], homes: TileHomeFrames = TileHomeFrames(),
                                 preferredPartner: WindowIdentity? = nil, gap: Double = 8) -> TileResolution {
        let w = landing.window
        var result = TileResolution()
        notePlacement(w, frame: landing.frame, now: now)
        var frames = effectiveFrames(records: records, now: now)
        let minimized = Set(records.filter { $0.isMinimized && placed[$0.id] == nil }.map(\.id))
        guard displays.indices.contains(landing.display), let role = TileGroupRole(zone: landing.zone) else {
            if let group = leave(w) { result.kind = .left; result.dissolved = [group.pairMembers] }
            return result
        }
        let d = landing.display, display = displays[d]
        func onThisDisplay(_ group: TileGroup) -> Bool { display.frame.isClose(to: group.display, tolerance: 1) }

        // 1. The window's own pair: unchanged, a swap, or left behind.
        if let group = group(containing: w), let old = group.role(of: w), let partner = group.partner(of: w) {
            if onThisDisplay(group) && old == role {
                result.kind = .unchanged; result.group = group
                return result
            }
            groups.removeAll { $0.id == group.id }
            result.dissolved.append(group.pairMembers)
            result.kind = .left
            if onThisDisplay(group), old == role.complement, !minimized.contains(partner) {
                if let fp = frames[partner], Self.role(of: fp, on: display, tolerance: tolerance) == old {
                    // Already there: the request-time swap move (or its landing) stands in.
                } else if !busy.contains(partner), let rect = Self.half(old, on: display, gap: gap) {
                    result.moves.append(TileMove(window: partner, frame: rect, display: d, zone: old.zone, reason: .swap))
                    notePlacement(partner, frame: rect, now: now); frames[partner] = rect
                }
                if let formed = pairUp(w, role, partner, display: d, displays: displays, frames: &frames, landing: landing,
                                       busy: busy, gap: gap, now: now, moves: &result.moves) {
                    result.kind = .swapped; result.group = formed
                }
                return result
            }
        }

        // 2. A pair already holding the target half on this display: replace that member.
        if let group = groups.first(where: { onThisDisplay($0) && !$0.contains(w)
                                              && ($0.role(of: $0.first) == role || $0.role(of: $0.second) == role) }),
           let member = group.members.first(where: { group.role(of: $0) == role }), let keeper = group.partner(of: member) {
            groups.removeAll { $0.id == group.id }
            result.dissolved.append(group.pairMembers)
            result.displaced = member
            result.kind = .replaced
            if !busy.contains(member), !minimized.contains(member), frames[member] != nil,
               let home = homes.restoreTarget(for: member, displays: displays),
               let homeDisplay = DisplayPlacement.displayIndex(for: home, in: displays) {
                result.moves.append(TileMove(window: member, frame: home, display: homeDisplay, reason: .restoreDisplaced))
                notePlacement(member, frame: home, now: now); frames[member] = home
            }
            result.group = pairUp(w, role, keeper, display: d, displays: displays, frames: &frames, landing: landing,
                                  busy: busy, gap: gap, now: now, moves: &result.moves)
            return result
        }

        // 3. An unpaired window already in the other half.
        let candidates = records.map(\.id).filter { id in
            guard id != w, !minimized.contains(id), group(containing: id) == nil, let frame = frames[id],
                  DisplayPlacement.displayIndex(for: frame, in: displays) == d else { return false }
            return Self.role(of: frame, on: display, tolerance: tolerance) == role.complement
        }
        if let partner = preferredPartner.flatMap({ candidates.contains($0) ? $0 : nil }) ?? candidates.first,
           let formed = pairUp(w, role, partner, display: d, displays: displays, frames: &frames, landing: landing,
                               busy: busy, gap: gap, now: now, moves: &result.moves) {
            result.kind = .formed; result.group = formed
        }
        return result
    }

    // MARK: Pairing helpers

    /// Pairs `w` (meant for `role`) with `k` on display `d`. Frames that already complement each other pair at once;
    /// a size-limited member keeps its accepted size and the other member gets the rest of the display.
    private mutating func pairUp(_ w: WindowIdentity, _ role: TileGroupRole, _ k: WindowIdentity, display d: Int,
                                 displays: [DisplayArea], frames: inout [WindowIdentity: WindowRect], landing: TileLanding,
                                 busy: Set<WindowIdentity>, gap: Double, now: Double, moves: inout [TileMove]) -> TileGroup? {
        let display = displays[d]
        guard let fw = frames[w], let fk = frames[k] else { return nil }
        if Self.complement(fw, fk, on: display, tolerance: tolerance) == nil {
            let wFits = Self.role(of: fw, on: display, tolerance: tolerance) == role
            let kFits = Self.role(of: fk, on: display, tolerance: tolerance) == role.complement
            // (window, its role, its frame) keeps its size; the other member takes the rest.
            let limited: (WindowIdentity, TileGroupRole, WindowRect, WindowIdentity)
            if !wFits && kFits { limited = (w, role, fw, k) }
            else if wFits && !kFits { limited = (k, role.complement, fk, w) }
            else { return nil }
            let (fixed, fixedRole, fixedFrame, other) = limited
            let anchored = Self.anchored(fixedFrame, role: fixedRole, on: display, gap: gap)
            guard let rest = Self.remainder(beside: anchored, role: fixedRole, on: display, gap: gap),
                  Self.complement(anchored, rest, on: display, tolerance: tolerance) != nil else { return nil }
            let moveFixed = !anchored.isClose(to: fixedFrame, tolerance: 1)
            if (moveFixed && busy.contains(fixed)) || busy.contains(other) { return nil }
            if moveFixed {
                moves.append(TileMove(window: fixed, frame: anchored, display: d, reason: .alignEdge))
                notePlacement(fixed, frame: anchored, now: now); frames[fixed] = anchored
            }
            moves.append(TileMove(window: other, frame: rest, display: d, reason: .remainder))
            notePlacement(other, frame: rest, now: now); frames[other] = rest
        }
        guard let fit = Self.complement(frames[w]!, frames[k]!, on: display, tolerance: tolerance) else { return nil }
        groups.removeAll { $0.contains(w) || $0.contains(k) }
        unsuppress(w, k)
        let roleW: TileGroupRole = fit.layout == .leftRight ? (fit.aIsFirst ? .left : .right) : (fit.aIsFirst ? .top : .bottom)
        return add(w, roleW, k, display: display.frame)
    }

    /// Paneflo's half rectangle for `role` on `display`.
    static func half(_ role: TileGroupRole, on display: DisplayArea, gap: Double) -> WindowRect? {
        LayoutEngine.plan(zone: role.zone, in: display.visibleFrame, gap: gap, backingScale: display.backingScale).rect
    }

    /// `frame` moved along the split axis so its outer edge sits where `role`'s half has it.
    static func anchored(_ frame: WindowRect, role: TileGroupRole, on display: DisplayArea, gap: Double) -> WindowRect {
        guard let half = half(role, on: display, gap: gap) else { return frame }
        var result = frame
        switch role {
        case .left: result.x = half.x
        case .right: result.x = half.maxX - frame.width
        case .top: result.y = half.y
        case .bottom: result.y = half.maxY - frame.height
        }
        return result
    }

    /// The rest of the display beside `frame` (which holds `role`), keeping Paneflo's gap; nil below `minimumShare`.
    static func remainder(beside frame: WindowRect, role: TileGroupRole, on display: DisplayArea, gap: Double) -> WindowRect? {
        guard let other = half(role.complement, on: display, gap: gap) else { return nil }
        let scale = max(1, display.backingScale)
        func aligned(_ value: Double) -> Double { (value * scale).rounded() / scale }
        let v = display.visibleFrame
        var rest = other
        switch role {
        case .left: rest.x = aligned(frame.maxX + gap); rest.width = other.maxX - rest.x
        case .right: rest.width = aligned(frame.x - gap) - other.x
        case .top: rest.y = aligned(frame.maxY + gap); rest.height = other.maxY - rest.y
        case .bottom: rest.height = aligned(frame.y - gap) - other.y
        }
        let share = role.layout == .leftRight ? rest.width / v.width : rest.height / v.height
        return rest.isValid && share >= minimumShare ? rest : nil
    }
}
