# Implementation status

Updated 2026-10-16. Milestone: native real-window integration under verification.

## Available

- Dependency-free Swift 6 package with a `PanefloCore` library, `Paneflo` AppKit app, and core test suite.
- Accessibility-backed discovery for regular application windows, with identity tracking across process lifetimes and off-main Accessibility calls. Discovery and window control remain unavailable until the user grants Accessibility access.
- Real-window activation and geometry placement for half-screen and maximize layouts, with undo history. The latest source includes a placement correction; final native geometry, focus, and undo retests on that bundle are pending.
- Switcher and a custom Paneflo overview over real windows. Overview slot order, pinning, and search are separate from recent-use switch order; slot metadata is saved locally.
- Global shortcuts are opt-in. When enabled, Command–Tab cycles and selects, Control–Option–Space opens Overview, Control–Option–arrows tile, Control–Option–Return maximizes, and Control–Option–Z undoes. Installation tries the HID head-insert event tap and falls back to the session head-insert tap. No automatic retry runs if macOS disables the tap.
- Live ScreenCaptureKit preview is opt-in and requires Screen Recording permission. At most one selected eligible window is streamed while Switcher or Overview is visible. Other cards currently show app icons and title metadata; there is no cached-thumbnail pipeline.
- Local `.app` assembly uses an ad-hoc signature. It is not Developer ID signed or notarized.

## Validation

The latest integrated run passed **33 tests in 8 suites**. Release compilation and local bundle signature verification also passed. Native regression checks on the latest bundle remain pending.

On one Mac and an earlier build, the native smoke check discovered real windows, activated a selected fixture window, changed its frame and restored it with undo, displayed a live selected-window ScreenCaptureKit frame, and installed a global event tap. The user physically confirmed that Command–Tab opened Paneflo's switching grid. These checks establish a working path on one host only; the latest bundle has not yet completed the same interaction pass. They do not establish shortcut precedence on every system, nor production recovery or compatibility.

The one local physical-memory sample is an observation from a single short run, not a repeatable benchmark. No comparison against macOS, AltTab, or Rectangle has been measured, and no performance superiority is claimed. The GitHub Actions workflow builds and tests on macOS when run; it has not yet completed a hosted CI run.

## Not implemented or not verified

- Cached thumbnails for unselected windows, durable window matching across relaunches, and settings migration.
- Pointer-edge snapping and coordinated multi-window layouts.
- Native Mission Control, Spaces, or fullscreen modification. The organized overview is Paneflo's own panel.
- Shortcut precedence and immediate emergency recovery across supported macOS versions and competing input tools.
- Permission revocation, protected/minimized/unresponsive windows, screen lock and sleep transitions, multi-display recovery, and the full input-method and VoiceOver matrix.
- A supported macOS/architecture matrix, project license, distribution identity, and notarization.
- Repeatable measurements of app/system memory, CPU, energy, latency, and correctness against declared workloads.

Product acceptance criteria remain in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
