# Paneflo

Every window. In its place.

Paneflo is a native macOS menu-bar app for finding, arranging, and switching between individual windows. Its organized overview is Paneflo's own panel; it does not modify Apple's Mission Control or control native Spaces.

## Project status

The current developer build works with real application windows. Accessibility-backed discovery, window activation, tiling, the organized overview, and opt-in global shortcuts are implemented. Native testing verified Cocoa-accepted left-half placement with focus preserved and exact-frame undo after a shrinking resize. The selected-window ScreenCaptureKit path is implemented, but capture has not been reverified on the current source hash. All permissions are user initiated. Other window cards currently show app icons and title metadata; Paneflo does not yet provide cached thumbnails.

On an earlier build, a native smoke check found real windows, activated a selected fixture window, applied a layout and undid it, displayed a selected-window frame from ScreenCaptureKit, and opened Paneflo's grid through Command–Tab with shortcuts enabled. On the current bundle, native testing confirms the left-half placement is accepted by Cocoa with focus preserved, shrinking-resize undo restores the exact recorded frame, switcher search displays and reveals the matching card, and the registry continues refreshing and can activate a responsive window while a separate fixture is unresponsive. Live capture has not been rechecked on this hash. These checks cover one Mac, not the supported macOS matrix or broader real-world app behavior.

| Capability | Current behavior | Remaining work |
| --- | --- | --- |
| Switcher | Lists real windows by app and title; supports pointer/keyboard selection and activation. Command–Tab replacement is available only after explicit shortcut enablement. | Verify shortcut precedence and recovery across supported systems; finish input-method and accessibility coverage. |
| Tiling | Applies half-screen and maximize layouts to a real window through Accessibility. Latest left-half geometry, focus, and exact-frame undo after shrinking resize were confirmed natively. | Test constrained-window readback, more displays, and broader app behavior. Pointer-edge snapping and multi-window arrangements are not implemented. |
| Overview | Paneflo's own overlay lists real windows; users can reorder, pin, search, and activate entries. Slot order is saved separately from recent-use switch order. | Validate long-term matching, settings migration, display and Space transitions. This does not rearrange Apple's Mission Control. |
| Live preview | The opt-in ScreenCaptureKit path admits one selected eligible window while a switching surface is visible; other cards use icons and titles. A capture frame was shown on an earlier build. | Recheck capture on the current source hash; add cached thumbnails and complete permission-revocation, teardown, privacy, and workload validation. |

The latest integrated run passed 36 core tests across 9 suites. Release compilation and local bundle signature verification passed. Current-hash capture validation and repeatable performance measurements remain pending. No performance benchmark or comparison has established lower memory, lower latency, or superiority over macOS, AltTab, or Rectangle.

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
