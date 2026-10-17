/// One window server entry (a `CGWindowListCopyWindowInfo` row reduced to matching fields).
public struct WindowServerEntry: Equatable, Sendable {
    public let number: UInt32
    public let ownerPID: Int32
    public let layer: Int
    public let frame: WindowRect
    public let title: String?
    /// Front-to-back position; lower is nearer the front. Off-screen entries sort after on-screen.
    public let stackIndex: Int

    public init(number: UInt32, ownerPID: Int32, layer: Int = 0, frame: WindowRect, title: String? = nil, stackIndex: Int) {
        self.number = number; self.ownerPID = ownerPID; self.layer = layer
        self.frame = frame; self.title = title; self.stackIndex = stackIndex
    }
}

/// One Accessibility window of a process, in the process's own AX window order. AppKit reports
/// that order front to back, which supplies the tiebreak for otherwise identical windows.
public struct AccessibilityWindowProbe: Equatable, Sendable {
    public let frame: WindowRect
    public let title: String?
    /// A number already established for this window (direct mapping or a previous match).
    public let known: UInt32?

    public init(frame: WindowRect, title: String? = nil, known: UInt32? = nil) {
        self.frame = frame; self.title = title; self.known = known
    }
}

/// Public fallback for AX window → window server number mapping. Conservative: an ambiguity
/// that cannot be resolved by frame, title, or a one-to-one stacking order yields nil.
public enum WindowNumberMatcher {
    public static let frameTolerance = 2.0

    public static func match(pid: Int32, probes: [AccessibilityWindowProbe], entries: [WindowServerEntry],
                             claimed: Set<UInt32> = []) -> [UInt32?] {
        var result = [UInt32?](repeating: nil, count: probes.count)
        var used = claimed
        let owned = entries.filter { $0.ownerPID == pid }
        let ownedNumbers = Set(owned.map(\.number))
        // Established numbers win if the window server still lists them for this process.
        for (index, probe) in probes.enumerated() {
            if let known = probe.known, ownedNumbers.contains(known), !used.contains(known) {
                result[index] = known; used.insert(known)
            }
        }
        let pool = owned.filter { $0.layer == 0 }.sorted { $0.stackIndex < $1.stackIndex }
        func candidates(_ index: Int) -> [WindowServerEntry] {
            pool.filter { !used.contains($0.number) && sameFrame($0.frame, probes[index].frame) }
        }
        // Unique frame matches, then unique title matches, repeated until stable.
        var progress = true
        while progress {
            progress = false
            for index in probes.indices where result[index] == nil {
                let options = candidates(index)
                var chosen: WindowServerEntry?
                if options.count == 1 { chosen = options[0] }
                else if options.count > 1, let title = probes[index].title, !title.isEmpty {
                    let titled = options.filter { $0.title == title }
                    if titled.count == 1 { chosen = titled[0] }
                }
                if let chosen { result[index] = chosen.number; used.insert(chosen.number); progress = true }
            }
        }
        // Remaining ambiguity: probes that share exactly the same candidate set are paired in
        // AX order with candidates in stacking order, only when the counts are equal.
        var groups: [[UInt32]: [Int]] = [:]
        var groupOrder: [[UInt32]] = []
        for index in probes.indices where result[index] == nil {
            let key = candidates(index).map(\.number)
            guard key.count > 1 else { continue }
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(index)
        }
        for key in groupOrder {
            guard let members = groups[key], members.count == key.count,
                  key.allSatisfy({ !used.contains($0) }) else { continue }
            for (member, number) in zip(members, key) { result[member] = number; used.insert(number) }
        }
        return result
    }

    static func sameFrame(_ a: WindowRect, _ b: WindowRect) -> Bool {
        abs(a.x - b.x) < frameTolerance && abs(a.y - b.y) < frameTolerance
            && abs(a.width - b.width) < frameTolerance && abs(a.height - b.height) < frameTolerance
    }
}
