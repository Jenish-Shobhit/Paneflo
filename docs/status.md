# Implementation status

Updated 2026-10-16. Milestone: native real-window integration under verification.

## Available

- Dependency-free Swift 6.2+ package with a `PanefloCore` library, `Paneflo` AppKit app, and core test suite.
- Accessibility-backed discovery for regular application windows, with identity tracking across process lifetimes and off-main Accessibility calls. Discovery and window control remain unavailable until the user grants Accessibility access.
- Real-window activation and geometry placement for half-screen and maximize layouts. Native testing confirmed the left-half placement was accepted by Cocoa with focus preserved, and undo after a shrinking resize restored the exact recorded frame.
- Switcher and a custom Paneflo overview over real windows. Overview slot order, pinning, and search are separate from recent-use switch order; slot metadata is saved locally.
- Global shortcuts are opt-in. When enabled, Command–Tab cycles and selects, Control–Option–Space opens Overview, Control–Option–arrows tile, Control–Option–Return maximizes, and Control–Option–Z undoes. Installation tries the HID head-insert event tap and falls back to the session head-insert tap. No automatic retry runs if macOS disables the tap.
- The opt-in ScreenCaptureKit preview path admits at most one selected eligible window while Switcher or Overview is visible. A selected capture frame was shown on an earlier build but has not been reverified on the current source hash. Other cards currently show app icons and title metadata; there is no cached-thumbnail pipeline.
- `Tools/PanefloFixture.swift` provides labeled fixture processes, a default-off 30 fps animation workload, and a clearly labeled five-second UI-thread pause for unresponsive-window checks. The fixture acts only on its own windows; its build and output remain ignored.
- Local `.app` assembly uses an ad-hoc signature. It is not Developer ID signed or notarized.

## Validation

The latest integrated run passed **36 tests in 9 suites**. Release compilation and local bundle signature verification also passed.

On an earlier build, a native smoke check discovered real windows, activated a selected fixture window, changed and restored its frame with tiling and undo, displayed a selected-window ScreenCaptureKit frame, and installed a global event tap. The user physically confirmed that Command–Tab opened Paneflo's switching grid. On the latest bundle, native checks confirmed Cocoa-accepted left-half geometry with focus preserved, exact-frame undo after a shrinking resize, and that switcher search displayed and revealed its matching card. In a separate fixture test, Paneflo continued refreshing its window registry and activated a responsive fixture window while another fixture's UI thread was paused; focus was confirmed on the responsive window, and the paused fixture resumed afterward. Capture has not been rechecked on this source hash. These checks establish behavior on one host only; they do not establish shortcut precedence on every system, production recovery, or behavior across broader real-world apps.

Current-hash capture validation remains pending. No repeatable performance benchmark or comparison against macOS, AltTab, or Rectangle has been completed. A hosted GitHub Actions run passed after the Swift 6.2+ toolchain selection fix; the latest source changes still need a hosted run after commit.

## Not implemented or not verified

- Cached thumbnails for unselected windows, durable window matching across relaunches, and settings migration.
- Pointer-edge snapping and coordinated multi-window layouts.
- Native Mission Control, Spaces, or fullscreen modification. The organized overview is Paneflo's own panel.
- Shortcut precedence and immediate emergency recovery across supported macOS versions and competing input tools.
- Permission revocation, protected/minimized/unresponsive windows, screen lock and sleep transitions, multi-display recovery, and the full input-method and VoiceOver matrix.
- A supported macOS/architecture matrix, project license, distribution identity, and notarization.
- Repeatable measurements of app/system memory, CPU, energy, latency, and correctness against declared workloads.

Product acceptance criteria remain in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
