# User guide

Paneflo is a menu-bar app with three modules that share one list of your windows: the **Switcher**, **Tiling** and the **Overview**. This guide covers each one and Settings. Key lists are in [shortcuts.md](shortcuts.md); problems are in [troubleshooting.md](troubleshooting.md).

- [First run](#first-run)
- [Switcher](#switcher)
- [Window actions while switching](#window-actions-while-switching)
- [Tiling](#tiling)
- [Tile pairs](#tile-pairs)
- [Overview](#overview)
- [Desktop entry](#desktop-entry)
- [Previews](#previews)
- [Trackpad gesture](#trackpad-gesture)
- [Settings](#settings)
- [Menu bar](#menu-bar)
- [Updates and privacy](#updates-and-privacy)

## First run

Move **Paneflo.app** to `/Applications` and open it. Because Paneflo is not notarized yet, choose **Open Anyway** in System Settings › Privacy & Security the first time. **Set up Paneflo** then opens while something required is missing: a short Welcome on the very first run, **Give Paneflo access**, an optional gesture step, and **You're set**.

| Permission | Required | Used for |
| --- | --- | --- |
| Accessibility | Yes | Finding, focusing, moving and resizing other apps' windows |
| Input Monitoring | Yes | Hearing ⌘Tab, the tiling shortcuts and the gesture |
| Screen Recording | No | Window pictures; without it cards show app icons |

Click **Grant…** on a row, switch Paneflo on in the System Settings pane, and come back; the row turns green by itself. If a row says **Restart Paneflo to apply**, restart it. **Later** (or Escape) closes setup; **Finish Setup…** in the menu brings it back.

## Switcher

Hold ⌘ and press Tab. Paneflo lists individual windows, not apps. Shift-Tab steps back; the arrow keys also choose while ⌘ is held (Left/Right step, Up/Down move by row). Release ⌘ to focus the selected window, or press Escape to cancel.

- Windows appear as cards on a compact glass shelf. Card size fits your windows on as few rows as possible; with many windows the grid scrolls.
- The selected window's full title is shown underneath. **Settings › General › Show selected window title** turns it off, and **Card size** picks a fixed size.
- The order follows real Command-Tab use and is frozen while the picker is open.
- No key hints are drawn on screen; Settings › Shortcuts & Help lists every key.
- Light and dark appearance, Increase Contrast, Reduce Transparency and Reduce Motion are respected.

## Window actions while switching

With ⌘ held, **W** closes the selected window, **M** minimizes it, **H** hides its app and **Q** quits its app. The picker stays open. **A** opens the selected window without its tile partner. Other keys pressed while switching never reach the app behind it. Finder is never quit.

## Tiling

Tiling works in two places.

- **Anywhere:** ⌃⌥ with the arrows tiles the frontmost window (Left, Right, Top, Bottom half). ⌃⌥Return fills its display and ⌃⌥Z undoes. The target is read when you press the keys; a sheet or dialog arranges its own window. The menu bar's **Tile Front Window** offers the same arrangements.
- **In the picker:** ⌘⌥ with the arrows tiles the selected window: Left and Right for a half, Up to fill, Down to undo. Repeating a half moves the window to the next display.

Tiling restores a minimized window and unhides a hidden app first. When nothing can be arranged (a full-screen window, Accessibility off, nothing to undo) a short note near the bottom of the display says why. A window that limits its own size keeps it and its partner takes the rest of the display.

macOS's own tiling keys (fn⌃ arrows) don't overlap. If ⌃⌥Space switches input sources on your Mac, turn off "Select next source in Input menu" in Keyboard Shortcuts › Input Sources.

## Tile pairs

Two windows in complementary halves of one display (left and right, or top and bottom) form a pair, whether Paneflo arranged them or not.

- The switcher shows a pair side by side with a link between the cards.
- Opening either window brings its partner forward too (**Settings › Tiling › Raise tile pairs together**, on by default). ⌘⌥Return in the picker or Overview always opens the pair; ⌘A in the picker, or ⌥Return in the Overview, opens the selection alone. The Overview's right-click menu has Open Pair, Open Alone and Unpair.
- **Snap assist** is a visual cue: after ⌘⌥← (or →) in the picker the selected card outlines the other half. Choose another window and press ⌘⌥→ (or ←) to place it beside the first and pair them.
- Tile a third window into a paired half and it pairs with the other half; the replaced window goes back to its previous frame when known. Tiling a paired window into its partner's half swaps them. Fill ends the pair.
- One undo restores every window an arrangement moved and re-forms the pair.
- A pair ends when a window closes, minimizes, moves to another display or leaves its half, or when you Unpair. Pairs last until Paneflo quits.

## Overview

⌃⌥Space opens a translucent overlay over your desktop with every window in a stable slot, a search field, a window count and the Desktop tile.

- **Arrows** move spatially; **search** filters while keeping slots in place; **Return** focuses (⌥Return without the tile partner); **Escape** or a click on the background closes.
- Slots never move while the Overview is open. A window that closes leaves a free slot that the next new window takes. Drag a window onto a free slot to move it, or onto another window to swap. Right-click a free slot to remove it.
- The next time the Overview opens, free slots are gone and windows keep their order. Pinned slots wait for their app ("Waiting for Mail").
- **Settings › Overview & Gesture › Keep empty places for closed windows** (Off, Until Paneflo quits, Always) keeps free slots longer. **Remove Free Slots** and **Reset Slot Order…** (asks first) are there too.

The Overview is Paneflo's own overlay. It does not modify Mission Control or native Spaces. Switching order (recent use) and Overview slot order are kept separate.

## Desktop entry

A **Desktop** card at the end of the switcher loop and a Desktop tile in the Overview reveal the desktop by hiding other apps. Apps that decline to hide stay visible, and Finder windows are not hidden. Apps hidden this way are restored on quit or next launch. Optional, in Settings › Desktop.

## Previews

With Screen Recording on, cards show cached snapshots, and the selected window gets one live preview while a surface is visible. Hidden surfaces have no live streams. Cards carry no text labels; a small symbol marks minimized, hidden, other-Space and paused previews, and VoiceOver says whether a picture is live or a snapshot and how old it is. Snapshots stay in memory and are never saved.

## Trackpad gesture

Optional and experimental, for built-in trackpads: a three-finger swipe up opens the Overview, down closes it. Turn off the three-finger **Mission Control** and **App Exposé** swipes in System Settings › Trackpad › More Gestures (or move them to four fingers); Paneflo does not change them. Then turn the gesture on in Settings › Overview & Gesture, which also shows whether a conflict remains.

## Settings

Menu bar › **Settings…** (⌘,).

| Pane | Contents |
| --- | --- |
| General | Use Paneflo shortcuts, Launch at login (off by default), Card size, Show selected window title, Show menu bar icon |
| Shortcuts & Help | Every key and gesture, grouped and searchable |
| Tiling | Raise tile pairs together, Show pairs side by side, Snap assist (all on by default) |
| Overview & Gesture | Keep empty places, Remove Free Slots, Reset Slot Order…, the gesture and its conflict status, Open Trackpad Settings… |
| Previews | Window previews and Screen Recording status |
| Desktop | The Desktop card; experimental macOS Show Desktop option |
| Permissions | Live status, Restart Paneflo, Permissions stuck? Reset and grant again…, Open Setup Guide… |
| Updates | Version, Check for updates automatically, Check Now |
| About | Version and links |

## Menu bar

The icon shows three panes. An orange dot means setup is needed; a dimmed icon means shortcuts are paused. The menu has a status line, **Finish Setup…** while needed, **Switch Windows…**, **Tile Front Window**, **Overview**, **Pause Shortcuts** / **Resume Shortcuts**, **Refresh Window List**, **Settings…**, **Check for Updates…**, **About Paneflo**, **Hide from Menu Bar** and **Quit Paneflo**.

**Hide from Menu Bar** (or turning off Show menu bar icon) asks once. Paneflo keeps running and your shortcuts and gesture keep working. Open Paneflo again from Spotlight, Launchpad or Applications to bring the icon back; Settings opens on General and says so. While setup is needed or macOS has stopped the shortcuts, the icon cannot be hidden.

## Updates and privacy

Paneflo checks GitHub for a new release once a day (Settings › Updates; **Check for Updates…** does it now) and never while the switcher or Overview is showing. Downloads are verified before they replace the app. That is Paneflo's only network use; there is no analytics or telemetry.
