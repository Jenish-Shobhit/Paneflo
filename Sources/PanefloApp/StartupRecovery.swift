import AppKit
import PanefloCore

/// Repairs state an earlier run may have left behind. Runs before any surface or service reads it.
@MainActor
enum StartupRecovery {
    static let overviewSlotsKey = "overview.slots.v1"

    /// Call first in `applicationDidFinishLaunching`.
    static func launch(defaults: UserDefaults = .standard) {
        let restored = DesktopService.restoreJournaledApps(defaults: defaults)
        let quarantined = quarantineOverviewSlots(defaults: defaults)
        RuntimeDiagnostics.mark("startup recovery desktopAppsRestored=\(restored) overviewSlots=\(quarantined ?? "usable")")
    }

    /// Call from `applicationWillTerminate`: apps a Show Desktop hid come back when Paneflo quits.
    static func terminate(defaults: UserDefaults = .standard) {
        DesktopService.restoreJournaledApps(defaults: defaults)
    }

    /// Stored slot metadata this version cannot read is backed up and removed before the Overview loads it.
    @discardableResult
    static func quarantineOverviewSlots(defaults: UserDefaults) -> String? {
        SlotMetadataAssessment.quarantineIfUnreadable(in: defaults, key: overviewSlotsKey)
    }
}
