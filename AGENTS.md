# Paneflo collaboration rules

## Work mode

- The root agent is the orchestrator. Delegate source changes, document creation, and implementation to contributors; root coordinates, reviews, runs integration checks, and performs milestone commits and repository operations.
- Keep at most **two contributor subagents active at once**. Contributor agents must not spawn further agents. Work in small, reviewable increments.
- The product and engineering specification milestone has been reviewed. The current milestone is a native developer preview and pure Swift foundation, using synthetic windows only. Real window adapters, global shortcut interception, capture, and permission requests require subsequent capability gates; do not connect them in the foundation milestone.
- Commit completed, verified milestones regularly. Keep unrelated work out of a commit, and do not include generated or private development artifacts.

## Evidence and scope

- Ground implementation claims in inspected evidence. Keep all reverse-engineering plans, methods, provenance, notes, evidence, third-party clones, binaries, analysis projects, captures, and machine-specific reports under ignored `dev_acrtifacts/research/`.
- Commit product requirements and findings-informed engineering specifications. Do not commit reverse-engineering reports, method descriptions, source provenance dumps, or research directories.
- Do not copy license-incompatible upstream code. Record the license of each inspected revision and the intended reuse decision before incorporating any implementation. Do not invent a project license or claim compatibility without a decision.
- Do not claim lower total RAM, lower latency, or superiority over another product without comparable measurements. Preview payload estimates are not app physical footprint or total system memory.

## Product architecture

- Build one native Swift menu-bar app with independently enabled Switcher, Tiling, and Overview modules. Share the window registry, capture/cache budget, shortcut routing, and action execution.
- Prefer AppKit and Core Animation on the latency-sensitive path; settings may use SwiftUI. Start with one process. Add helpers only for demonstrated isolation or recovery needs.
- Read a prepared snapshot on shortcut input. Do not synchronously scan windows, capture frames, or make Accessibility calls in the input handler.
- Keep MRU switching order separate from user-assigned overview slot order. Freeze switch order during a session.
- Admit at most one continuous live preview, for the selected eligible window, while a switching surface is visible. Hidden surfaces have zero live streams. Label cached, unavailable, and paused previews honestly.
- The organized overview is Paneflo's own overlay. Do not promise a modification of Apple's Mission Control internals, native Spaces, or gestures before the compatibility investigation proves it.

## Review and validation

- Match checks to the changed behavior. Record relevant results and remaining limits before requesting a milestone commit.
- Respect missing/revoked permissions, unresponsive apps, protected or minimized windows, display changes, input methods, accessibility settings, and shortcut recovery.
- Keep `dev_acrtifacts/` ignored using that exact spelling. Before any public push, inspect the staged file list and verify the ignore rule. Commit shared product/engineering specifications and source changes only; raw or summarized reverse-engineering records remain local.
- Never publish local app/window titles, screenshots, captured image payloads, signing keys, auth tokens, or personal machine traces.
