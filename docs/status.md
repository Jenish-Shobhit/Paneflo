# Implementation status

Updated 2026-10-17. Core workflow verified on one host; three-finger down dismissal remains unresolved.

## Available

- One native Swift 6.2+ menu-bar app with a compact Command–Tab window picker, separate Settings, keyboard tiling, and a larger organized Overview.
- Accessibility-backed window discovery, identity validation, focus, half-screen/fill placement, and geometry undo. Remote window control requires Accessibility access.
- In the picker, Command–Left/Right places the chosen window in a half and Command–Up fills the display. Releasing Command waits for placement before focusing that selection; Escape cancels deferred focus.
- Stable Overview slots, pinning, spatial arrow selection, and in-place search, independent of recent-use switch order. Slot metadata is saved locally.
- Explicit shortcut, preview, and gesture enable choices are saved. Configured startup stays quiet when permissions are ready; first launch or missing permissions opens Settings without automatic permission prompts.
- Opt-in global shortcut replacement with HID-first/session fallback and explicit failure recovery. Installation does not certify precedence over every competing input handler.
- Opt-in previews with at most one selected live stream and bounded static thumbnails: at most 12 entries/6 MiB, 30-second expiry, and one outstanding snapshot request. Explicit dismissal invalidates work and purges images.
- An optional native built-in trackpad adapter, gated to Apple silicon/macOS 27 and a validated framework revision. It uses an unsupported interface and requires conflicting native swipe bindings to be disabled separately. Lifecycle suspension preserves enable intent and permits one restart after all wake reasons clear and physical shutdown succeeds; failure clears intent.

## Validation

Current source `0c80b6e` passed **63 tests in 14 suites**, release compilation, and [hosted CI](https://github.com/Jenish-Shobhit/Paneflo/actions/runs/39014695313), including synthetic capture-ownership Address Sanitizer and package checks. The latest idle-recognition correction is covered by a regression test but has not yet had native acceptance testing.

Native evidence combines `af31070` Overview focus/arrows/Escape/wake checks with preceding-build physical switching/tiling and saved-control checks on unchanged paths. The physical Command–Tab check confirmed Command–Left/Right/Up placement and release-to-focus on the same selected window; it was not repeated on `af31070`, whose native diagnostics showed healthy placement/focus. On `af31070`, two swipe-up/Escape regressions closed Overview, restored the previous application, and did not leak Escape. Up/arrows/Escape also passed after sleep/wake/unlock. The reported Escape failure is resolved on this host.

Native checks rendered upright selected-live and unselected-static previews and confirmed preview/cache release after explicit dismissal. All three saved enable controls were checked in Settings on the preceding build; `af31070` showed quiet startup, restored gesture operation, and capture, without a repeat of that three-checkbox UI check. Normal two-finger scrolling remained usable.

Three-finger down dismissal is a reported failure under investigation. The idle-recognition correction in current source has not yet established a native fix. In-place search/Return confirmation remains pending. Results apply to one host and do not certify broader OS, hardware, or lifecycle behavior.

## Remaining limits

- Native acceptance of corrected down dismissal, in-place search/Return, and broader gesture/lifecycle cases.
- Native app-hide capture cleanup, permission revocation, protected/minimized windows, cache stress, multi-display recovery, input methods, and VoiceOver coverage.
- Durable window matching across relaunches and settings migration.
- Pointer-edge snapping, coordinated multi-window layouts, native Spaces/fullscreen modification, and Mission Control internals.
- Shortcut precedence and immediate emergency recovery across supported systems and competing tools.
- A supported OS/architecture matrix, project license, distribution identity, and notarization. Local app assembly uses an ad-hoc signature.
- Repeatable app/system memory, CPU, energy, latency, and correctness measurements. No comparative performance claim is established.

Product acceptance criteria are in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
