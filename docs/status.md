# Implementation status

Updated for 1.2.1, released 2026-10-19. Automated checks pass; hands-on acceptance of the final bundle is pending.

## 1.2.1

- Fixes to custom tiling shortcuts (Home, End, Page Up/Down, Forward Delete, Enter, number pad, ⌥-only refusal) and to how tiling shortcuts mark cards while the switcher or Overview is open.
- Snap areas: quick flicks to an edge, a pointer parked at an edge, and lock, sleep or user switch during a drag now behave correctly; the outline tracks the current zone.
- Details in [CHANGELOG.md](../CHANGELOG.md).

## 1.2.0

- Snap areas: drag a window by its title bar to the top edge to fill, to the left or right edge for that half, or into a corner for a quarter. A translucent outline shows the landing zone; release to place it. On by default.
- Custom tiling shortcuts: Settings › Tiling › Keyboard Shortcuts records a shortcut for each arrangement. Defaults stay ⌃⌥ with the arrows, Return and Z.
- Details in [CHANGELOG.md](../CHANGELOG.md) and [user-guide.md](user-guide.md).

## 1.1.0

- Liquid Glass switcher without on-card labels, card sizes, full-display Overview with collapsing free slots (Settings: Keep empty places Off / Until Paneflo quits / Always).
- Tile pairs: snap assist, open pair / open alone, automatic re-pairing when a member is replaced, one-step undo.
- Front-window tiling with ⌃⌥ arrows anywhere (target read at keypress time) and a Tile Front Window menu.
- Settings window with sidebar, four-step setup, Hide from Menu Bar. Details in [CHANGELOG.md](../CHANGELOG.md).

## Done (1.0 milestones)

Milestone numbers follow the order the work landed.

- **0.1 Build and updates** (`544385b`, `be731b0`, `4ac076a`, `9897a99`, merge `f9ebc75`): MIT license, macOS 26 / Apple silicon floor, `scripts/build.sh` (sign, install, zip), `scripts/release.sh`; Check for Updates… with verified download, install and relaunch; daily automatic check; GitHub Pages download site.
- **0.2 Input and surfaces** (`b4ef8d3`, `e092c58`, `41ae863`, `f3a46ad`): Escape owned whenever a Paneflo surface is visible; event tap on its own thread with bounded re-enable; separate pre-warmed picker and Overview panels, card diffing, non-activating Overview.
- **0.3 Window correctness** (`f147d76`, `3c4196b`, merge `428cb0e`): Command-Tab MRU seeded from window-server order, raise-before-activate focus, per-window Accessibility notifications, window numbers by direct lookup, separate Accessibility lanes for focus and placement.
- **0.4 Previews** (`3ffdf47`, `bb8948b`, `03f1907`, `1d83d90`, merge `7b659cb`): byte-bounded snapshot cache (24 MiB) that survives dismissal, up to three concurrent refreshes, one debounced live stream for the selected window, pressure tiers, deadlines and circuit breakers for discovery, screenshots and stream start, honest card labels.
- **0.5 Gesture** (`ae95f54`, merge `4824c45`): centroid-based three-finger recognizer, runtime contact-layout sanity check, Settings guidance about conflicting system swipes; gated to Apple silicon on macOS 26 or later.
- **0.6 Tiling** (`9b528e3`, merge `ab0a25d`): placement in one pass planned from a fresh frame, focus decoupled from placement, per-window undo, repeat-to-next-display, display-aware zones.
- **0.7 Desktop entry and lifecycle** (`53ff066`, `005e342`, `d17cd0b`): Desktop card in the loop and Overview home tile (Show Desktop by hiding apps; wallpaper image, never captured); surfaces open on the pointer's display; display change, screen lock, display sleep and user switching close surfaces and purge snapshots.
- **0.8 Hardening** (`5d15db4`, `74a2a6b`, `8dd13fe`, `5b94bd8`, `624020a`, `7b13253`, `d683dd8`, merge `2fa87c8`): ⌘W/⌘M/⌘H/⌘Q act on the selected window while switching and other keys are swallowed; Desktop-hidden apps journaled and restored on quit or next launch (one restore path); interrupted shortcut tap keeps the saved intent with bounded automatic retry; missed-⌘-release watchdog; lost screenshot and discovery callbacks release capacity after 30 s; bounded trackpad re-probe; unreadable Overview slot data backed up; deterministic timing tests.

