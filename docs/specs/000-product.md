# Paneflo product specification

Status: product requirements, pre-implementation. Updated 2026-10-16.

## Purpose

Make individual windows quick to find, arrange, and revisit in predictable places. Deliver one native Swift menu-bar app with three independently enabled modules: Switcher, Tiling, and Overview. The [engineering specification](001-engineering.md) defines the architecture, feasibility gates, and benchmark protocol for implementation.

Private development artifacts remain in gitignored `dev_acrtifacts/`. The public repository contains product requirements and engineering specifications, followed by implementation milestones.

## Product rules

1. A shortcut reads ready window state and presents icons or cached cards without waiting for capture or synchronous Accessibility work.
2. Window selection is shared across modules; selecting a window can lead directly to a placement action.
3. Recent-use order helps switching. Persistent slots help the overview. These orders never overwrite one another.
4. Only the selected eligible window may have a continuous preview stream; other cards use bounded snapshots. Both switching surfaces hidden means zero live streams.
5. Layout changes remain reversible where target windows still exist and accept their old geometry.
6. Cached, live, minimized/paused, excluded, and unavailable preview states are distinct. Permission loss produces a useful fallback.
7. Performance and memory figures below are proposed policies or unmeasured targets, not achieved results.

## 1. Switcher

### Core scope

- Command–Tab replaces the native app switcher with individual-window selection; Shift reverses, Command release commits, Escape cancels.
- Quick repeated use toggles the previous eligible window. Navigation order freezes for each session; window removals preserve selection when possible.
- App-name/window-title local search, keyboard and pointer navigation, thumbnail grid, compact list, and icons-only presentation.
- Immediate cached cards; asynchronous selected-window live preview when permitted and available.
- Filters for display, current app, and logical workspace; configurable treatment of minimized and hidden windows.
- Actions on the selection: focus, close, minimize, maximize, snap, and move to a display. Closing a window requires an explicit action, never modifier release alone.

### Acceptance criteria

- S1: With two windows of one app, Command–Tab can select and focus the intended window, rather than only activating its app.
- S2: Cycling, reverse cycling, modifier release, Escape, held keys, and a window closing mid-session produce deterministic selection. Background focus updates do not reshuffle the session.
- S3: Denied or revoked preview permission permits a responsive icons/title workflow without repeated permission prompts.
- S4: Capture starts after presentation and never blocks the input callback. At most one continuous stream exists across Switcher and Overview.
- S5: Normal quit restores any native shortcut state Paneflo changed. Crash recovery and an emergency bypass are proven before enabling replacement by default.
- S6: Report warm/cold shortcut-to-first-presentation latency under a documented workload; do not count screenshot completion as first presentation.

## 2. Desktop tiling

### Core scope

- Keyboard placement for halves, thirds, quarters, center, maximize, and main-pane layouts; pointer edge snapping with a destination preview.
- Directional focus, slot swap, display movement, configurable gaps, and per-app floating exclusions.
- Geometry-only undo capped at 20 operations. Multi-window actions capture previous geometry and report partial outcomes.
- Read back accepted frames; accommodate app minimum sizes, Dock/menu usable area, mixed display scales, and disconnected displays.

### Acceptance criteria

- T1: A window placed in a standard zone is inside the display's usable area, subject to app-enforced constraints; readback determines the actual result.
- T2: Preview geometry matches the requested destination. Unsupported or constrained movement is reported and does not create an infinite retry loop.
- T3: Undo restores surviving eligible windows to recorded frames when accepted; closed or refusing windows produce a clear partial result.
- T4: One unresponsive target cannot block shortcut presentation or exhaust work admission for other apps.
- T5: Display unplug, portrait orientation, different scales, and changed usable areas keep windows reachable.

### Later extensions

Custom zones per display, conservative saved-layout matching, shared-divider resizing, and opt-in automatic tiling rules. Each extension must pass correctness and resource gates before entering the core release.

## 3. Organized overview

### Core scope

- A dedicated Paneflo overlay with remembered logical slots, a shortcut, keyboard/pointer activation, drag reordering, and pinned positions.
- Focus history never sorts the overview. New windows occupy free slots or append without moving existing assignments; pinned vacancies persist.
- Search dims non-matching cards in place. Filters and density changes preserve logical slot identities.
- The window's display and visibility state remain visible. Large collections use recycled views and pagination or virtualization.

### Acceptance criteria

- O1: Reopen the overlay after arbitrary focus changes: assigned windows retain their slots.
- O2: Open/close another window: existing assignments remain unchanged. Clearing vacancies requires an explicit tidy action.
- O3: Searching and clearing search restore the same arrangement; navigation can skip non-matches without reassigning positions.
- O4: Overview selection uses the same window identity and action path as Switcher and Tiling.
- O5: Across app relaunches, reconcile conservatively using stable app/rule metadata; ambiguous matches require user choice. An ephemeral window number is never treated as a durable identity.

### Later extensions and limits

