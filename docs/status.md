# Implementation status

Updated 2026-10-17. Milestone: compact workflow implemented; redesigned native QA in progress.

## Available

- Dependency-free Swift 6.2+ package with a `PanefloCore` library, `Paneflo` AppKit app, and core test suite.
- Accessibility-backed discovery for regular application windows, with identity tracking across process lifetimes and off-main Accessibility calls. Discovery and window control remain unavailable until the user grants Accessibility access.
- Real-window activation, half-screen/fill placement, and geometry undo.
- A compact Command–Tab window picker, separate Settings, and a larger organized Overview. With the picker active, Command–Left/Right places the selected window in a half and Command–Up fills the display; releasing Command waits for placement before focusing that selection.
- Overview slot order, pinning, and in-place search remain separate from recent-use switch order; slot metadata is saved locally. Arrow navigation follows the visible grid.
- Explicit shortcut, preview, and native-gesture choices are saved. Startup restores eligible choices without requesting permissions and opens Settings on first launch or when required permissions are missing.
- Global shortcuts are opt-in. When enabled, Command–Tab cycles and selects, Control–Option–Space opens Overview, Control–Option–arrows tile, Control–Option–Return maximizes, and Control–Option–Z undoes. Installation tries the HID head-insert event tap and falls back to the session head-insert tap. No automatic retry runs if macOS disables the tap.
- Opt-in previews combine bounded static thumbnails with at most one selected eligible live stream. The static cache admits at most 12 entries and 6 MiB, with 30-second expiry and one outstanding snapshot request. Explicit dismissal invalidates capture work and purges images. Initial native checks confirmed upright static and selected-live content; app-hide, broader lifecycle/privacy transitions, and cache stress checks remain pending.
- An optional native three-finger adapter for the default built-in trackpad. Up opens Overview; down dismisses it. Its unsupported interface is gated to Apple silicon, macOS 27, and a validated framework revision. Conflicting native Mission Control/App Exposé bindings must be disabled separately. Sleep/display/session suspension preserves enable intent and permits one restart only after every corresponding wake and clean physical shutdown; failures clear enable intent. Physical up/down behavior and normal two-finger scrolling passed on one host; sleep/wake and broader gesture edge cases remain pending.
- `Tools/test-capture-ownership.sh` compiles the production capture source with an original synthetic 4×2 BGRA pixel-buffer harness and Address Sanitizer. It checks row stride and color interpretation, retained-provider ownership after releasing an image, the two-lease cap, rejection and re-admission, and final release to zero. It requires no app launch, permission, or capture session.
- `Tools/PanefloFixture.swift` provides labeled fixture processes, a default-off 30 fps animation workload, and a clearly labeled five-second UI-thread pause for unresponsive-window checks. The fixture acts only on its own windows; its build and output remain ignored.
- Local `.app` assembly uses an ad-hoc signature. It is not Developer ID signed or notarized.

## Validation

Commit `ec757b3` passed **61 tests in 14 suites**, release compilation, local bundle signature verification, and [hosted CI](https://github.com/Jenish-Shobhit/Paneflo/actions/runs/38977719155). Tests cover selected-window placement/release ordering, thumbnail admission and stale work, coherent three-finger gestures, and overlapping lifecycle suspension.

One-host native checks confirmed the compact picker, upright selected-live and unselected-static previews, selected-window half placement, and exact-target focus through selection and search. With global HID shortcuts enabled, native diagnostics also recorded left/right/fill placement and exact-target activation. Explicit user confirmation of the physical Command–Tab placement/release workflow is still pending. Dismissal cleared the overlay, purged cached images, and confirmed live-stream/buffer release.

The user physically confirmed three-finger up opens the organized board, three-finger down dismisses it, and normal two-finger scrolling still works on this host. Spatial Overview navigation, sleep/wake resume, saved shortcut/preview restoration, broader gesture edge cases, and capture/privacy checks including native app hide remain pending. Current results do not establish the cause of an earlier reported failure or certify other systems. A normal relaunch of the unchanged build opened no Settings window or permission prompts and restored the saved gesture to active; saved shortcut and preview restoration still need direct confirmation.

A 30-second fresh-launch sample with overlays closed and the gesture adapter active recorded about 24 MiB physical footprint and 0.002% of one CPU core. This is one idle observation on one host; it does not measure active capture or establish comparative performance.

Earlier baseline testing physically confirmed forward/reverse Command–Tab, release-to-focus, and Escape cancellation. It also checked geometry undo, permission re-enable/restart, memory-pressure preview shutdown, stable overview slots, and progress while another application was unresponsive. Those checks support the foundation; they do not substitute for validation of the redesigned workflow. No repeatable performance comparison or product-superiority claim has been established.

## Not implemented or not verified

- Broader thumbnail/cache validation, saved shortcut/preview restoration, and remaining redesigned interactions; durable window matching across relaunches and settings migration.
- Pointer-edge snapping and coordinated multi-window layouts.
- Native Mission Control, Spaces, or fullscreen modification. The organized Overview is Paneflo's own panel; the optional gesture adapter observes trackpad input and does not modify Mission Control.
- Shortcut precedence and immediate emergency recovery across supported macOS versions and competing input tools.
- Permission revocation, protected/minimized/unresponsive windows, screen lock and sleep transitions, multi-display recovery, and the full input-method and VoiceOver matrix.
- A supported macOS/architecture matrix, project license, distribution identity, and notarization.
- Repeatable measurements of app/system memory, CPU, energy, latency, and correctness against declared workloads.

Product acceptance criteria remain in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
