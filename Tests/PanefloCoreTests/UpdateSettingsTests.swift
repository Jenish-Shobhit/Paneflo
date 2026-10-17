import Foundation
@testable import PanefloCore
import Testing

/// The update bookkeeping in `UpdateSettings`, on a throwaway suite.
@Suite final class UpdateSettingsTests {
    let suite = "dev.paneflo.Paneflo.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: UpdateSettings

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = UpdateSettings(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func startingValues() {
        #expect(settings.checksAutomatically == true)
        #expect(settings.skippedVersion == nil)
        #expect(settings.lastCheck == nil)
        #expect(settings.pendingUpdate == nil)
    }

    @Test func roundTrips() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        settings.checksAutomatically = false
        settings.skippedVersion = "0.0.20"
        settings.lastCheck = date
        settings.pendingUpdate = ("0.0.21", date)
        let again = UpdateSettings(defaults: defaults)
        #expect(again.checksAutomatically == false)
        #expect(again.skippedVersion == "0.0.20")
        #expect(again.lastCheck == date)
        #expect(again.pendingUpdate?.version == "0.0.21")
        #expect(again.pendingUpdate?.date == date)
        again.pendingUpdate = nil
        again.skippedVersion = nil
        #expect(settings.pendingUpdate == nil)
        #expect(settings.skippedVersion == nil)
        #expect(defaults.object(forKey: UpdateSettings.pendingDateKey) == nil)
    }

    @Test func aHalfWrittenPendingUpdateIsNone() {
        defaults.set("0.0.21", forKey: UpdateSettings.pendingVersionKey)
        #expect(settings.pendingUpdate == nil)
    }
}

/// A scratch folder for the install helper's fake apps.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanefloCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
