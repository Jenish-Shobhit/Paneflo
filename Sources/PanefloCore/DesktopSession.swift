import Foundation

/// What the Show Desktop decision logic needs to know about one running app. The app target builds these from
/// `NSRunningApplication`; nothing here touches AppKit.
public struct DesktopApp: Equatable, Sendable {
    public let pid: Int32
    public let bundleIdentifier: String?
    /// `activationPolicy == .regular`
    public let isRegular: Bool
    public let isHidden: Bool
    public let isTerminated: Bool

    public init(pid: Int32, bundleIdentifier: String?, isRegular: Bool, isHidden: Bool = false, isTerminated: Bool = false) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.isRegular = isRegular
        self.isHidden = isHidden
        self.isTerminated = isTerminated
    }
}

public enum DesktopPlan {
    public static let finderBundleIdentifier = "com.apple.finder"

    /// Apps to hide to reveal the desktop: regular, running, not already hidden (those were hidden by the user and are
    /// not ours to restore), and neither Finder nor an excluded process (Paneflo itself). Sorted for determinism.
    public static func appsToHide(running: [DesktopApp], excluding excluded: Set<Int32>) -> [Int32] {
        running
            .filter { $0.isRegular && !$0.isHidden && !$0.isTerminated
                && $0.bundleIdentifier != finderBundleIdentifier && !excluded.contains($0.pid) }
            .map(\.pid)
            .sorted()
    }
}

public enum DesktopSignal: Equatable, Sendable {
    case didActivate(pid: Int32)
    case didUnhide(pid: Int32)
    case didTerminate(pid: Int32)
}

/// What the user picking the Desktop entry should do.
public enum DesktopEntryAction: Equatable, Sendable {
    case show
    case restoreAll

    /// Picking Desktop while the desktop is already the current state brings everything back; otherwise it shows it.
    public static func resolve(for session: DesktopSession?) -> DesktopEntryAction {
        session?.isCurrent == true ? .restoreAll : .show
    }
}

/// The record of one Show Desktop: which apps Paneflo hid, so only those are ever unhidden. Value type; the service
/// owns the single instance and feeds it signals.
///
/// Lifecycle: `isCurrent` is true from the moment the desktop is shown until the user (or a window selection) brings
/// an app forward. The session stays active while it still holds hidden apps, so the Desktop entry stays a normal
/// loop stop and "restore all" still works after one app was brought back. It ends when no app is hidden by it and
/// the desktop is no longer the current state.
public struct DesktopSession: Equatable, Sendable {
    /// Signals this soon after the session starts are our own hide/activate side effects and are ignored.
    public static let settleInterval: TimeInterval = 0.5

    public let generation: UInt64
    public let startedAt: Date
    public private(set) var hiddenPIDs: Set<Int32>
    /// Apps that were asked to hide and did not; reported, never restored.
    public private(set) var refusedPIDs: Set<Int32> = []
    public private(set) var isCurrent: Bool = true
    /// Finder and Paneflo: activating them does not leave the desktop and they are never in `hiddenPIDs`.
    public let protectedPIDs: Set<Int32>

    public init(generation: UInt64, startedAt: Date, hidden: Set<Int32>, protected: Set<Int32>) {
        self.generation = generation
        self.startedAt = startedAt
        self.hiddenPIDs = hidden.subtracting(protected)
        self.protectedPIDs = protected
    }

    public var isActive: Bool { isCurrent || !hiddenPIDs.isEmpty }

    /// The apps a selection of `pid`'s window must unhide before focusing: only that app (the native Dock-click
    /// model). Marks the desktop as no longer current, since the user is leaving it.
    public mutating func restore(for pid: Int32?) -> Set<Int32> {
        isCurrent = false
        guard let pid, hiddenPIDs.remove(pid) != nil else { return [] }
        return [pid]
    }

    /// Every app Paneflo hid, for "Restore all" and for picking the Desktop entry while the desktop is current.
    public mutating func restoreAll() -> Set<Int32> {
        let all = hiddenPIDs
        hiddenPIDs = []
        isCurrent = false
        return all
    }

    /// Apps still visible after the hide pass did not hide; they are not ours to restore.
    public mutating func noteRefused(_ pids: Set<Int32>) {
        refusedPIDs.formUnion(pids)
        hiddenPIDs.subtract(pids)
    }

    /// A second Show Desktop while this session still holds hidden apps: the new hides join the set and the desktop
    /// becomes current again under a new generation.
    public func merging(newlyHidden: Set<Int32>, generation next: UInt64, at date: Date) -> DesktopSession {
        var merged = DesktopSession(generation: next, startedAt: date,
                                    hidden: hiddenPIDs.union(newlyHidden), protected: protectedPIDs)
        merged.refusedPIDs = refusedPIDs
        return merged
    }

    /// Reacts to the user's own app activity. Returns true when the session has ended.
    @discardableResult
    public mutating func apply(_ signal: DesktopSignal, at date: Date) -> Bool {
        switch signal {
        case .didTerminate(let pid):
            hiddenPIDs.remove(pid)
        case .didActivate(let pid), .didUnhide(let pid):
            guard date.timeIntervalSince(startedAt) >= Self.settleInterval else { break }
            // Activating or unhiding an app puts it back on screen.
            hiddenPIDs.remove(pid)
            if !protectedPIDs.contains(pid) { isCurrent = false }
        }
        return !isActive
    }
}
