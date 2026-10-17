# Implementation status

Updated 2026-10-17. Source checks, signed-app launch, and local permission verification pass; final-bundle physical input acceptance remains pending.

## Available

- One native Swift 6.2+ menu-bar app with an icon-only menu item, compact Command–Tab window picker, separate Settings, keyboard tiling, and a larger organized Overview.
- Accessibility-backed window discovery, identity validation, focus, half-screen/fill placement, and geometry undo. Remote window control requires Accessibility access.
- In the picker, Command–Left/Right places the chosen window in a half and Command–Up fills the display. Releasing Command waits for placement before focusing that selection; Escape cancels deferred focus.
- Stable Overview slots, pinning, spatial arrow selection, and in-place search, independent of recent-use switch order. Slot metadata is saved locally. Hidden Overview content can be prepared for reopening.
- Explicit shortcut, preview, and gesture enable choices are saved. Configured startup stays quiet when permissions are ready; first launch or missing permissions opens Settings without automatic permission prompts.
- Opt-in global shortcut replacement with HID-first/session fallback and explicit failure recovery. Standalone tile, restore, and Overview actions queued for over 250 ms expire; switcher commit remains paired with its session. Installation does not certify precedence over every competing input handler.
- Opt-in previews with at most one selected live stream and bounded static thumbnails: at most 12 entries/6 MiB, 30-second expiry, and one outstanding snapshot request. Explicit dismissal and app hide invalidate work and purge images.
- An optional native built-in trackpad adapter, gated to Apple silicon/macOS 27 and a validated framework revision. It uses an unsupported interface and requires conflicting native swipe bindings to be disabled separately. Lifecycle suspension preserves enable intent and permits one restart after all wake reasons clear and physical shutdown succeeds; failure clears intent. The recognizer handles finger-free idle gaps, requires fresh-contact evidence on a new observation, and drops gestures queued over 250 ms.

## Validation

Source revision `83b82d3` passed **69 tests in 15 suites** and release compilation. [Hosted CI](https://github.com/Jenish-Shobhit/Paneflo/actions/runs/39037675075) passed the same source with core tests, capture-ownership Address Sanitizer checks, and app packaging/signing. The ad-hoc signed app was also signature-verified and launched locally. A native in-process UI check passed with synthetic 20- and 100-window snapshots. It exercised nonempty Overview queries and Escape, first Escape during marked input-method composition followed by closure on the next press, rapid presentation with stale cancellation, and expiry of one-second-old standalone tile/restore/Overview actions while preserving switcher commit. Native app hide cleared an injected synthetic image and signaled capture and keyboard ownership as inactive. Local capture-ownership checks finished with zero live leases under a two-lease cap. The fresh-contact, idle-gap, and 250 ms gesture delivery rules have synthetic regression coverage.

In the synthetic own-window check on one host, warm Overview openings took 6–13 ms with prepared content. Fresh first openings took 315–685 ms, chiefly at AppKit's first `makeKeyAndOrderFront` (about 200–670 ms). This does not measure native swipe latency or establish a cold-open fix.

Earlier host checks confirmed Command–Left/Right/Up placement and release-to-focus on the selected window. A later build passed two swipe-up/Escape regressions and post-sleep/wake/unlock Up, arrow, and Escape checks. Those results do not establish that Escape is resolved globally or on the final bundle.

Earlier native checks rendered upright selected-live and unselected-static previews and confirmed preview/cache release after explicit dismissal. All three saved enable controls were checked in Settings on a preceding build. Normal two-finger scrolling remained usable.

Three-finger down dismissal is a reported failure under investigation. The current recognizer changes have not yet established a physical fix. The unchanged packaged app now has verified Accessibility, Input Monitoring, and Screen Recording grants on this host; it launched without Settings, reported active gestures, and discovered 10 real windows. Physical swipe, Escape, tiling, and search/Return acceptance on this bundle remains pending. Results apply to one host and do not certify broader OS, hardware, or lifecycle behavior.

## Remaining limits

- Final-bundle physical acceptance of down dismissal, Escape across input contexts, in-place search/Return, and broader gesture/lifecycle cases.
- Final-bundle app-hide capture cleanup, permission revocation, protected/minimized windows, cache stress, multi-display recovery, broader input-method behavior, and VoiceOver coverage.
- Durable window matching across relaunches and settings migration.
- Pointer-edge snapping, coordinated multi-window layouts, native Spaces/fullscreen modification, and Mission Control internals.
- Shortcut precedence and immediate emergency recovery across supported systems and competing tools.
- A supported OS/architecture matrix, project license, distribution identity, and notarization. Local app assembly uses an ad-hoc signature.
- Repeatable app/system memory, CPU, energy, latency, and correctness measurements. No comparative performance claim is established.

Product acceptance criteria are in [000-product.md](specs/000-product.md), with architecture and capability gates in [001-engineering.md](specs/001-engineering.md).
