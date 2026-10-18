import Foundation

/// How the two members of a tile pair share their display.
public enum TileGroupLayout: String, Sendable {
    /// Left half and right half.
    case leftRight
    /// Top half and bottom half.
    case topBottom
}

/// The half of a display a pair member occupies.
public enum TileGroupRole: String, CaseIterable, Sendable {
    case left, right, top, bottom

    public var layout: TileGroupLayout { self == .left || self == .right ? .leftRight : .topBottom }

    /// The half that completes this one.
    public var complement: TileGroupRole {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// The left or top member is listed first in a group.
    public var isFirst: Bool { self == .left || self == .top }

    public var zone: LayoutZone {
        switch self {
        case .left: .leftHalf
        case .right: .rightHalf
        case .top: .topHalf
        case .bottom: .bottomHalf
        }
    }

    public init?(zone: LayoutZone) {
        switch zone {
        case .leftHalf: self = .left
        case .rightHalf: self = .right
        case .topHalf: self = .top
        case .bottomHalf: self = .bottom
        default: return nil
        }
    }
}

/// Two windows that fill complementary halves of one display. Opening either brings both forward.
public struct TileGroup: Equatable, Sendable {
    public let id: UInt64
    public let layout: TileGroupLayout
    /// The left (or top) member.
    public let first: WindowIdentity
    /// The right (or bottom) member.
    public let second: WindowIdentity
    /// The display's full frame (Accessibility coordinates) when the pair formed. It identifies the display:
    /// a pair whose display is gone or changed shape dissolves.
    public let display: WindowRect

    public init(id: UInt64, layout: TileGroupLayout, first: WindowIdentity, second: WindowIdentity, display: WindowRect) {
        self.id = id; self.layout = layout; self.first = first; self.second = second; self.display = display
    }

    public var members: [WindowIdentity] { [first, second] }
    public func contains(_ id: WindowIdentity) -> Bool { id == first || id == second }

    public func partner(of id: WindowIdentity) -> WindowIdentity? {
        id == first ? second : id == second ? first : nil
    }

    public func role(of id: WindowIdentity) -> TileGroupRole? {
        switch (layout, id) {
        case (.leftRight, first): .left
        case (.leftRight, second): .right
        case (.topBottom, first): .top
        case (.topBottom, second): .bottom
        default: nil
        }
    }
}

/// Tile pairs for the current process lifetime (nothing persists across relaunch).
///
/// A pair forms when Paneflo arranges two windows into complementary halves of one display, or when the window
/// frames show two windows already there (another tool, a manual drag). Each window belongs to at most one pair.
/// New pairs are detected from halves only; an existing pair stays while its members still complement each other
/// (`complement(_:_:on:)`: one seam, each spanning the display's other axis), so a window with its own minimum or
/// maximum size paired with a partner that takes the remainder, or both halves resized together along their shared
/// edge, stay paired. A pair dissolves when a member closes, minimizes, moves to another display, or the seam
/// breaks by more than the tolerance (a drag or resize of one member), and when the user ungroups it. An ungrouped
/// pair is not detected again until one of its windows leaves its half or Paneflo arranges the pair again.
///
/// Pure value state: the caller supplies frames, displays and the time, and calls `reconcile` on every
/// registry snapshot. Nothing here reads the window server or Accessibility.
public struct TileGroupRegistry: Sendable {
    /// Edge tolerance in points. Covers Paneflo's 8 pt gap, other tools' margins and apps that round their
    /// size to a character grid, while a third or a quarter is far outside it.
    public static let defaultTolerance = 24.0
    /// How long a frame reported by a Paneflo placement is trusted over an older registry record.
    public static let placementGrace = 1.5

    public let tolerance: Double
    public internal(set) var groups: [TileGroup] = []
    private var nextID: UInt64 = 0
    private var suppressed: Set<PairKey> = []
    /// Module-internal so the tile resolver (TileReplacement.swift) shares the same effective frames.
    var placed: [WindowIdentity: PlacedFrame] = [:]

    private struct PairKey: Hashable, Sendable {
        let a: WindowIdentity, b: WindowIdentity
        init(_ x: WindowIdentity, _ y: WindowIdentity) {
            // Order-independent: a stable ordering of the two identities.
            if (x.process.pid, x.process.launchToken, x.number, x.incarnation)
                < (y.process.pid, y.process.launchToken, y.number, y.incarnation) { a = x; b = y } else { a = y; b = x }
        }
    }

    struct PlacedFrame: Sendable {
        let frame: WindowRect
        let at: Double
    }

    /// Where one window sits: its display and the half it fills, if any.
    struct Placement: Equatable {
        let display: Int
        let role: TileGroupRole?
    }

    public init(tolerance: Double = TileGroupRegistry.defaultTolerance) {
        self.tolerance = max(0, tolerance)
    }

    // MARK: Queries

    public func group(containing id: WindowIdentity) -> TileGroup? { groups.first { $0.contains(id) } }
    public func partner(of id: WindowIdentity) -> WindowIdentity? { group(containing: id)?.partner(of: id) }

