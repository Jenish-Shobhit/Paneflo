# Building, testing and releasing

Requires macOS 26 or later on Apple silicon and Swift 6.2 or newer (Xcode Command Line Tools are enough). No third-party packages.

## Build

```sh
./scripts/make-signing-identity.sh   # once: creates the self-signed "Paneflo Dev" code-signing certificate
./scripts/build.sh --install --run   # build, sign, replace /Applications/Paneflo.app, open it
```

`scripts/build.sh [--debug] [--install] [--run] [--zip]`:

- `--debug` builds a debug configuration (default is release).
- `--install` quits a running Paneflo and replaces `/Applications/Paneflo.app`; run the installed copy so permissions persist.
- `--run` opens the result.
- `--zip` writes `dist/Paneflo-<version>.zip` (release builds only).

The app lands in `build/Paneflo.app`. Without the "Paneflo Dev" identity the bundle is signed ad hoc: macOS asks for permissions again after every rebuild and the copy cannot verify updates. The certificate is local and self-signed; releases are signed with the same one so installed copies accept updates.

`open build/Paneflo.app --args --diagnostics` prints title-free startup phases. If an executor blocks SwiftPM's manifest sandbox, prefix a script with `PANEFLO_SPM_DISABLE_SANDBOX=1`.

## Test

```sh
./scripts/test.sh
```

Runs the Swift Testing suites for `PanefloCore` (shortcut routing, sessions, layout, gesture recognition with synthetic replays, snapshot cache and scheduler, window matching, update parsing and verification). Builds and tests can use a lot of memory; run them one at a time. CI runs the same script on `macos-26` ([workflow](../.github/workflows/macos.yml)). Own-process checks live in `Tools/` (`build-native-ui-check.sh`, `test-capture-ownership.sh` and the bench builders); they use synthetic windows. Hands-on acceptance is the checklist in [QA.md](QA.md).

## Release

1. Add a `## <version> — <date>` section to the top of `CHANGELOG.md` and add its link at the bottom.
2. Commit it on a clean `main`.
3. Run `scripts/release.sh <version>`. It needs the "Paneflo Dev" identity, the `gh` CLI signed in, and no other uncommitted changes. It bumps the bundle version, builds and zips the signed release app, commits, tags `v<version>`, pushes, and creates the GitHub release with the zip; the notes are every CHANGELOG section since the last tag.

The download page at `docs/index.html` asks the GitHub API for the latest release, so it needs no edit per release.

## Benchmarks

`scripts/bench.sh` is one entry point for Paneflo's own benches in `Tools/` (`SurfaceBench`, `TileBench`, `CaptureBench`, `MeasureProcess`, `PanefloFixture`).

Read the numbers with these limits:

- **Host-specific.** Results depend on the machine, macOS build, thermal state, and memory pressure. Every results file records the model, chip, memory, macOS build, load average, free-memory percentage, and memory pressure level at start and end. A run that started or ended above "normal" pressure is flagged as noisy in the report.
- **Synthetic.** The benches drive Paneflo's own panels with generated window records, or Paneflo's own fixture windows. They do not measure your apps, a real session, or another product. A bench footprint is the bench process, not the menu-bar app and not total system memory.
- **No comparative claims.** Paneflo is not claimed to be faster or lighter than any other product. Only same-host, same-window-set, interleaved measurements of both products could support such a statement.

### Commands

```sh
scripts/bench.sh build [<ref>] [--app]    # build the bench tools (and Paneflo.app with --app) for this tree or a git ref
scripts/bench.sh run [--runs N] [--cards 20,60] [--only surface|tile|capture]
scripts/bench.sh ab <refA> <refB> [--runs N] [--cards 20,60] [--only ...]
scripts/bench.sh launch [--runs N]
scripts/bench.sh report <file.jsonl>...
```

A `<ref>` is built in a temporary worktree under `.build/bench-worktrees`, which is removed afterwards. Bench harness sources always come from the current tree, so both sides of an A/B measure the same way; only `Sources/` differs. Built tools live in `.build/bench-tools/<sha>`. Results are written to `.build/bench-results/<timestamp>-<command>.jsonl` (ignored by git). The default is 5 runs.

