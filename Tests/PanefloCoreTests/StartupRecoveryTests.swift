import Foundation
import Testing
@testable import PanefloCore

struct DesktopRestoreJournalTests {
    private let journal = DesktopRestoreJournal(generation: 4, entries: [
        .init(pid: 30, bundleIdentifier: "com.example.mail", launchDate: 1000),
        .init(pid: 20, bundleIdentifier: "com.example.editor", launchDate: 900),
        .init(pid: 40, bundleIdentifier: nil, launchDate: nil),
    ])

    @Test func roundTripsAndRejectsCorruptOrUnknownSchemas() throws {
        let data = try journal.encoded()
        #expect(DesktopRestoreJournal.decode(data) == journal)
        #expect(journal.entries.map(\.pid) == [20, 30, 40], "stored sorted")
        #expect(DesktopRestoreJournal.decode(Data("not json".utf8)) == nil)
        #expect(DesktopRestoreJournal.decode(Data()) == nil)
        let newer = Data(#"{"schemaVersion":2,"generation":1,"entries":[]}"#.utf8)
        #expect(DesktopRestoreJournal.decode(newer) == nil, "a newer journal is not acted on")
    }

    @Test func unhidesOnlyTheSameStillHiddenProcesses() {
        let running = [
            DesktopApp(pid: 20, bundleIdentifier: "com.example.editor", isRegular: true, isHidden: true, launchDate: 900),
            // The user unhid the mail app after Paneflo crashed: leave it.
            DesktopApp(pid: 30, bundleIdentifier: "com.example.mail", isRegular: true, isHidden: false, launchDate: 1000),
            DesktopApp(pid: 40, bundleIdentifier: nil, isRegular: true, isHidden: true, launchDate: nil),
        ]
        #expect(journal.appsToUnhide(running: running) == [20, 40])
    }

    @Test func reusedPIDsRelaunchesAndExitedAppsAreLeftAlone() {
        let running = [
            // Same PID, different process (launch date moved): never touched.
            DesktopApp(pid: 20, bundleIdentifier: "com.example.editor", isRegular: true, isHidden: true, launchDate: 5000),
            // Same PID reused by another app.
            DesktopApp(pid: 30, bundleIdentifier: "com.example.other", isRegular: true, isHidden: true, launchDate: 1000),
            // Terminating.
            DesktopApp(pid: 40, bundleIdentifier: nil, isRegular: true, isHidden: true, isTerminated: true),
        ]
        #expect(journal.appsToUnhide(running: running).isEmpty)
        #expect(journal.appsToUnhide(running: []).isEmpty, "apps that quit are gone")
        let launchKnownNow = [DesktopApp(pid: 40, bundleIdentifier: nil, isRegular: true, isHidden: true, launchDate: 7)]
        #expect(journal.appsToUnhide(running: launchKnownNow).isEmpty, "a launch date that appeared is a different lifetime")
    }
}

struct SlotMetadataRecoveryTests {
    private func store(_ count: Int) throws -> Data {
        var slots = OverviewSlotStore()
        slots.reconcile((0..<count).map {
            WindowRecord(id: .init(process: .init(pid: 9, launchToken: 1), number: UInt32($0), incarnation: 1),
                         appIdentifier: "app", appName: "App", title: "", frame: WindowRect(x: 0, y: 0, width: 100, height: 100))
        })
        return try slots.encodedMetadata()
    }

    @Test func usableDataIsLeftInPlace() throws {
        #expect(SlotMetadataAssessment.assess(try store(3)) == .usable)
        #expect(SlotMetadataAssessment.assess(try store(0)) == .usable)
    }

    @Test func unreadableDataIsQuarantinedByKind() {
        #expect(SlotMetadataAssessment.assess(Data("{garbage".utf8)) == .quarantine(tag: "corrupt"))
        #expect(SlotMetadataAssessment.assess(Data()) == .quarantine(tag: "corrupt"))
        let newer = Data(#"{"schemaVersion":2,"slots":[],"bindings":{"future":true}}"#.utf8)
        #expect(SlotMetadataAssessment.assess(newer) == .quarantine(tag: "schema2"), "newer data from a later version is kept")
        let id = UUID().uuidString
        let duplicate = Data(#"{"schemaVersion":1,"slots":[{"id":"\#(id)","isPinned":false},{"id":"\#(id)","isPinned":true}]}"#.utf8)
        #expect(SlotMetadataAssessment.assess(duplicate) == .quarantine(tag: "corrupt"))
        #expect(SlotMetadataAssessment.assess("a string") == .quarantine(tag: "invalid"))
        #expect(SlotMetadataAssessment.assess(42) == .quarantine(tag: "invalid"))
    }

    @Test func quarantineMovesUnreadableDataAsideAndKeepsUsableData() throws {
        let suite = "dev.paneflo.tests.slots.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "overview.slots.v1"
        #expect(SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: key) == nil, "absent")
        let good = try store(2)
        defaults.set(good, forKey: key)
        #expect(SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: key) == nil)
        #expect(defaults.data(forKey: key) == good, "usable data is untouched")

        let newer = Data(#"{"schemaVersion":3,"slots":[]}"#.utf8)
        defaults.set(newer, forKey: key)
        #expect(SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: key) == "\(key).backup-schema3")
        #expect(defaults.object(forKey: key) == nil, "the Overview starts fresh")
        #expect(defaults.data(forKey: "\(key).backup-schema3") == newer, "newer data survives")
        // The same blob again reuses its backup; a different one gets a new key.
        defaults.set(newer, forKey: key)
        #expect(SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: key) == "\(key).backup-schema3")
        let other = Data(#"{"schemaVersion":3,"slots":[],"x":1}"#.utf8)
        defaults.set(other, forKey: key)
        #expect(SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: key) == "\(key).backup-schema3-2")
        #expect(defaults.data(forKey: "\(key).backup-schema3") == newer)
        defaults.set("oops", forKey: key)
        #expect(SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: key) == "\(key).backup-invalid")
        #expect(defaults.string(forKey: "\(key).backup-invalid") == "oops")
    }

    @Test func backupsNeverOverwriteEarlierOnes() {
        let key = "overview.slots.v1"
        #expect(SlotMetadataAssessment.backupKey(for: key, tag: "schema2") { _ in false } == "overview.slots.v1.backup-schema2")
        let taken: Set<String> = ["overview.slots.v1.backup-corrupt", "overview.slots.v1.backup-corrupt-2"]
        #expect(SlotMetadataAssessment.backupKey(for: key, tag: "corrupt") { taken.contains($0) } == "overview.slots.v1.backup-corrupt-3")
    }
}
