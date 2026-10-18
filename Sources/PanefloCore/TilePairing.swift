import Foundation

/// Snap assist for one switching session: after Command–Option–Left tiles the selected window to the left half, the
/// next Command–Option–Right on another window tiles it to the right half of the same display and pairs the two
/// (and the mirror case). Pure state; the caller reports placement requests and their outcomes.
///
/// The caller resets it on Escape, at session end and at the start of each presentation.
public struct SnapAssistSession: Equatable, Sendable {
    /// The first window of a pair in progress.
    public struct Anchor: Equatable, Sendable {
        public let id: WindowIdentity
        public let zone: LayoutZone
        /// The display index its placement landed on; nil until the placement reports.
        public var display: Int?
        public var placed: Bool
        /// The `requests` count when this placement was requested; matches its report to it.
        public var request: UInt64 = 0
    }

    /// What a placement request should do.
    public struct Request: Equatable, Sendable {
        /// Place on this display (the anchor's), instead of the window's own.
        public var explicitDisplay: Int?
        /// The anchor this placement completes, when it is the second half.
        public var pairsWith: WindowIdentity?
        public init(explicitDisplay: Int? = nil, pairsWith: WindowIdentity? = nil) {
            self.explicitDisplay = explicitDisplay; self.pairsWith = pairsWith
        }
    }

    /// Both halves landed on one display: the caller forms the group.
    public struct Formation: Equatable, Sendable {
        /// The left member.
        public let first: WindowIdentity
        /// The right member.
        public let second: WindowIdentity
        public let display: Int
    }

    public private(set) var anchor: Anchor?
    public private(set) var partner: Anchor?
    /// Counts half-screen requests. Read it right after `willTile` and pass it to `didTile`, so a superseded
    /// placement's late report never touches a newer request for the same window.
    public private(set) var requests: UInt64 = 0

    public init() {}

    /// Snap assist pairs the switcher's half-screen arrangements only.
    public static func complement(of zone: LayoutZone) -> LayoutZone? {
        switch zone {
        case .leftHalf: .rightHalf
        case .rightHalf: .leftHalf
        default: nil
        }
    }

    /// Text for the hint strip while the session waits for the second window; nil otherwise.
    public var pairingHint: String? {
        guard let anchor, partner == nil, let other = Self.complement(of: anchor.zone) else { return nil }
        return other == .rightHalf ? "Pick a window for the right half — ⌘⌥→" : "Pick a window for the left half — ⌘⌥←"
    }

    /// While the second half is still being placed, the window to raise with `target` if the session commits now.
    public func pendingPartner(for target: WindowIdentity) -> WindowIdentity? {
        guard let anchor, let partner else { return nil }
        return target == partner.id ? anchor.id : target == anchor.id ? partner.id : nil
    }

    /// A Command–Option arrangement of `id` into `zone` is about to be requested.
    public mutating func willTile(_ id: WindowIdentity, zone: LayoutZone) -> Request {
        guard Self.complement(of: zone) != nil else {
            // Fill screen (or any other zone) of a window in the pair in progress abandons it.
            if anchor?.id == id || partner?.id == id { reset() }
            return Request()
        }
        requests &+= 1
        if let anchor, anchor.id != id, zone == Self.complement(of: anchor.zone) {
            partner = Anchor(id: id, zone: zone, display: nil, placed: false, request: requests)
            return Request(explicitDisplay: anchor.display, pairsWith: anchor.id)
        }
        // A first half, the same window again, or the same half for another window: start over from this one.
        anchor = Anchor(id: id, zone: zone, display: nil, placed: false, request: requests)
        partner = nil
        return Request()
    }

    /// A placement requested through `willTile` finished on `display`, or failed (`display` nil). `request` is the
    /// `requests` value read after that `willTile`; nil matches by window and zone alone.
    public mutating func didTile(_ id: WindowIdentity, zone: LayoutZone, display: Int?, request: UInt64? = nil) -> Formation? {
        func matches(_ part: Anchor) -> Bool { part.id == id && part.zone == zone && (request == nil || request == part.request) }
        if var current = partner, matches(current) {
            guard let display else { partner = nil; return nil }
            current.display = display; current.placed = true
            partner = current
        } else if var current = anchor, matches(current) {
            guard let display else { reset(); return nil }
            current.display = display; current.placed = true
            anchor = current
        } else {
            return nil
        }
        guard let anchor, let partner, anchor.placed, partner.placed else { return nil }
        reset()
        guard anchor.display == partner.display, let display = anchor.display else { return nil }
        let leftFirst = anchor.zone == .leftHalf
        return Formation(first: leftFirst ? anchor.id : partner.id, second: leftFirst ? partner.id : anchor.id, display: display)
    }

