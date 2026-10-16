# Paneflo

Every window. In its place.

Paneflo is a native macOS window-management project with three planned connected functions:

- **Switch:** replace Command–Tab with individual-window switching, immediate cached previews, and one selected live preview.
- **Arrange:** snap, resize, swap, and restore desktop window layouts with bounded undo.
- **Overview:** open an organized Mission Control-style overlay whose chosen window positions remain stable across openings.

One shared window engine connects the three modules. Recent-use switch order and persistent overview positions remain independent.

## Project status

The current milestone is a **native developer preview using synthetic windows**. A dependency-free Swift 6 package contains the pure state/geometry foundation and an AppKit menu-bar shell. The expected workflow is a preview panel on launch, with the menu-bar item reopening each mode after the panel closes. It does not inspect or control your desktop, intercept shortcuts, request permissions, or capture your screen.

Verified: 24 core tests in 6 suites, release compilation, local bundle signature verification, packaging checks, and a native GUI smoke check of all three sample modes. Search/selection, layout apply/undo, and overview reorder/pin/reopen were exercised on this Mac. No real-window or performance benchmark has been run.

Implementation will proceed in stages: reliable app startup, real-window discovery and focus, tiling, switching, organized overview, and capture, followed by correctness fixes and measured performance. Platform capability gates in the specifications continue to govern behavior and defaults.

The goal is reliable interaction with bounded resource use. Being faster or using less RAM than native macOS, AltTab, or Rectangle remains a hypothesis to benchmark, not an achieved result. The overview is a custom Paneflo surface, not a promised patch to Apple's Mission Control.

| Capability | Implemented in this milestone | Still required |
| --- | --- | --- |
| Switcher | Synthetic cards, frozen core session, local search, selection, simulated focus history | Real window discovery/focus, global Command–Tab replacement and recovery, live previews |
| Tiling | Pure layout calculation, sample destination outline, synthetic apply/20-step undo, sample display sizes | AX movement/constraints/readback, real drag snapping, multi-window actions |
| Overview | Stable in-memory sample slots, reorder/pin, search dimming, focus-history independence | Live window binding, persistent app settings, real-window actions and workspace recall |
| Resource foundation | Pure preview budget/admission contracts and deterministic tests | Real capture/cache integration, physical footprint/CPU/latency measurements |
| Native shell | Single accessory AppKit app, menu-bar controls, on-demand panel, accessible labels and local keyboard actions | Full VoiceOver/support-matrix certification and production distribution |

## Build and run

Requires macOS and a Swift 6 toolchain with the macOS SDK. The package and bundle currently use a **provisional macOS 14 deployment floor**; that is not certification that every planned capability supports macOS 14. There are no third-party package dependencies.

```sh
./scripts/build-app.sh
open build/Paneflo.app
```

The script builds a release executable, assembles `build/Paneflo.app`, and ad-hoc signs and verifies the assembled local bundle. No developer signing identity or permission setup is required for this synthetic preview. This local signature is not Developer ID distribution signing or notarization. Use `./scripts/build-app.sh debug` for a debug bundle. Quit through the Paneflo menu-bar menu.

For a developer run and core tests:

```sh
open build/Paneflo.app --args --diagnostics
./scripts/test.sh
```

Use LaunchServices (`open`) or Finder for the native app. A restricted background executor can abort in macOS application registration before Paneflo receives a launch callback; that is separate from UI construction. `--diagnostics` emits title-free startup phases to stderr, and `build/Paneflo.app/Contents/MacOS/Paneflo --version` works without a GUI session.

The scripts keep compiler caches in ignored `.build/`. The test script runs bundled Swift Testing, deriving its framework search path from the selected Command Line Tools or Xcode installation when needed; failures remain visible. With a full Xcode toolchain that resolves Testing automatically, `swift test --build-system native --enable-swift-testing --disable-xctest` is also available.

In an executor that blocks nested SwiftPM manifest sandboxing, prefix either script with `PANEFLO_SPM_DISABLE_SANDBOX=1`. This disables SwiftPM's manifest sandbox for this local dependency-free package, not the application sandbox or macOS protections. Swift 6.4 deprecates its native build backend; it is selected here for compatibility with this milestone's tested environment.

## Try the preview

- **Switch:** type an app/title query; Up/Down navigates results, Return chooses a sample, Escape closes. Left/Right edits search text. Previous/Next and card clicks also work.
- **Arrange:** choose a sample zone/display/gap, apply to the sample rectangle, then undo. No desktop window moves.
- **Overview:** move or pin a sample, change simulated focus history, then reopen. Slot order stays the same; search dims cards without repacking.

The preview uses reused AppKit card views and no timers/continuous animations. Native controls provide keyboard and accessibility behavior; a full VoiceOver audit remains a release gate. No animation means the sample also respects Reduce Motion without a parallel animation path.

## Specifications

- [Product scope and acceptance criteria](docs/specs/000-product.md)
- [Native architecture and engineering acceptance criteria](docs/specs/001-engineering.md)
- [Contributor workflow](AGENTS.md)
- [Implementation status and remaining gates](docs/status.md)

The local interactive concept, comprehensive working spec, and private development material live in **`dev_acrtifacts/`**, which is intentionally gitignored. A fresh checkout will not include them. The directory name preserves the owner's requested spelling.

## Technical direction

Swift, AppKit, and Core Animation for the input and presentation path; SwiftUI may host settings later. Begin with one process and modular subsystems. Real adapters will connect the shared event-driven window registry, bounded Accessibility work, and cost-accounted preview policy. Supported OS versions, shortcut recovery, distribution/signing model, project license, and measured total-memory budget remain open decisions.
