# Paneflo

Every window. In its place.

Paneflo is a native macOS menu-bar app for finding, arranging, and switching between individual windows. Its organized overview is Paneflo's own panel; it does not modify Apple's Mission Control or control native Spaces.

## Project status

Paneflo is a native macOS developer preview for discovering and activating real windows, tiling with undo, switching, and arranging entries in its own overview. Global shortcuts and selected-window ScreenCaptureKit previews are opt-in. Paneflo does not alter Mission Control or native Spaces; unselected cards currently use app icons and title metadata, with cached thumbnails still unimplemented. See [implementation status](docs/status.md) for verified behavior, validation results, and remaining work.

Final code commit `8c989be` passed hosted CI with 36 core tests across 9 suites, the synthetic capture-ownership Address Sanitizer check, and release package/signature checks. This is a developer preview tested on one Mac, not a supported-system certification or product-superiority claim.

## Build and run

Requires macOS and Swift 6.2 or newer with the macOS SDK. The package uses a provisional macOS 14 deployment floor; that does not certify every capability on macOS 14. There are no third-party package dependencies.

```sh
./scripts/build-app.sh
open build/Paneflo.app
```

The script builds a release executable, assembles the app, and applies a local ad-hoc signature. This is not Developer ID signing or notarization. No permission is requested on launch. To discover and control other windows, grant Accessibility access from Paneflo's panel. Shortcuts and live capture each have separate controls and request their needed permissions only when enabled.

For a developer run and core tests:

```sh
open build/Paneflo.app --args --diagnostics
./scripts/test.sh
sh ./Tools/test-capture-ownership.sh
```

Use LaunchServices (`open`) or Finder to launch the native app. `--diagnostics` prints title-free startup phases to stderr. `build/Paneflo.app/Contents/MacOS/Paneflo --version` exits without initializing AppKit.

Build caches live under ignored `.build/`. The test script runs bundled Swift Testing and derives its framework search path from the selected Command Line Tools or Xcode installation. In an executor that blocks SwiftPM's manifest sandbox for this dependency-free package, prefix a script with `PANEFLO_SPM_DISABLE_SANDBOX=1`.

## Controls

Enable Paneflo shortcuts in the app panel to replace Command–Tab behavior for that running session. macOS requires Accessibility and Input Monitoring access. Paneflo installs an event tap, then suppresses only the shortcuts it handles. It tries the HID head-insert tap and falls back to the session head-insert tap if needed. Installation does not guarantee precedence over every system or third-party handler. If macOS disables the tap, Paneflo releases it and requires the user to enable shortcuts again. Use the menu-bar **Disable global shortcuts** command to release it directly.

With shortcuts enabled, Command–Tab and Command–Shift–Tab cycle windows; release Command to activate the selected window. Control–Option–Space opens the organized overview. Control–Option–Arrow keys tile the focused window to a half, Control–Option–Return maximizes it, and Control–Option–Z undoes the latest geometry change.

Enable live previews separately and grant Screen Recording access when prompted. Paneflo requests one selected-window stream while Switcher or Overview is visible. Tiling and hidden surfaces do not keep a live preview running.

The menu-bar **Synthetic developer fixtures** item opens the sample interface for trying the core layout and overview interactions without moving desktop windows.

For real-window integration checks, build the synthetic fixture app with `./Tools/build-fixture.sh`. Launch separate, clearly titled instances with `open -n build/PanefloFixture.app --args --label Responsive` and `open -n build/PanefloFixture.app --args --label Slow`. The default is two windows; `--count 1...20` sets the count. Its **Animate fixture** control starts a 30 fps test view only when enabled; **Pause fixture for 5 seconds** deliberately blocks only that fixture process to test unresponsive-window handling. Run `build/PanefloFixture.app/Contents/MacOS/PanefloFixture --help` for argument details.

## Specifications

- [Product scope and acceptance criteria](docs/specs/000-product.md)
- [Native architecture and engineering acceptance criteria](docs/specs/001-engineering.md)
- [Contributor workflow](AGENTS.md)
- [Implementation status and remaining gates](docs/status.md)

Private development material lives under `dev_acrtifacts/`, which is intentionally gitignored. It is not included in a fresh checkout.

## Technical direction

Swift, AppKit, and Core Animation serve the interactive path; SwiftUI may host settings later. Paneflo currently runs in one process. Supported OS versions, emergency shortcut recovery, durable window matching, the project license, and the measured resource budget remain open decisions.
