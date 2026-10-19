# Architecture

This is a map for contributors. Intended behaviour and capability gates are in [specs/000-product.md](specs/000-product.md) and [specs/001-engineering.md](specs/001-engineering.md); the verification record is [status.md](status.md).

Paneflo is one native Swift menu-bar process. Switcher, Tiling and Overview are independent modules that share one window registry, one capture/cache budget, one shortcut router and one action executor. There are no third-party packages and no helper processes.

## Targets

| Target | Contents | Depends on |
| --- | --- | --- |
| `PanefloCore` (`Sources/PanefloCore`) | Pure, testable logic: shortcut routing (`ShortcutSession`), switcher and Desktop sessions, layout and display placement, tile pairing and undo, Overview slot store, gesture recognizer, snapshot cache and scheduler, preview policy, permission setup state, update parsing/verification/install planning | Foundation only |
| `PanefloApp` (`Sources/PanefloApp`) | AppKit/Core Animation surfaces, SwiftUI Settings and Setup, Accessibility and CoreGraphics calls, the event tap and trackpad listener, capture, updater, menu bar | `PanefloCore` |
| `Tools/` | Own-process fixtures, native UI check, benches | built by scripts, not part of the app |
| `Tests/PanefloCoreTests` | Swift Testing suites | `PanefloCore` |

Decisions live in Core as value types with explicit inputs so they can be tested without a window server; the App target performs the side effects.

## Input

`GlobalShortcutService` runs a keyboard event tap on its own thread. The handler does no scanning, capture or Accessibility work: it passes each event to `ShortcutSession` (in Core), which decides in constant time whether to consume it and which action to emit, using state prepared earlier. Actions are dispatched to the main actor. If macOS disables the tap, Paneflo re-enables it with bounded retries, keeps the saved intent, and a watchdog commits a switch session whose ⌘ release was missed. Escape is owned whenever a Paneflo surface is visible. `TrackpadGestureService` feeds `ThreeFingerSwipe`, which is gated by a contact-layout sanity check and a lifecycle gate.

## Window registry and Accessibility lanes

`WindowService` maintains a registry of windows from the window server list plus per-application Accessibility observers (run on a dedicated observer thread). Work for other apps goes through an admission coordinator (`AXWorkAdmission`) with separate lanes for interactive focus, interactive placement and background metadata: within a lane a process is serialized and coalesced, and one unresponsive app cannot stall the others. Calls have deadlines and circuit breakers. Focus raises the window first and activates the app after. Switch order (MRU) is seeded from window-server order and kept separate from Overview slot order (`OverviewSlotStore`); a switch session freezes its order.

## Capture engine and cache

`CaptureController` produces snapshots and at most one live stream, for the selected eligible window while a switching surface is visible. A byte-bounded `ThumbnailCache` (24 MiB, with pressure tiers from `PreviewPolicy`) survives dismissal and is purged on display change, lock, sleep and user switching. `SnapshotScheduler` bounds concurrent refreshes; lost callbacks release capacity after a timeout. Hidden surfaces hold zero streams. Previews are in memory only.

## Surfaces

The switcher and Overview are separate, pre-warmed non-activating panels (`SurfacePanel`, `SwitcherPanelController`, `OverviewPanelController`) built with AppKit and Core Animation. Cards are diffed rather than rebuilt (`CardGrid`, `CardView`); layout (`SwitcherLayout`, `GridNavigation`) is computed in Core. The Overview is Paneflo's own overlay and makes no claim about Mission Control or Spaces. Settings and Setup are SwiftUI windows over a shared `SettingsModel`. Surfaces close and purge on display changes, screen lock and display sleep.

## Tiling and pairs

`LayoutEngine` and `DisplayPlacement` plan an arrangement in one pass from a freshly read frame; placement is decoupled from focus. `GeometryUndo` records per-window frames so one undo restores everything an arrangement moved. `TilePairing`, `TileGroups` and `TileReplacement` detect complementary halves, replace a member in one step and swap partners; `TilePairController` applies them and keeps pairs until quit. For ⌃⌥ shortcuts the front window is resolved at keypress time (`FrontWindowResolution`).

Drag-to-edge snapping (`DragSnapService`) listens to the left button through a passive global mouse monitor, installed only while the setting is on and Accessibility is granted. `SnapDragTracker` (Core) owns the drag: the window under the press is read once from the window list on a background queue, its frame is sampled there only until it is clear the window moves (origin changed, size unchanged; a resize or a still window ignores the drag), and after that each drag event is arithmetic against cached display geometry (`SnapAreas`: outer edges only, the menu bar counts as the top, hysteresis at boundaries). A release over a zone tiles through `TilePairController` on the display under the pointer; `SnapRestoreBook` gives a tiled window its earlier size when it is dragged away.

## Updater

`UpdateController`, `UpdateNetwork` and `UpdateVerifier` check the GitHub releases feed (`ReleaseFeed`, `UpdateCheck`), download the zip, and verify size, SHA-256, bundle ID, version, code signature and signing certificate equality with the running copy before `UpdateInstall` plans a helper-driven replace and relaunch, logging to `~/Library/Logs/Paneflo/Update.log`. `UpdateNetwork.swift` is the only code that uses `URLSession`.

## Performance invariants

- The shortcut handler reads prepared state; it never scans windows, captures frames or calls Accessibility synchronously.
- Hidden surfaces cost no live streams and (near) zero main-thread work.
- At most one continuous live preview, for the selected eligible window.
- Switch order is frozen during a session and separate from slot order.
- Capture is bounded in bytes and concurrency and degrades under memory pressure.
- Every external call to another app (Accessibility, screenshots, window lists) has a deadline.
- Performance statements are only made from same-host, comparable measurements; see the benchmark section of [building.md](building.md).
