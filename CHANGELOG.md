# Changelog

All notable changes to Paneflo are listed here. Versions follow [Semantic Versioning](https://semver.org); releases before 1.0.0 are 0.x milestones.

## Unreleased

### Tiling

- Snap areas: drag a window by its title bar to the top edge of a display to fill it, to the left or right edge for that half, or into a corner for a quarter. A translucent outline shows where it will land; release to place it. The bottom edge does nothing. Edges shared between displays don't count, and the menu bar counts as the top edge. A window Paneflo tiled gets its previous size back when you drag it away. Snapped windows pair and undo like any other tile. On by default: Settings › Tiling › Snap windows by dragging to screen edges.
- Settings › Tiling › Keyboard Shortcuts: record your own shortcut for each arrangement (halves, quarters, thirds, Fill, Center, Restore). Defaults stay ⌃⌥ with the arrows, Return and Z; the rest start unassigned. Delete clears a shortcut, Escape cancels, Reset to Defaults restores them. Changes apply at once and the menu bar's Tile Front Window shows the new keys.
- Shortcuts need ⌘, ⌃ or ⌥ (F-keys excepted), can't use Paneflo's own keys, and move from another action rather than doubling up. System chords such as ⌘Q warn instead of blocking.
- Shortcuts follow the physical key and are shown with the current keyboard layout's character.

## 1.1.0 — 2026-10-19

### Switcher

- ⌘Tab is now a compact Liquid Glass shelf over your desktop: window cards, and the selected window's full title underneath (Settings › General › Show selected window title turns it off). There are no headings, key hints or Live/Snapshot labels on the cards.
- Cards have a recessed preview in the window's own shape, the app icon, the title and the app name; the selection is an accent ring with no movement. A small symbol marks minimized, hidden, other-Space and paused previews, and VoiceOver says whether a picture is live or a snapshot and how old it is.
- Card size is chosen each time the picker opens to fit your windows on one to three balanced rows (Settings › General › Card size picks a fixed size). With many windows the grid scrolls with soft edges.
- Tile pairs sit side by side with a link at the seam; selecting one rings it and outlines its partner.
- Light and dark, Increase Contrast, Reduce Transparency and Reduce Motion are respected. A warm ⌘Tab opens faster with many windows.

### Overview

- The Overview is a full-display translucent overlay with a search field, a window count, the Desktop tile and your slots. Click the background to close it.
- Free and kept slots have a new recessed look with hover and drop states. Drag a window onto a free slot to move it there, or onto another window to swap; right-click a free slot to remove it.
- Free slots no longer pile up. They hold their places while the Overview is open; the next time it opens they are gone and windows keep their relative order. Pinned slots stay as faint outlined wells waiting for their app. Settings › Overview & Gesture › Keep empty places for closed windows: Off (default), Until Paneflo quits, or Always (the 1.0 behaviour). Free slots saved by 1.0 are dropped on first launch; pinned slots are kept.

### Tiling and tile pairs

- Two windows filling complementary halves of one display (left and right, or top and bottom) form a pair, whether Paneflo arranged them or not. A pair ends when a window closes, minimizes, moves to another display or leaves its half, or when you choose Unpair. Pairs last until Paneflo quits.
- Opening a paired window brings its partner forward too (Settings › Tiling › Raise tile pairs together). ⌘⌥Return in the picker or Overview always opens the pair; ⌘A in the picker or ⌥Return in the Overview opens the selection alone. The Overview's right-click menu has Open Pair, Open Alone and Unpair.
- Snap assist: after ⌘⌥← in the picker, the selected card outlines the right half; ⌘⌥→ on another window places it beside the first and pairs them (and the other way round). Escape or releasing ⌘ ends it.
- Replacing a pair member is one step: tile a third window into a paired half and it pairs with the other half at once, while the replaced window returns to its previous frame when that is known. Tiling a paired window into its partner's half swaps the two. Fill ends the pair.
- One undo (⌘⌥↓ or ⌃⌥Z) restores every window an arrangement moved and re-forms the pairs it ended. In the picker, ⌘⌥↓ undoes the selected window.
- A window that limits its own size keeps it against its edge and its partner takes the rest of the display. Resizing a pair along its shared edge keeps it paired; moving or resizing one window alone ends it.
- Tiling restores a minimized window and unhides a hidden app first, and says so when it can't arrange a window (full-screen, Accessibility off, nothing selected, nothing to undo) in a short note near the bottom of the display.
- Fixed: ⌃⌥ arrows, ⌃⌥Return and ⌃⌥Z could silently do nothing when Paneflo's idea of the focused window was out of date. The target is now read from the frontmost app when you press the keys, so tiling the front window works anywhere.

### Settings, setup and menu bar

- Settings is a window with a sidebar: General, Shortcuts & Help, Tiling, Overview & Gesture, Previews, Desktop, Permissions, Updates and About. Each pane says what it is for.
- Shortcuts & Help lists every key and gesture as keycaps, grouped and searchable.
- Permissions shows live Accessibility, Input Monitoring and Screen Recording status, Restart Paneflo when macOS needs it, the reset for stuck permissions and Open Setup Guide…. The sidebar always says whether ⌘Tab is ready.
- The setup window has four steps: Welcome (first run only), Give Paneflo access, an optional gesture step, and You’re set. It opens only while something required is missing.
- The menu's Arrange Windows… list is replaced by **Tile Front Window**: Left, Right, Top and Bottom Half, Fill and Undo, showing their ⌃⌥ shortcuts.
- A new menu bar icon (three panes) with an orange dot when setup is needed and a dimmed look when shortcuts are paused. The menu starts with a status line and uses Pause/Resume Shortcuts; the automatic-update switch moved to Settings › Updates.
- **Hide from Menu Bar** (menu item or Settings › General) asks once; Paneflo, its shortcuts and the gesture keep running. Open Paneflo again from Spotlight, Launchpad or Applications to bring the icon back. The icon can't be hidden while setup is needed or macOS has stopped the shortcuts.
- VoiceOver labels on every control and keyboard navigation in setup.

### Performance

- The Overview opens faster (about 20% in a synthetic benchmark on one Mac).
- Moving the selection in the picker and Overview is lighter.
- The menu bar item is ready earlier after launch.

## 1.0.0 — Not released separately (included in 1.1.0)

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

[1.1.0]: https://github.com/Jenish-Shobhit/Paneflo/releases/tag/v1.1.0
[1.0.0]: https://github.com/Jenish-Shobhit/Paneflo/releases/tag/v1.1.0
