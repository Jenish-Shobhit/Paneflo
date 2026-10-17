import AppKit

/// The menu bar items for updates: "Check for Updates…" and a "Check for Updates Automatically" toggle. The controller of
/// the status menu adds them with `UpdateMenu.shared.addItems(to:)`; they act on `UpdateController.shared`.
@MainActor
final class UpdateMenu: NSObject, NSMenuItemValidation {
    static let shared = UpdateMenu()

    func addItems(to menu: NSMenu) {
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let automatic = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self
        menu.addItem(automatic)
    }

    @objc private func checkForUpdates() { UpdateController.shared.checkForUpdates() }

    @objc private func toggleAutomatic() {
        UpdateController.shared.checksAutomatically.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomatic) {
            item.state = UpdateController.shared.checksAutomatically ? .on : .off
        }
        return true
    }
}