## Verification

- `./scripts/test.sh` for 1.1.0: **405 tests in 61 suites passed**; CI (macOS build and tests) is green on the 1.1.0 line and sanitizer runs were clean earlier in the cycle. Coverage includes shortcut routing, switcher and Desktop sessions, layout and display placement, gesture recognition (synthetic replays), snapshot cache and scheduler, window matching, update parsing, verification and install planning.
- Own-process tools (`Tools/`): a native UI check with synthetic windows, including setup, Settings, menu and tile-pair surfaces (search, Escape ownership, input-method composition, stale cancellation, Desktop card, display and lock notifications, app-hide cleanup), a capture-ownership check, and surface, tiling and capture benches against Paneflo's own fixture windows.
- Synthetic own-process measurements on one host (Mac14,2, M2, 8 GB, macOS 27.0.1) using Paneflo's own fixture windows and synthetic cards. They are not comparative, say nothing about any other product, and are not physical footprint, total system memory or swipe latency.
  - Surface bench (20 / 60 synthetic cards, medians): warm Command-Tab present call about 4.5 ms / 7.6 ms with cached snapshots on every card; Tab step call about 0.4 ms; first Overview open call 63 ms median at 20 cards (15–30 ms on quiet launches, up to about 300 ms when the host was under memory pressure); Overview arrow step about 0.1 ms.
  - Tiling (fixture windows): tile request to final frame 8–11 ms; releasing Command to focus with a pending tile 12–13 ms. Focus on a fixture window: 11–18 ms.
  - Previews (6 fixture windows, pre-warmed): first snapshot 155 ms, all cards 347 ms, selected card live 186–216 ms; cached snapshots on reopen delivered within the open call; dismissal to zero live streams 25–33 ms.
- Earlier hands-on checks on one host covered selected-window placement and release-to-focus, Overview input and post-sleep/wake behavior. They do not carry over to the final bundle.

## Pending

- Owner hands-on acceptance of the final 1.2.1 bundle, including Stage Manager and windows on other Spaces (not yet exercised by hand): three-finger up and down, Escape across input contexts, tiling (including across displays), snap areas on real windows, custom tiling shortcuts, search and Return, previews on real windows, Desktop entry.
- Break-testing: permission revocation, protected and minimized windows, cache stress, multi-display recovery, input methods, VoiceOver.
- Repeatable memory, CPU, energy and latency measurements, including against other tools. No comparative performance claim is made until those exist.

## Known limits

- Windows on other Spaces and full-screen windows are not reliably discovered or focused; Paneflo does not modify native Spaces or Mission Control.
- Show Desktop hides apps; Finder windows are not hidden. Apps that decline to hide stay visible.
- The gesture uses an unsupported macOS interface, so a system update can break it. The system three-finger Mission Control / App Exposé swipes must be turned off separately. It is a built-in-trackpad feature only.
- Not notarized: first launch needs Open Anyway. Locally built copies signed ad hoc cannot verify updates and lose permissions on rebuild.
- Shortcut precedence over other tools that also hook ⌘Tab is not guaranteed; Pause Shortcuts in the menu bar menu is the recovery path.
- While a Paneflo surface is visible and another app has keyboard focus, an Escape meant to end input-method composition in that app is taken by Paneflo.
- Snap areas: a window already flush under the menu bar, dragged perfectly straight up, can't move, so it isn't recognized as a drag and doesn't fill. Any sideways motion works.
- Snap areas: for windows that limit their own size, the outline shows the nominal zone, not the size the window will land at.
- Snap areas: macOS's own edge tiling, if turned on, also acts on the drag.
- Window matching does not yet survive app relaunches. Multi-window layouts are out of scope.
- Results apply to the hosts tested; the supported matrix is macOS 26+ on Apple silicon.

Product acceptance criteria are in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
