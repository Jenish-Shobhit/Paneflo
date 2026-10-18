import AppKit
import PanefloCore

/// What the surfaces need for the Desktop entry (the switcher's Desktop card and the Overview home tile).
///
/// The app supplies `DesktopEntryController` (Show Desktop service, settings and wallpaper decoding). Own-window
/// checks supply a fake, so no check ever hides an app. Every member is cheap and synchronous except the wallpaper
/// refresh, which decodes off the main actor and is throttled.
@MainActor
protocol DesktopEntryProvider: AnyObject {
    /// The "Show Desktop in ⌘Tab and Overview" setting.
    var showsDesktopEntry: Bool { get }
    /// The desktop is the current state (it was just shown and no app has come forward since).
    var isDesktopShown: Bool { get }
    /// What choosing the entry does: show the desktop, or bring back what Paneflo hid when the desktop is current.
    func activateDesktopEntry()
    /// Runs `focus` once the window's app may be raised: when a desktop session hid that app it is unhidden first
    /// (and `focus` waits briefly for it), otherwise `focus` runs at once.
    func prepareToFocus(pid: pid_t, then focus: @escaping @MainActor () -> Void)
    /// The last decoded wallpaper for `screen`, or nil. Never decodes or touches the file system.
    func cachedWallpaper(for screen: NSScreen) -> CGImage?
    /// Re-reads the wallpaper for `screen` off the main actor, at most every few seconds. `completion` runs on the
    /// main actor only when the image changed (nil means "no still image": draw the placeholder).
    func refreshWallpaper(for screen: NSScreen, completion: @escaping @MainActor (CGImage?) -> Void)
    /// Display configuration changed: cached wallpapers may belong to another display now.
    func screensChanged()
}

extension DesktopEntryProvider {
    var loopMode: DesktopLoopMode { DesktopLoopMode.make(enabled: showsDesktopEntry, desktopIsCurrent: isDesktopShown) }
}

extension NSScreen {
    /// The Core Graphics display ID (stable while the display stays attached).
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Where a surface opens: the screen containing the mouse pointer, so it appears where the user is looking
    /// (and works the same for the keyboard, the gesture and the menu). Falls back to the key window's screen.
    static var pointerScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main ?? screens.first
    }
}
