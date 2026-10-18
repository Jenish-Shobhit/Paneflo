# Changelog

All notable changes to Paneflo are listed here. Versions follow [Semantic Versioning](https://semver.org); releases before 1.0.0 are 0.x milestones.

## 1.0.0 — Unreleased

First release. Paneflo is a menu-bar app for macOS 26 or later on Apple silicon, signed with a self-signed certificate (not notarized yet).

### Switcher

- Hold ⌘ and press Tab (Shift–Tab goes back) to pick a single window instead of an app. While ⌘ is held, the arrow keys also choose: Left/Right step, Up/Down move by row. Release ⌘ to focus the window; Escape cancels.
- The order follows real Command-Tab use: it starts from the on-screen window order and updates as you focus windows.
- Focus raises the window first and activates its app after, and does not wait behind a window scan.
- Escape closes the picker or Overview whenever one is showing, even if another window has keyboard focus (except an Escape that ends input-method composition in Paneflo's search field).

### Tiling

- In the picker or Overview, ⌘⌥ with the arrows places the selected window: Left/Right for a half, Up to fill the display, Down to undo.
- Anywhere, ⌃⌥ with the arrows tiles the focused window to a half, ⌃⌥Return fills its display, and ⌃⌥Z undoes the latest change.
- Repeating a half-screen request moves the window to the neighbouring display. Undo is per window and keeps the window on a visible display.
- A tile is placed in one pass and apps that limit their size are centered in the zone. Releasing ⌘ focuses at once while the tile finishes.

### Overview & gesture

- ⌃⌥Space opens a larger Overview with every window in stable slots you control. Arrows move spatially, search keeps the slots in place, Return or a click focuses, pinned slots are remembered.
- Optional three-finger swipe up opens the Overview and swipe down closes it. It uses a private macOS interface, so it is experimental; Settings tells you if it is unavailable and shows whether the system Mission Control / App Exposé swipes conflict. Paneflo does not change those settings for you.
- The picker and the Overview open on the display under the pointer and re-fit when displays change.

### Desktop entry

- A Desktop card ends the ⌘Tab loop (second right after the desktop was shown) and the Overview starts with a Desktop tile. Choosing it hides the other apps (Finder stays); choosing it again, or a window, brings back what Paneflo hid. Turn it off in Settings.
- Optional, experimental: **Use macOS Show Desktop** sends the system shortcut instead.

### Previews

- Cards show cached snapshots labelled with their age, refreshed on open. Only the selected window can have a live preview, and it stops when the picker closes.
- Each card says Live, Snapshot · age, Loading, Unavailable (with a reason) or Paused.
- Snapshots are kept in memory only (24 MiB, less under memory pressure) and are cleared on app hide, turning previews off, critical memory pressure, losing Screen Recording access, screen lock and user switching.

### Settings & permissions

- Shortcuts, previews and the gesture are opt-in and remembered. Settings explains what each needs: Accessibility, Input Monitoring, and Screen Recording only for previews. Previews start without a relaunch where macOS allows it.
- Disable global shortcuts is always in the menu-bar menu.
- If macOS turns the keyboard hook off, Paneflo re-enables it a few times, then releases it and asks you to turn shortcuts on again.

### Updates & install

- Check for Updates… in the menu-bar menu, plus an optional daily automatic check (on by default, never while the picker or Overview is showing). A newer release is downloaded and verified (size, SHA-256, bundle ID, version, code signature and the same signing certificate as the running copy) before Paneflo quits, replaces itself and reopens. The old copy goes to the Trash.
- A download page (`docs/index.html`, for GitHub Pages) and `scripts/release.sh` to publish a release.
- Build, sign (self-signed "Paneflo Dev"), install and zip with `scripts/build.sh`.

### Reliability

- Window discovery, screenshots and live-stream start have deadlines, so a slow or unresponsive app cannot stall the picker.
- Locking the screen, display sleep and switching users close any surface and stop capture until the session is back.

### Hardening (0.8)

- While the ⌘Tab picker is held, ⌘W closes the selected window, ⌘M minimizes it, ⌘H hides its app and ⌘Q quits its app, and the picker stays open. Other keys pressed while switching no longer reach the app behind it.
- Apps hidden by the Desktop entry come back when Paneflo quits, and at the next launch if Paneflo crashed or was force-quit.
- If macOS keeps turning off the shortcut tap, shortcuts stay enabled in Settings and Paneflo retries on its own; turning Shortcuts on retries at once.
- The ⌘Tab picker closes even if the ⌘ release was missed and no other key follows.
- Previews keep working after screenshot or window-list requests that macOS never answers.
- The trackpad gesture recovers from a missing built-in trackpad (for example a closed lid) without restarting Paneflo.
- Unreadable or newer Overview arrangement data is kept as a backup instead of being overwritten.
