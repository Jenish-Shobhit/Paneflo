# Implementation status

Updated 2026-10-16. Milestone: native developer preview and pure Swift foundation.

## Available

- Dependency-free Swift 6 package with a `PanefloCore` library, deterministic core tests, and `Paneflo` AppKit executable.
- Value-model window/process lifetime identities, immutable snapshots, registry updates, frozen switching sessions/search, and logical overview slots independent of focus history.
- Pure layout planning and preview-work budget/admission models; these do not invoke macOS window or capture APIs.
- One menu-bar accessory app with a clearly labeled synthetic preview for switching, layout geometry, and stable overview order. Sample cards are reused and the panel has no timers or background animation.
- Local `.app` assembly through `scripts/build-app.sh`; build output and private development material remain ignored.

## Validation

Verified on the current arm64 host with Swift 6.4:

- **24 core tests in 6 suites passed** through `scripts/test.sh` with the executor's manifest-sandbox opt-in.
- Release compilation and local `.app` assembly passed after the preview constraint-order fix.
- Assembled-bundle ad-hoc signature verification passed with `codesign --verify --strict --verbose=2`.
- Mach-O arm64 output, Info.plist lint, shell syntax, and private/build artifact ignore checks passed.

**Native GUI launch and sample interaction remain unverified.** UI automation could not obtain a Paneflo app state after launch attempts. Build/signature success does not establish visible launch or interaction correctness. No real-window integration or performance benchmark has been tested.

## Not connected

Real window discovery or focus; AX geometry/control; global Command–Tab ownership; native shortcut recovery; ScreenCaptureKit or screenshots; permission onboarding; native Spaces/gestures; saved user settings; production signing/distribution. All current cards, search titles, focus changes, layouts, and display sizes are synthetic.

## Remaining gates

1. Confirm supported macOS/architecture matrix; macOS 14 is a provisional build floor only.
2. Prove real identity/discovery, newest-intent AX execution, constrained geometry readback, cross-Space capability limits, and display recovery.
3. Prove reversible shortcut ownership and immediate forced-termination/emergency recovery before replacing native shortcuts by default.
4. Integrate bounded capture with actual outstanding-request and buffer-lifetime accounting; verify permission/privacy transitions and hidden-state teardown.
5. Measure release-build latency, app/system memory, CPU, energy, and correctness against declared workloads. No performance superiority is established.
6. Complete accessibility/input-method checks, durable matching/settings migration, project license choice, and distribution/signing decisions.

A native GUI smoke check of all three synthetic modes is the immediate validation task before treating this preview as interactively verified.

Product acceptance criteria remain in [000-product.md](specs/000-product.md), with architecture/capability gates in [001-engineering.md](specs/001-engineering.md). This milestone validates contracts and native interaction scaffolding; it is not a working desktop window manager yet.