`run` reports median, p90, min, and max for each metric. `n` counts samples, so a metric sampled several times per run (steps, warm presentations) has more than N. Per-invocation tile medians are treated as one sample per run.

### Metrics

Surface (`--only surface`; each run launches the bench once per card count through LaunchServices; the bench shows its own panels briefly and installs no event tap):

- `*.call`: milliseconds from the call that presents or changes a surface until it returns.
- `*.turn`: milliseconds until the main queue drains after the call, so the first frame's layout, drawing, and commit are included.
- `hidden.*.busy*`: main-thread busy milliseconds in the stated window while no surface is visible. Idle should be near zero.
- `footprint.beforeSurfaces.MiB`, `footprint.afterSurfaces.MiB`: physical footprint of the bench process before the first presentation and after the whole presentation scenario. It is the bench process, so it only shows growth caused by presenting surfaces.

Tile (`--only tile`): `tileToFinalFrame`, `tileCompletion`, and `releaseToFocus` medians and p90s per invocation of `tile-bench` (10 iterations each), plus end-state failure counts, which must be zero. It moves Paneflo fixture windows through Accessibility and needs Accessibility for the terminal; without it the bench is recorded as skipped.

Capture (`--only capture`): snapshot and live-frame latencies, teardown time, cache size, and footprint start and end against fixture windows, from `CaptureBench`. It needs Screen Recording for the terminal; without it the bench is recorded as skipped. Values ending in `Ms` are milliseconds, `MiB` are mebibytes, and the rest are counts.

The `churn50` result runs 50 rapid open/select/close cycles. `settledMs` is the time from the last close until zero live streams and zero outstanding snapshots; the last cycle closes while a live stream is running, so it is measured under that condition, and it is omitted when nothing was pending at that close. `pendingAtClose` is the number of live streams plus outstanding snapshots at that final close. `maxLiveStreams` is the highest live-stream count seen during the run; it must not exceed 1.

Launch (`launch`): launches a bench copy of the app, never `/Applications/Paneflo.app`. The copy has the bundle identifier `dev.paneflo.Paneflo.bench`, so its settings and permissions stay apart from the installed app's, and it runs with `--diagnostics --bench-no-input`. `--bench-no-input` is a benchmark-only launch flag: no event tap, no trackpad listener, no setup window, no update check. Metrics:

- `launch.processEntryMark`: milliseconds from spawning the process to the `entry` startup mark.
- `launch.menuReady`: milliseconds from spawning to the `menuReady=true` startup mark.
- `launch.firstIdle`: milliseconds from spawning to the `startup firstIdle` mark: the launch work, including what it queued on the main queue, has finished and the first frame has been drawn. Recorded only when the build emits the mark; older builds lack it.
- `idle5s.physicalFootprint`: physical footprint (MiB) of the app 5 s after it was ready. The bench copy inherits the launching terminal's permissions, so it can read the window list when the terminal has them; that metadata stays on the machine and nothing is uploaded.
- `idle5s.cpuTimeOver1s`: CPU milliseconds used during the 1 s sampling window at that point.

The first launch of a freshly built binary is much slower (about 600 ms before `main`, measured on one Mac); exclude it or report it separately from the warm runs. All numbers from these benches are synthetic and apply only to the machine they were measured on.

Footprint after surface presentations is measured by the surface bench (the footprint metrics above), not by the launched app, because presenting surfaces needs the native-check hooks that exist only in the bench build.

### Running an A/B

```sh
scripts/bench.sh ab HEAD~3 HEAD --runs 10 --only surface
```

Both refs are built, then run in interleaved blocks (A,B then B,A then A,B, ...) so drift in thermal state or background load hits both sides. The report prints both builds side by side with the delta `(B - A) / A`. Before trusting a delta, check the host line: memory pressure at "normal" at both ends, a low load average, no other heavy apps. Repeat the run; treat differences smaller than the spread between the min and max of one side as noise.

Quit other heavy apps before measuring, run on power, and avoid running builds or tests at the same time.