Editable logical groups, saved workspace/layout recall, conservative relaunch matching, and optional gesture/function-key entry after investigation. Logical workspaces do not imply native Space control. Paneflo does not initially modify Apple's Mission Control arrangement or promise removal of OS-controlled fullscreen/Space transition delays.

## Shared experience and platform boundaries

- Menu-bar controls, independent module toggles, shared shortcut conflict handling, optional launch at login, and on-demand settings.
- Accessibility permission for window control; Screen Recording permission for previews. Confirm any additional input permission through the selected hotkey implementation.
- No account or cloud requirement. Preview images stay in memory by default, with app exclusion controls and purge on permission revocation, lock, or privacy-sensitive transitions as established by the platform investigation.
- VoiceOver, full keyboard navigation, Reduce Motion, high contrast, and light/dark appearance are release criteria.
- Handle minimized/protected/unavailable capture, non-resizable windows, unresponsive apps, screen lock, sleep/wake, permission revocation, keyboard layouts/input methods, and each supported macOS version.
- No SIP changes are part of the plan. Undocumented integration, if required, sits behind versioned capability checks with a recoverable fallback.

## Architecture and resource policy

Start with one process: shared immutable WindowRegistry snapshots; ShortcutRouter; isolated, bounded AXExecutor; LayoutEngine; SlotStore; CaptureScheduler; cost-accounted PreviewCache; native presentation modules. AppKit/Core Animation serves the hot path; SwiftUI may serve settings. A helper requires evidence of an isolation/recovery need.

| Policy or target | Proposed value | Interpretation |
| --- | --- | --- |
| Continuous live streams | At most 1 while a surface is visible; 0 hidden | Selected eligible window only; release retained/in-flight frames on teardown |
| Thumbnail payload LRU | At most 24 MiB | Owned image payload, not total process RAM |
| Combined modeled preview reservation | At most 32 MiB | Account for retained and pending owned payloads; external framework allocations measured separately |
| Pressure mode | 0 streams; at most 6 MiB smaller snapshots | Purge disposable images; icons-only releases preview payloads |
| Initial selected capture | Up to 960 × 600 pixels at 30 fps; initial queue depth 3 | Proposed starting configuration; actual row stride, retained surfaces, and overhead must be measured |
| Warm input-to-first-presentation | P95 ≤ 50 ms | Unmeasured engineering target on a declared reference machine/workload |
| Selection highlight | Next available display refresh | Unmeasured target under reference load |
| Settled idle CPU | < 0.5% of one core over 60 seconds | Unmeasured target; no idle continuous capture/display-link loop |
| Total app/system RAM | Set after minimal-shell baseline | No hard total-RAM promise has been made |

Use byte reservations before image work, reconcile actual `bytesPerRow × height`, evict/reject oversize payloads, and bound references plus pending work. A soft cache limit alone cannot enforce a budget. Avoid repeated CPU conversion or encoding in the preview path. Generation tokens discard stale results; only the newest resize intent needs execution. An already-blocked synchronous AX call may still run until its timeout, so worker admission must remain bounded and isolated.

## Benchmark and advantage criteria

Paneflo's intended differentiation is connected selection/actions, independent stable overview slots, and explicit resource policies. AltTab and Rectangle provide overlapping capabilities; feature exclusivity and superior performance require comparable measurements. These requirements do not assert that Paneflo already outperforms another product.

Benchmark release builds with debugger detached. Record hardware, macOS build, power mode, app versions, window mix, capture settings, and display arrangement. Begin at 50 tracked windows and one display; repeat at 10/100/200 windows and two displays. Measure cold/warm P50/P95/P99 input latency, focus success, dropped frames, idle/active CPU, energy, peak/settled physical footprint, capture service/WindowServer/GPU changes, and repeated open/close recovery. Keep raw traces private and publish sanitized summaries.

## Delivery gates

| Gate | Deliverable | Exit evidence |
| --- | --- | --- |
| 0. Specify | Product and engineering requirements, capability decisions, baseline protocol | Shortcut recovery, window identity, AX behavior, and capture feasibility gates defined; unresolved risks documented |
| 1. Switch | Native shell, registry, shortcut ownership, reliable focus, cached/selected preview | S1–S6; permission and recovery checks; measured initial resource baseline |
| 2. Arrange | Standard layouts, snapping, swaps, directional actions, undo | T1–T5 across reference apps/displays |
| 3. Remember | Stable custom overview and persisted slots | O1–O5 with conservative matching and accessible navigation |
| 4. Refine | Shared actions, profiling, selected extensions | No correctness or resource regression; justified comparison against recorded baselines |

## Decisions still required

Minimum macOS version and architecture support; native shortcut mechanism and emergency recovery design; signing/distribution and permissions model; project license and dependency policy; persistent window-matching strategy; display topology identity; default shortcut map; benchmark reference machines; and the measured total-RAM budget. Resolve decisions through the engineering gates rather than inventing guarantees.
