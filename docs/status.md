# Implementation status

Updated 2026-10-18 (source at `d337ed9`, 1.0.0 release candidate in preparation). Automated checks pass; the owner's hands-on acceptance on the final bundle is pending.

## Done

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

- `./scripts/test.sh` at `2fa87c8`: **261 tests in 43 suites passed** (10 consecutive runs of the 0.8 branch passed), covering shortcut routing, switcher and Desktop sessions, layout and display placement, gesture recognition (synthetic replays), snapshot cache and scheduler, window matching, update parsing, verification and install planning.
- Own-process tools (`Tools/`): a native UI check with synthetic windows (search, Escape ownership, input-method composition, stale cancellation, Desktop card, display and lock notifications, app-hide cleanup), a capture-ownership check, and surface, tiling and capture benches against Paneflo's own fixture windows.
- Synthetic own-process measurements on one host (Mac14,2, M2, 8 GB, macOS 27.0.1) using Paneflo's own fixture windows and synthetic cards. They are not comparative, say nothing about any other product, and are not physical footprint, total system memory or swipe latency.
  - Surface bench (20 / 60 synthetic cards, medians): warm Command-Tab present call about 4.5 ms / 7.6 ms with cached snapshots on every card; Tab step call about 0.4 ms; first Overview open call 63 ms median at 20 cards (15–30 ms on quiet launches, up to about 300 ms when the host was under memory pressure); Overview arrow step about 0.1 ms.
  - Tiling (fixture windows): tile request to final frame 8–11 ms; releasing Command to focus with a pending tile 12–13 ms. Focus on a fixture window: 11–18 ms.
  - Previews (6 fixture windows, pre-warmed): first snapshot 155 ms, all cards 347 ms, selected card live 186–216 ms; cached snapshots on reopen delivered within the open call; dismissal to zero live streams 25–33 ms.
- Earlier hands-on checks on one host covered selected-window placement and release-to-focus, Overview input and post-sleep/wake behavior. They do not carry over to the final bundle.

## Pending

- Owner hands-on acceptance of the final bundle: three-finger up and down, Escape across input contexts, tiling (including across displays), search and Return, previews on real windows, Desktop entry.
- Break-testing: permission revocation, protected and minimized windows, cache stress, multi-display recovery, input methods, VoiceOver.
- Repeatable memory, CPU, energy and latency measurements, including against other tools. No comparative performance claim is made until those exist.

## Known limits

- Windows on other Spaces and full-screen windows are not reliably discovered or focused; Paneflo does not modify native Spaces or Mission Control.
- Show Desktop hides apps; Finder windows are not hidden. Apps that decline to hide stay visible.
- The gesture uses an unsupported macOS interface, so a system update can break it. The system three-finger Mission Control / App Exposé swipes must be turned off separately. It is a built-in-trackpad feature only.
- Not notarized: first launch needs Open Anyway. Locally built copies signed ad hoc cannot verify updates and lose permissions on rebuild.
- Shortcut precedence over other tools that also hook ⌘Tab is not guaranteed; Pause Shortcuts in the menu bar menu is the recovery path.
- While a Paneflo surface is visible and another app has keyboard focus, an Escape meant to end input-method composition in that app is taken by Paneflo.
- Window matching does not yet survive app relaunches. Pointer-edge snapping and multi-window layouts are out of scope.
- Results apply to the hosts tested; the supported matrix is macOS 26+ on Apple silicon.

Product acceptance criteria are in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
