# Paneflo engineering specification

Status: implementation requirements and feasibility gates. Updated 2026-10-17.

This specification records architecture and capability gates for the [product requirements](000-product.md). Current source `0c80b6e` passed 63 tests, release compilation, and [hosted CI](https://github.com/Jenish-Shobhit/Paneflo/actions/runs/39014695313). Native evidence combines `af31070` Overview keyboard cancellation/wake checks with preceding-build physical placement/release and saved-control checks on unchanged paths, all on one host. Three-finger down dismissal remains unresolved; the current idle-recognition correction awaits native validation. See [implementation status](../status.md) for verified scope. Numeric budgets below are policies or targets, not measurements of total app resources.

## 1. Application shape

One Swift menu-bar app, initially one process. The independently enabled Switcher, Tiling, and Overview modules consume shared services and immutable state. Use AppKit and Core Animation for interactive panels and tiles; Settings opens separately on demand. The deliverable is a native application, not a web runtime around the HTML concept.

| Subsystem | Responsibility | Boundary |
| --- | --- | --- |
| AppCoordinator | Lifecycle, module toggles, privacy transitions, capability state | Main-thread orchestration only; no blocking IPC |
| WindowRegistry | Current windows, geometry, visibility, app metadata, MRU | Publishes immutable generation-tagged snapshots |
| ShortcutRouter | Hotkey events and switching-session state | Reads prepared state; queues actions without AX/capture work |
| PlatformAdapter | Version-specific hotkey, window identity, focus/capture integration | Capability checks, fail-closed unsupported paths, reversible state |
| AXExecutor | Enumeration, attributes, focus, resize/move operations | Bounded worker/admission policy, per-app isolation |
| CaptureScheduler | Discovery, thumbnail requests, selected live stream | Queued-work, in-flight, byte, and stream limits |
| PreviewCache | Owned image references and reservations | Cost-accounted eviction; no disk preview storage by default |
| LayoutEngine | Pure geometry plans, constraints, swaps, undo intent | Does not call platform APIs directly |
| SlotStore | Durable overview slots, pins, groups, matching rules | Independent from MRU; versioned metadata persistence |
| ActionCoordinator | Explicit selected-window actions and outcomes | Revalidates target identities; returns success/partial/failure |
| Presentation | Switcher/overview panels, selection, accessibility | Reuses views/layers; no direct AX queries |

A helper process is permitted only after a measured isolation or shortcut-recovery requirement cannot be met by the initial design. Document its launch, failure, memory, and cleanup costs before adding it.

## 2. Identity, registry, and persistence

- A live window key includes process lifetime identity and window identity. PID or window number reuse must never target another app/window accidentally.
- Snapshots contain compact title/app metadata, frame/display, visibility/capability flags, and separate MRU/slot references. Deduplicate app metadata and icons rather than copying them per card. Exclude Paneflo's own overlay panels from remote-window tracking.
- Observe application and AX events; coalesce bursts. Reconcile after launch, permission changes, wake, display changes, and suspected missed events. Do not continuously enumerate every window on a UI frame timer.
- Keep focus/selection session state independent from background registry mutations. Confirmed closed targets are removed; preserve the nearest viable selection deterministically. An AX timeout or incomplete scan is an unknown state, not proof of closure: preserve last-known metadata until lifecycle evidence or bounded reconciliation settles it.
- A durable overview slot has its own identifier, group, order, optional pin/matching rule, and topology metadata. Store ephemeral window IDs only as runtime associations.
- Durable matching may use app identifier plus explicit user rules and document identity where available. Titles are mutable and ambiguous. A weak or duplicate match leaves a vacancy/pending choice rather than moving an unrelated window.
- Persist explicit shortcut, preview, and gesture enable choices; restore only with existing permissions and capability checks, without startup permission prompts. Show Settings on first launch or missing permissions; keep ordinary configured launch quiet. Persist only user settings, logical slots/rules, and layout metadata. Use versioned writes with atomic replacement; recover from corrupt/unknown schema without deleting the user's last usable data.

Validation: exercise app relaunch, PID/window-number reuse in synthetic state, duplicate titles, renamed documents, closed/reopened windows, damaged settings, and registry refresh during a switching session. MRU updates must not change any overview assignment.

## 3. Shortcut ownership and session lifecycle

Model shortcut replacement as `disabled → arming → active → releasing`, plus an explicit failed/recovery state. Arming must establish permissions, a working event path, and recovery before suppressing the native forward/reverse shortcuts as a pair. A partially armed adapter releases acquired state and leaves native switching usable.

- The chosen integration may use platform-specific APIs, but all such calls belong in one version-gated adapter. Do not spread private symbol dependencies across modules.
- On first Command–Tab, freeze eligible runtime keys and the chosen order in a compact picker. Tab cycles; Shift reverses; Command release commits; Escape cancels. Handle repeat events and modifier changes explicitly.
- Command–Left/Right/Up while the picker is active applies half/fill geometry to the selected identity, not the previously focused window. Defer release-to-focus until the current placement finishes. Cancellation or a superseding selection invalidates pending focus; late placement results cannot activate another selection.
- Capture a session generation. Permission loss, screen lock, module disable, or adapter failure cancels pending selection and releases any stream/panel state.
- Dismissal enqueues focus against the selected key and verifies the current process/window identity before execution. Failure does not silently focus an arbitrary window.
- On disable and normal quit, restore only state this adapter owns, respecting the recorded baseline and detected conflicts. Native shortcut settings altered by another tool must not be overwritten blindly.
- Event-path invalidation must trigger bounded recovery or disable replacement. Prove a crash/emergency recovery approach before native replacement is enabled by default. Startup-only repair is not sufficient evidence that a crash leaves immediate switching available.

Acceptance: forward/reverse ownership, key repeat, rapid tap/release, alternate keyboard layouts, input methods, conflicting tools, permission revocation, event-path invalidation, normal exit, forced termination, and relaunch. Record exactly which recovery properties are proven on each supported macOS version.

### Optional built-in trackpad adapter

Keep unsupported trackpad integration behind explicit enable intent and platform/framework checks. Initial scope is the default built-in trackpad on Apple silicon/macOS 27 and a validated framework revision; external trackpads and broader versions are not certified. Native Mission Control/App Exposé gesture conflicts require a separate user setting change, not silent preference mutation.

The callback performs bounded contact decoding and pure recognition only. Recognize coherent three-finger vertical motion, allow a brief stationary staggered landing, reject scrolling/palm/fourth-contact sequences, and emit at most one action until lift. Dispatch actions to the main thread with a session generation; never perform UI, Accessibility, discovery or capture inside the callback.

Separate user enable intent from physical observation. Serialize start/stop outside the main thread, retain only a bounded device/library lease, and reject new starts while shutdown is uncertain. System sleep, display sleep and inactive sessions suspend observation; overlapping reasons must all clear before one automatic resume attempt after clean stop. Revalidate permissions and capability checks for each attempt. Disable invalidates queued actions; failed start/stop clears intent and prevents automatic retries. No device polling or replacement-device loop is allowed.

Acceptance: physical up/down entry with keyboard focus owned by Overview and Escape delivered to its cancellation path, normal two-finger scrolling, palm/fourth-contact rejection, repeated enable/disable, overlapping sleep/wake, disable during suspension, duplicate wakes, failed-stop recovery and permission changes. Pure lifecycle tests and one-host input checks do not certify a broader hardware/OS matrix.

## 4. Accessibility execution and focus

AX reads and writes are synchronous interprocess calls. An async Swift function or serial actor does not make a blocked call non-blocking for its executor. Use dedicated bounded workers, target timeouts, and queue admission outside the input/main thread.

- Separate interactive focus/placement from enumeration/retry traffic. A scan backlog cannot delay a user action indefinitely.
- Apply per-process outstanding-work limits and global worker limits. Do not let one stalled PID reserve every worker. Reject/defer new work when those limits are reached.
- Coalesce geometry/attribute requests by current window generation. Only the newest unstarted destination is necessary during a drag.
- Discard stale completion results using target/session generations. Cancellation removes queued work and ignores late results; it does not promise to interrupt a synchronous AX call already in progress.
- Add bounded retry/backoff for specific transient failures. Denied access, invalid targets, and unsupported attributes do not cause unlimited retries.
- Focus may require unminimizing, activating the app, and raising/focusing the correct window in a platform-dependent sequence. Verify the resulting target where the OS permits and surface failures.
- The latest focus/layout intent wins. Recheck its generation before every not-yet-issued activation, unminimize, raise, or geometry stage so obsolete work cannot issue a new effect. An already-issued synchronous AX effect cannot be cancelled; finite messaging timeouts and corrective execution of the newest intent define that limitation and recovery.
- AppKit access to Paneflo's own windows obeys main-thread rules; remote AX execution stays off-main. Respect assistive technologies and do not blanket-toggle applications' enhanced accessibility behavior to improve apparent speed.
- Treat window enumeration as capability-limited. Define and test cross-Space/fullscreen coverage by OS version; a partial AX window list does not establish that no additional windows exist.

Acceptance: use an intentionally unresponsive target and a responsive second app; the second must remain actionable and the UI responsive. Confirm bounded worker/queue counts, finite timeout recovery, no stale geometry after drag cancellation, and prompt cleanup of closed-target references.

## 5. Layout planning and application

Compute plans from a consistent registry/display snapshot. Use an explicit coordinate conversion layer for Accessibility frames, screen geometry, usable frames, and backing pixel scale. Geometry is in logical points; capture dimensions are in pixels.

- Standard layouts are deterministic functions of usable bounds, gap, and proportions. Preserve reachable geometry on display removal or resolution/rotation change.
- Display transfer preserves relative position/edge anchoring when meaningful, then clamps against the destination usable bounds and orientation. Refresh stale usable frames after Dock/menu/display changes.
- Query known movable/resizable capabilities and constraints outside the hotkey path. Some apps constrain dimensions or round frames; constraints are part of the observed outcome.
- Apply position/size changes through an adapter that can handle apps requiring repeated position/size ordering. Read back the accepted rectangle and stop after a bounded correction policy.
- Shared-divider plans must satisfy both neighbors' constraints before executing; otherwise clamp/reject with a clear outcome.
- Treat multi-window operations as a best-effort transaction: snapshot previous frames first, execute bounded work, then report success or partial failure. Do not promise atomic changes across processes.
- Undo stores runtime identities and before/after geometry only, capped at 20 operations. Never restore geometry to a newly reused window key.
- Saved-layout restore uses explicit/conservative matching. Missing and ambiguous slots remain visible to the user. Automatic rules are opt-in with floating exclusions and no uncontrolled reapplication loop.

Acceptance: constrained/non-resizable windows, half/third rounding, mixed-DPI displays, portrait display, Dock/menu changes, unplug/replug, partial failures, 20-operation history bound, and undo when a target disappears. Readback, rather than intended geometry alone, determines correctness.

## 6. Preview acquisition and presentation

Cached thumbnails and icons are sufficient for first presentation. Capture discovers eligible sources asynchronously and never runs synchronously in the shortcut handler. Use version/capability adapters rather than assuming one capture implementation behaves identically across macOS releases.

- Admit a maximum of **one continuous live stream across the entire application**, attached to the currently selected eligible window while Switcher or Overview is visible.
- Other cards use low-resolution one-shot/cached images. The current cache is limited to 12 entries/6 MiB with 30-second expiry, a per-image payload ceiling, and one physically outstanding snapshot request. Expiry or cancellation never releases physical request debt before its callback finishes. Selection changes invalidate obsolete results; current window identity/owner must still match before presentation. Avoid eagerly retaining full-resolution neighbors.
- Bound discovery with single-flight state, deadlines, coalescing, and retry backoff. A timed-out discovery result cannot repopulate a newer generation accidentally.
- Independently cap waiting jobs, executing OS requests awaiting callbacks, retained frames, and byte reservations. A serial operation queue does not bound asynchronous capture requests after they have been submitted.
- A callback deadline or logical cancellation does not prove the OS stopped the request. Retain outstanding-request accounting until completion/certain teardown, or open a circuit breaker that blocks new requests until bounded recovery. Do not repeatedly submit replacements for timed-out work whose physical completion is unknown.
- Capture only the pixels needed for presentation. Initial selected-live ceiling: 960 × 600 pixels at up to 30 fps, no audio; initialize queue depth at 3 and verify actual retained surfaces.
- Present the latest usable frame and drop obsolete frames. Prefer surface reuse without repeated CPU conversion or image encoding. Verify ownership/lifetime before claiming a zero-copy path.
- Distinguish live, cached, minimized/paused, unavailable/protected, and excluded states. Cached images must not animate or carry a live indicator.
- On close, lock, permission revocation, exclusion, or disabled previews: invalidate the session, stop/detach the stream, release retained/queued frames, discard late callbacks, and purge images as required by the privacy state.
- A stopped panel has no continuous capture or display-link animation loop. Reduce Motion and Low Power Mode alter animation/capture cadence without delaying selection state.

Acceptance: at most one admitted stream; zero hidden must cover native app hide as well as explicit panel dismissal. Also verify a rapid 200-cycle open/select/close sequence, selection changes faster than capture, callback after close, minimized/protected windows, denied/revoked permission, lock/wake, and capture service failure. Counters distinguish queued, logically cancelled, physically outstanding, and completed requests. Withhold callbacks in a scheduler test and prove recovery cannot accumulate unbounded OS requests. Check that old generations release their payloads after actual completion/teardown.

## 7. Memory accounting and pressure

The budget below constrains owned preview payloads and reservations. It is not a cap on total app footprint, ScreenCaptureKit/framework pools, capture services, WindowServer, or GPU allocations.

| Mode | Retained thumbnails | Live stream | Combined modeled reservation |
| --- | --- | --- | --- |
| Balanced | Cost-accounted LRU, at most 24 MiB | Selected only | At most 32 MiB |
| Memory pressure | Smaller snapshots, at most 6 MiB | Off | At most 6 MiB |
| Icons only | No preview payloads | Off | 0 preview-payload bytes |

Reserve bytes before submitting image work; charge queued and in-flight output reservations to the same admission system. On arrival, use actual row stride × height for the image payload, reconcile the reservation, and evict/downscale/reject if the requested mode cannot admit it. Avoid double-counting shared references while tracking their lifetime. Release reservation and image references on every success, failure, timeout, cancellation, and privacy transition.

`surface bytes = actual bytesPerRow × pixel height`. A three-surface 960 × 600 BGRA pool has an unaligned payload estimate of about 6.6 MiB; row stride and additional retained surfaces change actual cost. Fifty 320 × 200 BGRA thumbnails have an unaligned payload estimate of about 12.2 MiB. Neither figure includes object/framework/system overhead.

Do not rely on a soft cache-cost limit as a hard budget. Bound metadata, shared icons, visible tile pools, observer registrations, undo, queue entries, and stale AX references as well. A total footprint target will be established after the native shell and first capture path are measured.

Acceptance: admission cannot exceed the owned-byte envelope in deterministic scheduler tests, including error/late-callback paths. Instruments inspection must separately confirm the process/system allocations and identify overhead not represented by counters. Memory pressure stops live work and releases purged payloads; repeated dismissal settles without a monotonic growth trend.

## 8. Overview and accessible UI

The larger Overview is a Paneflo panel, separate from Apple's Mission Control and the compact Command–Tab picker. Invoke it with its dedicated shortcut or the optional capability-gated built-in gesture adapter. Mission Control key, native Space, and fullscreen integration remain later extensions. Settings has a separate window and does not occupy the switching surface.

Logical slots remain stable across focus changes. Arrow navigation follows the visible grid rather than treating every direction as linear cycling. Dragging explicitly changes slot assignments; filtering dims non-matches in place. Pinning reserves a vacancy. Density, pagination, and display filters derive visual placement from stable logical slots without destroying assignments.

Reuse tile/layer pools for visible cards, diff registry snapshots, and expose accessible app/title/state/action labels. Ensure keyboard traversal, VoiceOver selection, Reduce Motion, contrast, and light/dark appearance. Native window titles may be sensitive: do not send them to telemetry or persistent logs by default.

Acceptance: repeat open/focus/filter/close cycles without slot movement; navigate without a pointer; preserve selected identity through density/display changes; test VoiceOver and Reduce Motion; verify layout remains useful at 200 tracked windows.

## 9. Performance evidence and release gates

Use signposts around input receipt, panel presentation, selection update, focus request/confirmation, AX work, discovery, capture start/frame/stop, and cache admission/eviction. Keep instrumented release behavior representative; diagnostics must be bounded and avoid image/title collection.

Reference workload: declared Mac model/memory, exact macOS build, one display, 50 tracked windows, 320 × 200 cached thumbnails, one 960 × 600 selected preview, debugger detached. Repeat at 10/100/200 windows, two displays/mixed scales, Low Power Mode, and one unresponsive target. Benchmark native macOS and the chosen comparator versions under equivalent workloads; record functionality differences rather than obscuring them.

Report cold and warm P50/P95/P99 input-to-first-presentation, selection delay, focus success, peak/settled physical footprint, CPU normalized to one core, energy, dropped frames, and capture-service/WindowServer/GPU deltas. Raw machine traces stay local.

Initial unmeasured targets: warm P95 first presentation ≤ 50 ms; selection highlight at the next available display refresh; settled idle CPU < 0.5% of one core over 60 seconds; no active stream while both surfaces are hidden. No claim of being fastest or having the least total RAM is permitted before comparable evidence supports it.

Before a release enables each capability: prove shortcut recovery, privacy fallbacks, correct constrained geometry, stable overview identity, bounded async work, memory teardown, input-method compatibility, and the supported OS/display matrix. Failures disable the affected capability with a useful fallback instead of blocking every module.

## 10. Decisions before implementation defaults

- Supported macOS versions and architectures; test machines for every claimed version.
- Shortcut adapter and immediate forced-termination recovery; whether that requirement justifies a helper.
- Native capture adapters, deployment APIs, entitlement/signing/distribution model, and precise permission flow.
- Concrete AX/capture worker, queue, and timeout defaults, established from the smallest feasibility target rather than guessed unlimited concurrency.
- Persistent app/window matching and display topology identity; migration policy for saved slots/layouts.
- Project license and dependency/reuse policy.
- Measured native-shell baseline and total process/system memory budget.

These decisions gate their related defaults. They do not block writing pure geometry/state/scheduling code once the specification milestone is accepted, provided no unproven platform behavior is presented as shipped functionality.
