# Implementation status

Updated 2026-10-16. Milestone: native developer preview verified on one host.

## Available

- Dependency-free Swift 6.2+ package with a `PanefloCore` library, `Paneflo` AppKit app, and core test suite.
- Accessibility-backed discovery for regular application windows, with identity tracking across process lifetimes and off-main Accessibility calls. Discovery and window control remain unavailable until the user grants Accessibility access.
- Real-window activation and geometry placement for half-screen and maximize layouts. Native testing confirmed the left-half placement was accepted by Cocoa with focus preserved, and undo after a shrinking resize restored the exact recorded frame.
- Switcher and a custom Paneflo overview over real windows. Overview slot order, pinning, and search are separate from recent-use switch order; slot metadata is saved locally.
- Global shortcuts are opt-in. When enabled, Command–Tab cycles and selects, Control–Option–Space opens Overview, Control–Option–arrows tile, Control–Option–Return maximizes, and Control–Option–Z undoes. Installation tries the HID head-insert event tap and falls back to the session head-insert tap. No automatic retry runs if macOS disables the tap.
- The opt-in ScreenCaptureKit preview path admits at most one selected eligible window while Switcher or Overview is visible. Current-build native checks verified selected-window capture, recovery after re-enabling Screen Recording permission and restarting Paneflo, and stream shutdown with an honest paused label under memory pressure. Other cards currently show app icons and title metadata; there is no cached-thumbnail pipeline.
- `Tools/test-capture-ownership.sh` compiles the production capture source with an original synthetic 4×2 BGRA pixel-buffer harness and Address Sanitizer. It checks row stride and color interpretation, retained-provider ownership after releasing an image, the two-lease cap, rejection and re-admission, and final release to zero. It requires no app launch, permission, or capture session.
- `Tools/PanefloFixture.swift` provides labeled fixture processes, a default-off 30 fps animation workload, and a clearly labeled five-second UI-thread pause for unresponsive-window checks. The fixture acts only on its own windows; its build and output remain ignored.
- Local `.app` assembly uses an ad-hoc signature. It is not Developer ID signed or notarized.

## Validation

The latest integrated run passed **36 tests in 9 suites**. The isolated synthetic capture-ownership check passed under Address Sanitizer. Release compilation and local bundle signature verification also passed.

Earlier integrated native checks confirmed real-window discovery and activation, Cocoa-accepted left-half geometry with focus preserved, exact-frame undo after a shrinking resize, and switcher-search visibility. These geometry checks were not repeated on the final code commit. On final code commit `8c989be`, physical input testing confirmed Command–Tab opens the switcher, Shift–Tab reverses direction, releasing Command activates the selected window, and Escape cancels. Other final-build checks verified Screen Recording permission re-enable/restart recovery, stream shutdown and an honest paused label under memory pressure, and overview movement, pinning, focus, and retained slot state after reopening and searching. The registry also refreshed and activated a responsive fixture while another fixture's UI thread was paused; focus landed on the responsive fixture and the paused one resumed afterward.

Across recorded preview cycles, 19 confirmed stops returned to zero physical streams and zero retained buffer leases (peak two). A separate 60-second hidden-state check completed with no Paneflo overlay. A CUA screenshot once showed white client areas while the user confirmed the grid remained physically visible; closing and reopening the same process restored the tool image, indicating an automation capture artifact. These checks establish behavior on one host only; they do not establish shortcut precedence on every system or behavior across broader real-world apps.

The final code commit `8c989be` passed hosted GitHub Actions: 36 core tests in 9 suites, the isolated capture-ownership Address Sanitizer check, and release package/signature checks. Profiling-guided Core Animation layers avoid redrawing static preview text and borders on every frame. A short matched local run showed lower Paneflo process CPU use and physical footprint at similar frame cadence. This is one-host evidence, not a repeatable benchmark or product-superiority claim. Longer active runs and stress testing remain pending; an attempted long active sample became idle before completion and is excluded. No comparison against macOS, AltTab, or Rectangle has been completed.

## Not implemented or not verified

- Cached thumbnails for unselected windows, durable window matching across relaunches, and settings migration.
- Pointer-edge snapping and coordinated multi-window layouts.
- Native Mission Control, Spaces, or fullscreen modification. The organized overview is Paneflo's own panel.
- Shortcut precedence and immediate emergency recovery across supported macOS versions and competing input tools.
- Permission revocation, protected/minimized/unresponsive windows, screen lock and sleep transitions, multi-display recovery, and the full input-method and VoiceOver matrix.
- A supported macOS/architecture matrix, project license, distribution identity, and notarization.
- Repeatable measurements of app/system memory, CPU, energy, latency, and correctness against declared workloads.

Product acceptance criteria remain in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
