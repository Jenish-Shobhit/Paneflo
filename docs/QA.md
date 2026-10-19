# Manual QA checklist

Run this on a release build installed in `/Applications`, signed with the Paneflo Dev identity, before tagging. Record the macOS version, hardware and what was not exercised. Use scratch windows; do not record real window titles. Automated checks (`./scripts/test.sh`, CI) come first.

## Install and setup

- [ ] First launch: Open Anyway flow works; Welcome appears once.
- [ ] Accessibility and Input Monitoring rows turn green after granting; Restart Paneflo appears when needed and works.
- [ ] Screen Recording is optional: Continue unlocks without it.
- [ ] "Permissions stuck? Reset and grant again" clears only Paneflo's entries and re-guides.
- [ ] Revoking a permission while running is reported; the menu status line and badge update.

## Switcher

- [ ] ⌘Tab / ⌘⇧Tab step; release focuses; Esc cancels. Arrows choose; Up/Down move by row.
- [ ] Order matches recent use and does not change while open. Fast ⌘Tab-and-release focuses the previous window.
- [ ] Many windows (20+): grid scrolls, selection stays visible, title shown underneath.
- [ ] ⌘W, ⌘M, ⌘H, ⌘Q act on the selected window; Finder is not quit; other keys do not reach the app behind.
- [ ] Minimized, hidden, other-Space and protected windows are marked and behave honestly.
- [ ] Light, dark, Increase Contrast, Reduce Transparency, Reduce Motion.
- [ ] VoiceOver reads each card, including live/snapshot and age.

## Tiling and pairs

- [ ] ⌃⌥ arrows, ⌃⌥Return and ⌃⌥Z on the frontmost window, including a window with a sheet and a window that limits its size.
- [ ] ⌘⌥ arrows in the picker; repeating a half moves to the next display (multi-display).
- [ ] Complementary halves form a pair; side-by-side card; opening either raises both; ⌘A / ⌥Return opens alone.
- [ ] Replacing a member, swapping, Fill, Unpair, and one undo restoring everything.
- [ ] Full-screen window or Accessibility off: a clear note, no crash.

## Overview

- [ ] ⌃⌥Space opens and closes; Esc and a background click close; focus from the keyboard and mouse.
- [ ] Search keeps slots; arrows move spatially; drag swaps and moves to free slots; right-click menu.
- [ ] Closing a window leaves a free slot; reopening drops free slots; pinned slots show "Waiting for ...".
- [ ] Keep empty places: Off, Until Paneflo quits, Always. Remove Free Slots; Reset Slot Order asks first.
- [ ] Desktop tile and Desktop card hide other apps and restore them, including after quitting Paneflo.

## Gesture

- [ ] With system swipes off, three fingers up opens and down closes the Overview. With them on, Settings reports the conflict.
- [ ] Closing the lid / no built-in trackpad does not break it afterwards.

## Previews

- [ ] Screen Recording on: snapshots appear, one live preview on the selected card only; none after dismissal.
- [ ] Screen Recording off: icons, no errors.

## Menu bar and Settings

- [ ] Every menu item; Pause/Resume Shortcuts; Tile Front Window items.
- [ ] Hide from Menu Bar, relaunch from Spotlight restores the icon and shows the hint; cannot hide while setup is needed.
- [ ] Every Settings pane; Launch at login; settings persist across restart.

## Lifecycle

- [ ] Display connect/disconnect, sleep/wake, screen lock and fast user switching close surfaces cleanly.
- [ ] Input methods: Esc during composition in another app is handled as documented in [status.md](status.md).
- [ ] Update: Check for Updates from the previous release installs the new one and relaunches; permissions persist; `~/Library/Logs/Paneflo/Update.log` is clean.
- [ ] Idle: hidden Paneflo shows near-zero CPU and no live streams.