    /// An undo of `id` abandons a pair in progress that includes it.
    public mutating func willRestore(_ id: WindowIdentity?) {
        guard let id else { return }
        if anchor?.id == id || partner?.id == id { reset() }
    }

    public mutating func reset() { anchor = nil; partner = nil }
}

/// One step of opening a window that has a tile partner.
public enum PairActivationStep: Equatable, Sendable {
    /// Bring the partner forward without focusing it.
    case raise(WindowIdentity)
    /// Focus the chosen window (activation included).
    case focus(WindowIdentity)
}

/// Orders opening a pair: the partner is raised first, then the target is focused, so the target ends up frontmost
/// with its partner visible next to it. Focus waits for the raise at most `raiseDeadline`: an unresponsive partner
/// app never delays the window the user chose. Each step is issued once.
public struct PairActivation: Equatable, Sendable {
    public static let raiseDeadline = 0.08

    public let target: WindowIdentity
    public let partner: WindowIdentity?
    public private(set) var focusIssued = false

    public init(target: WindowIdentity, partner: WindowIdentity?) {
        self.target = target
        self.partner = partner == target ? nil : partner
    }

    public mutating func start() -> [PairActivationStep] {
        guard let partner else { return issueFocus() }
        return [.raise(partner)]
    }

    public mutating func raiseFinished() -> [PairActivationStep] { issueFocus() }
    public mutating func raiseDeadlineElapsed() -> [PairActivationStep] { issueFocus() }

    private mutating func issueFocus() -> [PairActivationStep] {
        guard !focusIssued else { return [] }
        focusIssued = true
        return [.focus(target)]
    }

    /// The partner to bring with `target`: its tile pair's other member, else the half still being placed in a
    /// snap-assist session. Nil when the setting is off, unless the user explicitly asked to open the pair.
    public static func partner(for target: WindowIdentity, groups: TileGroupRegistry, pending: WindowIdentity? = nil,
                               raiseTogether: Bool, explicit: Bool = false) -> WindowIdentity? {
        guard raiseTogether || explicit else { return nil }
        return groups.partner(of: target) ?? (pending == target ? nil : pending)
    }
}

/// Carries out pair activation steps.
@MainActor
public protocol PairActivationExecutor: AnyObject {
    /// Raises `id` without focusing it; `completion` runs on the main actor once the raise was attempted.
    func raiseWithoutFocus(_ id: WindowIdentity, completion: @escaping @MainActor () -> Void)
    func focus(_ id: WindowIdentity)
}

/// Drives a `PairActivation` against an executor. `schedule` runs a block after a delay in seconds (the app passes
/// a main-queue timer; tests pass a manual clock).
@MainActor
public enum PairActivator {
    public static func open(_ target: WindowIdentity, partner: WindowIdentity?, executor: PairActivationExecutor,
                            deadline: Double = PairActivation.raiseDeadline,
                            schedule: (Double, @escaping @MainActor () -> Void) -> Void) {
        final class Box { var activation: PairActivation; init(_ a: PairActivation) { activation = a } }
        let box = Box(PairActivation(target: target, partner: partner))
        weak let weakExecutor = executor
        func run(_ steps: [PairActivationStep]) {
            guard let executor = weakExecutor else { return }
            for step in steps {
                switch step {
                case .raise(let id):
                    executor.raiseWithoutFocus(id) { run(box.activation.raiseFinished()) }
                case .focus(let id):
                    executor.focus(id)
                }
            }
        }
        let first = box.activation.start()
        if !box.activation.focusIssued { schedule(deadline) { run(box.activation.raiseDeadlineElapsed()) } }
        run(first)
    }
}
