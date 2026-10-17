# Paneflo

Every window. In its place.

Paneflo is a native macOS menu-bar app for finding, arranging, and switching between individual windows. Its organized overview is Paneflo's own panel; it does not modify Apple's Mission Control or control native Spaces.

## Project status

Paneflo is a native macOS developer preview with a compact window switcher, keyboard tiling, a stable organized Overview, and separate Settings. Its menu-bar item is icon-only. Preview capture and global input replacement are opt-in. Cards can use bounded static thumbnails; only the selected eligible window can have a live preview.

Source revision `83b82d3` passed 69 tests across 15 suites, release compilation, and [hosted CI](https://github.com/Jenish-Shobhit/Paneflo/actions/runs/39037675075), including capture ownership checks and app packaging. The unchanged signed app was verified and launched locally with Accessibility, Input Monitoring, and Screen Recording granted; it restored gestures and discovered 10 real windows without showing Settings. A native in-process UI check passed with synthetic 20- and 100-window snapshots, including nonempty search, Escape ownership, marked input-method composition, stale cancellation, and app-hide cleanup. Prepared Overview content made warm synthetic openings take 6–13 ms on one host. Fresh openings took 315–685 ms, chiefly during AppKit's first window activation; cold-open speed has not been resolved. Earlier physical checks covered selected-window placement/focus, Overview input, and post-wake behavior. Final-bundle physical checks of swipe dismissal, Escape, tiling, and gesture latency remain pending. See [implementation status](docs/status.md) for the evidence and remaining limits.

## Build and run

Requires macOS and Swift 6.2 or newer with the macOS SDK. The package uses a provisional macOS 14 deployment floor; that does not certify every capability on macOS 14. There are no third-party package dependencies.

```sh
./scripts/build-app.sh
open build/Paneflo.app
```

The script builds a release executable, assembles the app, and applies a local ad-hoc signature. This is not Developer ID signing or notarization. The first launch opens Settings; later launches stay quiet when permissions are ready. Explicit shortcut, preview, and gesture choices are saved and restored only when their permissions and capability checks allow it. To discover and control other windows, grant Accessibility access from Settings. Input replacement and previews have separate controls; startup does not request permissions automatically.

For a developer run and core tests:

```sh
open build/Paneflo.app --args --diagnostics
./scripts/test.sh
sh ./Tools/test-capture-ownership.sh
```

Use LaunchServices (`open`) or Finder to launch the native app. `--diagnostics` prints title-free startup phases to stderr. `build/Paneflo.app/Contents/MacOS/Paneflo --version` exits without initializing AppKit.

Build caches live under ignored `.build/`. The test script runs bundled Swift Testing and derives its framework search path from the selected Command Line Tools or Xcode installation. In an executor that blocks SwiftPM's manifest sandbox for this dependency-free package, prefix a script with `PANEFLO_SPM_DISABLE_SANDBOX=1`.

## Controls

Enable Paneflo shortcuts in Settings to replace Command–Tab behavior. macOS requires Accessibility and Input Monitoring access. Paneflo installs an event tap, then suppresses only the shortcuts it handles. It tries the HID head-insert tap and falls back to the session head-insert tap if needed. Installation does not guarantee precedence over every system or third-party handler. If macOS disables the tap, Paneflo releases it and requires the user to enable shortcuts again. Use the menu-bar **Disable global shortcuts** command to release it directly.

With shortcuts enabled:

- Hold Command and press Tab or Shift–Tab to choose a window in the compact picker. While Command remains held, Left/Right places that chosen window in the left/right half; Up fills the usable display area. Release Command to focus it after placement completes. Escape cancels selection.
- Control–Option–Space opens the larger organized Overview. Arrow keys move spatially through its stable slots; search preserves those positions. Return or a click focuses a window; Escape closes Overview.
- Control–Option–arrows tile the focused window, Control–Option–Return fills its display, and Control–Option–Z undoes the latest geometry change.

Enable previews separately and grant Screen Recording access when prompted. Static thumbnails are cached in memory with entry, byte, and age limits. Paneflo admits at most one selected-window live stream. Explicit dismissal and app hide stop capture and clear cached images. App-hide cleanup passed a synthetic own-window check; other lifecycle transitions still require validation.

The optional built-in trackpad adapter is intended to open Overview with three-finger up and dismiss it with three-finger down. It uses an unsupported macOS interface and is restricted to Apple silicon, macOS 27, and a validated framework revision. Disable conflicting native Mission Control/App Exposé swipe bindings before using it; Paneflo does not change them automatically. Sleep/session suspension permits one resume attempt after clean shutdown and matching wake events. Recognition now handles a fresh stroke after a finger-free idle, requires fresh-contact evidence after observation starts, and discards gestures delayed over 250 ms before delivery. Standalone shortcut actions queued for over 250 ms are also discarded, while switcher commit is preserved. These rules pass synthetic checks; physical down dismissal remains unverified on the final bundle.

The menu-bar **Synthetic developer fixtures** item opens the sample interface for trying the core layout and overview interactions without moving desktop windows.

For real-window integration checks, build the synthetic fixture app with `./Tools/build-fixture.sh`. Launch separate, clearly titled instances with `open -n build/PanefloFixture.app --args --label Responsive` and `open -n build/PanefloFixture.app --args --label Slow`. The default is two windows; `--count 1...20` sets the count. Its **Animate fixture** control starts a 30 fps test view only when enabled; **Pause fixture for 5 seconds** deliberately blocks only that fixture process to test unresponsive-window handling. Run `build/PanefloFixture.app/Contents/MacOS/PanefloFixture --help` for argument details.

## Specifications

- [Product scope and acceptance criteria](docs/specs/000-product.md)
- [Native architecture and engineering acceptance criteria](docs/specs/001-engineering.md)
- [Contributor workflow](AGENTS.md)
- [Implementation status and remaining gates](docs/status.md)

Private development material lives under `dev_acrtifacts/`, which is intentionally gitignored. It is not included in a fresh checkout.

## Technical direction

Swift, AppKit, and Core Animation serve the interactive path; Settings opens separately from the switching surfaces. Paneflo currently runs in one process. Supported OS versions, emergency shortcut recovery, durable window matching, the project license, and the measured resource budget remain open decisions.