    /// The half of `display` that `frame` fills within `tolerance`, or nil.
    public static func role(of frame: WindowRect, on display: DisplayArea,
                            tolerance: Double = defaultTolerance) -> TileGroupRole? {
        let v = display.visibleFrame
        guard frame.isValid, v.isValid else { return nil }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }
        let fullHeight = near(frame.y, v.y) && near(frame.maxY, v.maxY)
        let fullWidth = near(frame.x, v.x) && near(frame.maxX, v.maxX)
        if fullHeight {
            if near(frame.x, v.x) && near(frame.maxX, v.centerX) { return .left }
            if near(frame.x, v.centerX) && near(frame.maxX, v.maxX) { return .right }
        }
        if fullWidth {
            if near(frame.y, v.y) && near(frame.maxY, v.centerY) { return .top }
            if near(frame.y, v.centerY) && near(frame.maxY, v.maxY) { return .bottom }
        }
        return nil
    }

    /// The smallest share of the display's split axis a pair member may cover.
    public static let minimumShare = 0.15

    /// How two frames on one display complement each other, or nil: both span the visible frame's cross axis
    /// (within `tolerance`), one starts at the leading edge, the other ends at the trailing edge, and they meet at
    /// one seam (a gap or overlap of at most `tolerance`), each covering at least `minimumShare` of the split axis.
    /// Halves qualify; so does a size-limited window next to a partner holding the rest of the display.
    /// Returns the layout and whether `a` is the first (left or top) member.
    public static func complement(_ a: WindowRect, _ b: WindowRect, on display: DisplayArea,
                                  tolerance: Double = defaultTolerance) -> (layout: TileGroupLayout, aIsFirst: Bool)? {
        let v = display.visibleFrame
        guard a.isValid, b.isValid, v.isValid else { return nil }
        func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= tolerance }
        func check(_ first: WindowRect, _ second: WindowRect, horizontal: Bool) -> Bool {
            if horizontal {
                let spans = [first, second].allSatisfy { near($0.y, v.y) && near($0.maxY, v.maxY) }
                return spans && near(first.x, v.x) && near(second.maxX, v.maxX) && near(first.maxX, second.x)
                    && first.width >= v.width * minimumShare && second.width >= v.width * minimumShare
            }
            let spans = [first, second].allSatisfy { near($0.x, v.x) && near($0.maxX, v.maxX) }
            return spans && near(first.y, v.y) && near(second.maxY, v.maxY) && near(first.maxY, second.y)
                && first.height >= v.height * minimumShare && second.height >= v.height * minimumShare
        }
        if check(a, b, horizontal: true) { return (.leftRight, true) }
        if check(b, a, horizontal: true) { return (.leftRight, false) }
        if check(a, b, horizontal: false) { return (.topBottom, true) }
        if check(b, a, horizontal: false) { return (.topBottom, false) }
        return nil
    }

    // MARK: Changes

    /// Paneflo placed `id` at `frame` (the placement's own readback). Until the registry record catches up,
    /// or `placementGrace` passes, this frame stands in for the record's.
    public mutating func notePlacement(_ id: WindowIdentity, frame: WindowRect, now: Double) {
        guard frame.isValid else { return }
        placed[id] = PlacedFrame(frame: frame, at: now)
    }

    /// Explicitly pairs two windows Paneflo just arranged. Succeeds only when they complement each other on one
    /// display right now (`complement(_:_:on:)`); either window leaves any previous pair, and a previous "ungroup" no
    /// longer applies. A window with a fresh placement frame counts as on screen even if its record still says
    /// minimized (the placement restored it).
    @discardableResult
    public mutating func form(_ a: WindowIdentity, _ b: WindowIdentity, records: [WindowRecord],
                              displays: [DisplayArea], now: Double) -> TileGroup? {
        let frames = effectiveFrames(records: records, now: now)
        let minimized = Set(records.filter { $0.isMinimized && placed[$0.id] == nil }.map(\.id))
        guard a != b, !minimized.contains(a), !minimized.contains(b), let fa = frames[a], let fb = frames[b],
              let da = DisplayPlacement.displayIndex(for: fa, in: displays),
              let db = DisplayPlacement.displayIndex(for: fb, in: displays), da == db,
              let fit = Self.complement(fa, fb, on: displays[da], tolerance: tolerance) else { return nil }
        groups.removeAll { $0.contains(a) || $0.contains(b) }
        suppressed.remove(PairKey(a, b))
        let roleA: TileGroupRole = fit.layout == .leftRight ? (fit.aIsFirst ? .left : .right) : (fit.aIsFirst ? .top : .bottom)
        return add(a, roleA, b, display: displays[da].frame)
    }

    /// Removes the pair containing `id` because Paneflo moved it out (Fill, another display, another pair). Unlike
    /// `ungroup`, detection may pair the two again later. Returns the removed pair.
    @discardableResult
    public mutating func leave(_ id: WindowIdentity) -> TileGroup? {
        guard let group = self.group(containing: id) else { return nil }
        groups.removeAll { $0.id == group.id }
        return group
    }

    /// Re-forms pairs after an undo put their members back. Each pair forms only if both members are alive and
    /// complement each other again; returns the pairs formed.
    @discardableResult
    public mutating func restore(_ pairs: [TilePairMembers], records: [WindowRecord], displays: [DisplayArea],
                                 now: Double) -> [TileGroup] {
        pairs.compactMap { form($0.first, $0.second, records: records, displays: displays, now: now) }
    }

    /// Dissolves the pair containing `id` at the user's request. Returns false when `id` had no pair.
    @discardableResult
    public mutating func ungroup(_ id: WindowIdentity) -> Bool {
        guard let group = self.group(containing: id) else { return false }
        groups.removeAll { $0.id == group.id }
        suppressed.insert(PairKey(group.first, group.second))
        return true
    }

    /// Re-validates every pair against the latest records and detects new pairs from frames. `records` should be
    /// in most-recently-used order: when several windows fill the same half, the most recent one pairs.
    /// Returns true when the set of pairs changed.
    @discardableResult
    public mutating func reconcile(records: [WindowRecord], displays: [DisplayArea], now: Double) -> Bool {
        let before = groups
        let frames = effectiveFrames(records: records, now: now)
        var placements: [WindowIdentity: Placement] = [:]
        for record in records where !record.isMinimized || placed[record.id] != nil {
            if let p = placement(record.id, frames: frames, displays: displays) { placements[record.id] = p }
        }
        // 1. Existing pairs: both members alive, unminimized, on the same unchanged display, still complementing
        //    each other in the same order and layout.
        groups.removeAll { group in
            guard let pf = placements[group.first], let ps = placements[group.second], pf.display == ps.display,
                  displays[pf.display].frame.isClose(to: group.display, tolerance: 1),
                  let ff = frames[group.first], let fs = frames[group.second],
                  let fit = Self.complement(ff, fs, on: displays[pf.display], tolerance: tolerance),
                  fit.aIsFirst, fit.layout == group.layout else { return true }
            return false
        }
        // 2. An ungroup lasts while both windows stay in complementary halves of one display.
        suppressed = suppressed.filter { key in
            guard let pa = placements[key.a], let pb = placements[key.b], pa.display == pb.display,
                  let ra = pa.role, ra.complement == pb.role else { return false }
            return true
        }
        // 3. New pairs from frames, most recent windows first.
        let ordered = records.map(\.id).filter { placements[$0]?.role != nil }
        for id in ordered where group(containing: id) == nil {
            guard let p = placements[id], let role = p.role, role.isFirst else { continue }
            let partner = ordered.first { other in
                other != id && group(containing: other) == nil && placements[other] == Placement(display: p.display, role: role.complement)
                    && !suppressed.contains(PairKey(id, other))
            }
            if let partner { add(id, role, partner, display: displays[p.display].frame) }
        }
        return groups != before
    }

    // MARK: Internals

    @discardableResult
    mutating func add(_ a: WindowIdentity, _ roleA: TileGroupRole, _ b: WindowIdentity, display: WindowRect) -> TileGroup {
        nextID &+= 1
        let group = TileGroup(id: nextID, layout: roleA.layout, first: roleA.isFirst ? a : b, second: roleA.isFirst ? b : a,
                              display: display)
        groups.append(group)
        return group
    }

    /// Forgets an earlier ungroup of `a` and `b` (Paneflo arranged them as a pair again).
    mutating func unsuppress(_ a: WindowIdentity, _ b: WindowIdentity) { suppressed.remove(PairKey(a, b)) }

    /// `effectiveFrames` without expiring anything: for read-only planning.
    func peekFrames(records: [WindowRecord], now: Double) -> [WindowIdentity: WindowRect] {
        var frames: [WindowIdentity: WindowRect] = [:]
        for record in records {
            if let override = placed[record.id], now - override.at <= Self.placementGrace, now >= override.at {
                frames[record.id] = override.frame
            } else {
                frames[record.id] = record.frame
            }
        }
        return frames
    }

    /// Record frames, with fresh placement frames standing in until the record matches them or they expire.
    mutating func effectiveFrames(records: [WindowRecord], now: Double) -> [WindowIdentity: WindowRect] {
        var frames: [WindowIdentity: WindowRect] = [:]
        let alive = Set(records.map(\.id))
        placed = placed.filter { alive.contains($0.key) && now - $0.value.at <= Self.placementGrace && now >= $0.value.at }
        for record in records {
            if let override = placed[record.id] {
                if record.frame.isClose(to: override.frame, tolerance: 2) { placed.removeValue(forKey: record.id) }
                frames[record.id] = override.frame
            } else {
                frames[record.id] = record.frame
            }
        }
        return frames
    }

    func placement(_ id: WindowIdentity, frames: [WindowIdentity: WindowRect], displays: [DisplayArea]) -> Placement? {
        guard let frame = frames[id], !displays.isEmpty,
              let index = DisplayPlacement.displayIndex(for: frame, in: displays) else { return nil }
        return Placement(display: index, role: Self.role(of: frame, on: displays[index], tolerance: tolerance))
    }
}
