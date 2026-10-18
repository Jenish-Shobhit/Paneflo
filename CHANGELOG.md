# Changelog

All notable changes to Paneflo are listed here. Versions follow [Semantic Versioning](https://semver.org); releases before 1.0.0 are 0.x milestones.

## 1.1.0 — Unreleased

### Switcher and Overview redesign

- ⌘Tab is a compact Liquid Glass shelf over your desktop: no heading and no key hints, just window cards and the selected window's full title. Cards have a recessed preview at the window's own shape, the app icon, the title and the app name; the selection is an accent ring, with no movement.
- Cards come in four sizes, chosen once each time the picker opens to fit your windows on one to three balanced rows (the last row is centred); with many windows the grid scrolls with soft edges.
- Previews look like the window: the Live and Snapshot labels are gone. A small symbol marks minimized, hidden, other-Space and paused previews; VoiceOver says whether a picture is live or a snapshot and how old it is, and the Overview shows it in a tooltip.
- Tile pairs sit side by side in ⌘Tab with a link at the seam; selecting one rings it and outlines its partner. Snap assist shows a faint outline of the half you are about to fill instead of text.
- The Overview is a full-display translucent overlay with a search field, a window count, the Desktop tile and your slots; click the background to close it. Free and kept slots have a new recessed look with hover and drop states. Drag a window onto a free slot to move it there (its old slot becomes free) or onto another window to swap them; right-click a free slot to remove it.
- Light and dark, Increase Contrast (thicker ring, card borders), Reduce Transparency (opaque backdrop) and Reduce Motion are respected. Selecting a card does no redrawing and no layout.

### Tile pairs

- Two windows filling complementary halves of one display (left and right, or top and bottom) form a pair, whether Paneflo arranged them or they were already there. A pair ends when a window closes, minimizes, moves to another display or leaves its half, or when you choose Unpair. Pairs last until Paneflo quits.
- Opening a paired window from ⌘Tab or the Overview brings its partner forward first, then focuses the window you chose, so both are visible. Turn this off in Settings.
- ⌘⌥Return (or keypad Enter) in the picker or a keyboard-focused Overview opens the selection with its partner regardless of that setting. The Overview's right-click menu offers Open Pair, Open Alone and Unpair for paired windows.
- Snap assist in the picker: after ⌘⌥← tiles the selection to the left half, the selected card shows a faint outline of the right half; ⌘⌥→ on another window places it on the same display and pairs the two (and the other way round). Escape or releasing ⌘ ends it.
- Bringing a partner forward activates its app for a moment before the chosen window's app takes focus: an Accessibility raise alone leaves a background window behind the frontmost app.

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

- **Set up Paneflo** opens by itself only while a required permission is missing, at most once per launch, and never loops back to Settings. It lists Accessibility and Input Monitoring (required) and Screen Recording (optional), with live status checked every second while it is open. **Grant…** asks macOS and opens the exact Privacy & Security pane; a row turns green on its own.
- **Restart Paneflo** appears when Input Monitoring or Screen Recording needs a relaunch to apply (or the shortcut tap still fails with access on). Paneflo reopens itself and starts everything you had chosen without another click.
- **Permissions stuck? Reset and grant again** clears only Paneflo's own permission entries (`tccutil reset … dev.paneflo.Paneflo`), for when macOS keeps an entry from an older build, then starts granting again. Setup suggests it when a permission is still off after the restart.
- Shortcuts are on once setup is done; the gesture stays opt-in; previews run whenever Screen Recording is granted, unless you turn them off. Choices are remembered, and a failed start no longer switches shortcuts off.
- Launch never opens Settings. While setup is incomplete the menu-bar icon has a badge and the menu offers **Finish setup…**.
- The menu has Settings…, Check for Updates…, Enable/Disable shortcuts, **Hide menu bar icon** and Quit Paneflo. With the icon hidden Paneflo keeps running; opening it again from Finder, Spotlight or Launchpad shows Settings, where **Show menu bar icon** brings it back.
- Settings is grouped into Permissions, Shortcuts, Trackpad gesture, Previews, Desktop, Updates and Menu bar, and adds **Launch at login** (off by default). The window-arranging and refresh buttons that duplicated the shortcuts and menu are gone.
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
