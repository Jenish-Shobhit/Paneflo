import Foundation

/// The platform adapter supplies a monotonically increasing launch token for each PID lifetime.
public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let launchToken: UInt64

    public init(pid: Int32, launchToken: UInt64) {
        self.pid = pid
        self.launchToken = launchToken
    }
}

/// An incarnation increases whenever a window number is reused within a process lifetime.
public struct WindowIdentity: Hashable, Codable, Sendable {
    public let process: ProcessIdentity
    public let number: UInt32
    public let incarnation: UInt64

    public init(process: ProcessIdentity, number: UInt32, incarnation: UInt64) {
        self.process = process
        self.number = number
        self.incarnation = incarnation
    }
}

/// Ephemeral presentation metadata. Deliberately not Codable: titles are not persistence data.
public struct WindowRecord: Equatable, Sendable {
    public let id: WindowIdentity
    public var appIdentifier: String
    public var appName: String
    public var title: String
    public var frame: WindowRect
    public var isMinimized: Bool
    public var documentKey: String?

    public init(id: WindowIdentity, appIdentifier: String, appName: String, title: String,
                frame: WindowRect, isMinimized: Bool = false, documentKey: String? = nil) {
        self.id = id
        self.appIdentifier = appIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.documentKey = documentKey
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public let records: [WindowRecord]
    public let mostRecent: [WindowIdentity]

    public init(records: [WindowRecord], mostRecent: [WindowIdentity] = []) {
        var seen = Set<WindowIdentity>()
        self.records = records.filter { seen.insert($0.id).inserted }
        let valid = Set(self.records.map(\.id))
        seen.removeAll(keepingCapacity: true)
        self.mostRecent = mostRecent.filter { valid.contains($0) && seen.insert($0).inserted }
    }

    public var orderedRecords: [WindowRecord] {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let recent = Set(mostRecent)
        return mostRecent.compactMap { byID[$0] } + records.filter { !recent.contains($0.id) }
    }
}

/// A deterministic reducer. Only confirmed focus changes MRU; failed reads need no mutation.
public struct WindowRegistry: Sendable {
    private var records: [WindowIdentity: WindowRecord] = [:]
    private var insertionOrder: [WindowIdentity] = []
    private var mostRecent: [WindowIdentity] = []
    private var latestLaunch: [Int32: UInt64] = [:]
    private var latestIncarnation: [NumberKey: UInt64] = [:]
    private var latestRevision: [NumberKey: UInt64] = [:]
    private var endedPIDs = Set<Int32>()
    private var localRevision: UInt64 = 0

    private struct NumberKey: Hashable, Sendable {
        let process: ProcessIdentity
        let number: UInt32
    }

    public init() {}

    @discardableResult
    public mutating func upsert(_ record: WindowRecord, revision: UInt64? = nil) -> Bool {
        let id = record.id
        guard admitLifetime(id.process), let eventRevision = sequence(revision) else { return false }
        let key = NumberKey(process: id.process, number: id.number)
        if let latest = latestRevision[key], eventRevision <= latest { return false }
        if let incarnation = latestIncarnation[key] {
            guard id.incarnation >= incarnation else { return false }
            // A confirmed close cannot be undone by a delayed update for the same incarnation.
            if id.incarnation == incarnation && records[id] == nil { return false }
        }
        let obsolete = insertionOrder.filter {
            $0.process == id.process && $0.number == id.number && $0 != id
        }
        for old in obsolete { removeRecord(old) }
        latestIncarnation[key] = id.incarnation
        latestRevision[key] = eventRevision
        if records[id] == nil { insertionOrder.append(id) }
        records[id] = record
        return true
    }

    /// Defaults are for serialized input. Adapters with asynchronous sources supply monotonic revisions.
    public mutating func remove(_ id: WindowIdentity, revision: UInt64? = nil) {
        guard admitLifetime(id.process), let eventRevision = sequence(revision) else { return }
        let key = NumberKey(process: id.process, number: id.number)
        if let latest = latestRevision[key], eventRevision <= latest { return }
        if let incarnation = latestIncarnation[key], id.incarnation < incarnation { return }
        latestIncarnation[key] = id.incarnation
        latestRevision[key] = eventRevision
        let obsolete = insertionOrder.filter { $0.process == id.process && $0.number == id.number }
        for old in obsolete { removeRecord(old) }
    }

    /// Window tombstones live only for their process lifetime; one latest-launch marker remains per PID.
    public mutating func processEnded(_ process: ProcessIdentity) {
        guard admitLifetime(process) else { return }
        for id in insertionOrder.filter({ $0.process == process }) { removeRecord(id) }
        latestIncarnation = latestIncarnation.filter { $0.key.process != process }
        latestRevision = latestRevision.filter { $0.key.process != process }
        endedPIDs.insert(process.pid)
    }

    private mutating func removeRecord(_ id: WindowIdentity) {
        records.removeValue(forKey: id)
        insertionOrder.removeAll { $0 == id }
        mostRecent.removeAll { $0 == id }
    }

    @discardableResult
    public mutating func commitFocus(_ id: WindowIdentity) -> Bool {
        guard records[id] != nil else { return false }
        mostRecent.removeAll { $0 == id }
        mostRecent.insert(id, at: 0)
        return true
    }

    public var snapshot: WindowSnapshot {
        WindowSnapshot(records: insertionOrder.compactMap { records[$0] }, mostRecent: mostRecent)
    }

    private mutating func admitLifetime(_ process: ProcessIdentity) -> Bool {
        if let launch = latestLaunch[process.pid] {
            guard process.launchToken >= launch else { return false }
            if process.launchToken == launch { return !endedPIDs.contains(process.pid) }
        }
        for id in insertionOrder.filter({ $0.process.pid == process.pid }) { removeRecord(id) }
        latestIncarnation = latestIncarnation.filter { $0.key.process.pid != process.pid }
        latestRevision = latestRevision.filter { $0.key.process.pid != process.pid }
        latestLaunch[process.pid] = process.launchToken
        endedPIDs.remove(process.pid)
        return true
    }

    private mutating func sequence(_ supplied: UInt64?) -> UInt64? {
        if let supplied { localRevision = max(localRevision, supplied); return supplied }
        guard localRevision < UInt64.max else { return nil }
        localRevision += 1
        return localRevision
    }
}

enum WindowSearch {
    static func matches(_ query: String, record: WindowRecord) -> Bool {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace)
        let text = normalized(record.appName + " " + record.title)
        return terms.allSatisfy { text.contains($0) }
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive],
                       locale: Locale(identifier: "en_US_POSIX"))
    }
}
