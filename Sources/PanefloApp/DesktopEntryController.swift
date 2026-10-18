import AppKit
import PanefloCore

/// The app's Desktop entry: the Show Desktop service, its settings and the wallpaper decoder behind one
/// `DesktopEntryProvider` for the surfaces.
@MainActor
final class DesktopEntryController: DesktopEntryProvider {
    /// One decoded size serves both surfaces' cards (the layer scales it down); about 1 MiB per display.
    static let wallpaperPixelSize = CGSize(width: 640, height: 400)
    /// The wallpaper file is re-checked at most this often, and never on the input path.
    static let wallpaperRefreshInterval: TimeInterval = 5

    let service: DesktopService
    private let settings: DesktopSettings
    private let images = DesktopImageProvider(capacity: 2)
    private var wallpapers: [CGDirectDisplayID: (image: CGImage?, checkedAt: TimeInterval)] = [:]
    private var refreshing: Set<CGDirectDisplayID> = []
    /// Cached so a ⌘Tab never reads `UserDefaults`.
    private var showsEntry: Bool

    init(service: DesktopService, settings: DesktopSettings) {
        self.service = service
        self.settings = settings
        showsEntry = settings.showsDesktopEntry
    }

    var showsDesktopEntry: Bool {
        get { showsEntry }
        set { showsEntry = newValue; settings.showsDesktopEntry = newValue }
    }

    var usesSystemShowDesktop: Bool {
        get { settings.usesSystemShowDesktop }
        set { settings.usesSystemShowDesktop = newValue }
    }

    var isDesktopShown: Bool { service.isDesktopShown }

    func activateDesktopEntry() {
        let outcome = service.activateDesktopEntry()
        RuntimeDiagnostics.mark("desktop entry activated outcome=\(outcome.map { "\($0)" } ?? "restoredAll")")
    }

    func prepareToFocus(pid: pid_t, then focus: @escaping @MainActor () -> Void) {
        guard let session = service.session else { focus(); return }
        let app = NSRunningApplication(processIdentifier: pid)
        if session.hiddenPIDs.contains(pid) {
            // Paneflo hid this app: unhide it and wait (at most 0.3 s) so the AX raise finds it visible.
            Task { [service] in
                await service.restoreAndWait(for: app)
                focus()
            }
        } else {
            // Not hidden by Paneflo: leave the "desktop is current" state and focus at once.
            service.restore(for: app)
            focus()
        }
    }

    func cachedWallpaper(for screen: NSScreen) -> CGImage? {
        screen.displayID.flatMap { wallpapers[$0]?.image }
    }

    func refreshWallpaper(for screen: NSScreen, completion: @escaping @MainActor (CGImage?) -> Void) {
        guard let id = screen.displayID, !refreshing.contains(id) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let entry = wallpapers[id], now - entry.checkedAt < Self.wallpaperRefreshInterval { return }
        refreshing.insert(id)
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.images.image(for: screen, maxPixelSize: Self.wallpaperPixelSize)?.image
            self.refreshing.remove(id)
            let previous = self.wallpapers[id]?.image
            self.wallpapers[id] = (loaded, ProcessInfo.processInfo.systemUptime)
            if previous !== loaded { completion(loaded) }
        }
    }

    func screensChanged() {
        wallpapers.removeAll()
        images.removeAll()
    }
}
