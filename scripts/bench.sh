#!/bin/bash
# One entry point for Paneflo's own benches: synthetic, own-process / fixture windows only.
#
#   scripts/bench.sh build [<git-ref>] [--app]    bench tools (and with --app a Paneflo.app) of this tree, or of <ref>
#                                                 built in a temporary worktree under .build/bench-worktrees
#   scripts/bench.sh run [--runs N] [--cards 20,60] [--only surface|tile|capture]
#   scripts/bench.sh ab <refA> <refB> [--runs N] [--cards ..] [--only ..]   interleaved, side by side with deltas
#   scripts/bench.sh launch [--runs N]            launch -> menu ready, idle footprint (bench copy, no input taps)
#   scripts/bench.sh report <file.jsonl>...       the tables again
#
# Results: .build/bench-results/<timestamp>-<command>.jsonl. Numbers are host-specific and synthetic; see
# docs/building.md ("Benchmarks"). Nothing here installs an event tap, posts global input, or touches
# /Applications/Paneflo.app. The tile bench needs Accessibility for the terminal and capture needs Screen
# Recording; without them those benches are recorded as skipped.
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
ROOT=$(pwd)
TOOLS_DIR="$ROOT/.build/bench-tools"
WT_DIR="$ROOT/.build/bench-worktrees"
RESULTS_DIR="$ROOT/.build/bench-results"
FIXTURE_APP="$ROOT/build/PanefloFixture.app"
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"

die() { echo "bench.sh: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# ---------------------------------------------------------------- host -------------------------------------------------
pressure_level() { sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0; }   # 1 normal, 2 warning, 4 critical
pressure_name() { case "$1" in 1) echo normal ;; 2) echo warning ;; 4) echo critical ;; *) echo "unknown($1)" ;; esac; }
load_avg() { sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}'; }
free_pct() { memory_pressure 2>/dev/null | awk '/free percentage/ {gsub("%","",$NF); print $NF}' | head -1; }

SESSION=""; OUT=""
start_session() { # $1 command
  mkdir -p "$RESULTS_DIR"
  SESSION="$(date +%Y%m%d-%H%M%S)-$1"
  OUT="$RESULTS_DIR/$SESSION.jsonl"
  jq -nc --arg session "$SESSION" --arg cmd "$1" --arg date "$(date -u +%FT%TZ)" \
    --arg model "$(sysctl -n hw.model)" --arg chip "$(sysctl -n machdep.cpu.brand_string)" \
    --arg os "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" \
    --argjson memGiB "$(( $(sysctl -n hw.memsize) / 1073741824 ))" --argjson cpus "$(sysctl -n hw.ncpu)" \
    --argjson pressure "$(pressure_level)" --arg load "$(load_avg)" --arg free "$(free_pct)" \
    '{type:"session",session:$session,cmd:$cmd,date:$date,model:$model,chip:$chip,macOS:$os,memGiB:$memGiB,cpus:$cpus,
      pressureStart:$pressure,loadStart:($load|tonumber? // null),freePctStart:($free|tonumber? // null)}' >> "$OUT"
}
end_session() {
  jq -nc --argjson pressure "$(pressure_level)" --arg load "$(load_avg)" --arg free "$(free_pct)" --arg date "$(date -u +%FT%TZ)" \
    '{type:"sessionEnd",date:$date,pressureEnd:$pressure,loadEnd:($load|tonumber? // null),freePctEnd:($free|tonumber? // null)}' >> "$OUT"
  echo "$OUT" >&2
}
# emit <build> <bench> <metric> <unit> <run> <value>
emit() {
  jq -nc --arg build "$1" --arg bench "$2" --arg metric "$3" --arg unit "$4" --argjson run "$5" --argjson value "$6" \
    '{type:"sample",build:$build,bench:$bench,metric:$metric,unit:$unit,run:$run,value:$value}' >> "$OUT"
}
skip() { jq -nc --arg build "$1" --arg bench "$2" --arg reason "$3" '{type:"skip",build:$build,bench:$bench,reason:$reason}' >> "$OUT"; say "skipped $2 ($1): $3"; }

# ---------------------------------------------------------------- build ------------------------------------------------
tree_name() {
  local sha dirty=""
  sha=$(git rev-parse --short HEAD)
  [[ -n "$(git status --porcelain -- Sources Tools Package.swift)" ]] && dirty="-dirty"
  echo "$sha$dirty"
}
WT_ACTIVE=""
cleanup_wt() { if [[ -n "$WT_ACTIVE" && -d "$WT_ACTIVE" ]]; then git worktree remove --force "$WT_ACTIVE" >/dev/null 2>&1 || rm -rf "$WT_ACTIVE"; git worktree prune; fi; WT_ACTIVE=""; }
trap cleanup_wt EXIT

ensure_fixture() { [[ -x "$FIXTURE_APP/Contents/MacOS/PanefloFixture" ]] || sh "$ROOT/Tools/build-fixture.sh" >&2; }

build_capture() { # <out dir> <source root>
  local out=$1 src=$2
  [[ -f "$src/Sources/PanefloApp/Capture/CaptureController.swift" ]] || return 1
  mkdir -p "$out/capture"
  cat "$src/Sources/PanefloApp/Capture/CaptureController.swift" "$ROOT/Tools/CaptureBench.swift" > "$out/capture/CaptureBench.swift"
  xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -parse-as-library -O -module-cache-path "$out/capture/module-cache" \
    -emit-library -emit-module -module-name PanefloCore "$src"/Sources/PanefloCore/*.swift \
    -emit-module-path "$out/capture/PanefloCore.swiftmodule" -o "$out/capture/libPanefloCore.dylib" >&2 || return 1
  xcrun swiftc -target "$TARGET_TRIPLE" -O -parse-as-library -I "$out/capture" -L "$out/capture" -lPanefloCore \
    -Xlinker -rpath -Xlinker "$out/capture" -module-cache-path "$out/capture/module-cache" \
    "$src/Sources/PanefloApp/RuntimeDiagnostics.swift" "$out/capture/CaptureBench.swift" -o "$out/capture/capture-bench" >&2 || return 1
  codesign --force --sign - "$out/capture/libPanefloCore.dylib" "$out/capture/capture-bench" >&2
}

# build_one <ref or ""> <with-app 0|1>; prints the build name (directory under .build/bench-tools)
build_one() {
  local ref=$1 with_app=$2 name src
  if [[ -z "$ref" ]]; then name=$(tree_name); src="$ROOT"
  else name=$(git rev-parse --short "$ref") || die "unknown ref $ref"; fi
  local out="$TOOLS_DIR/$name"
  local stamp="$out/.stamp"
  local stale=1
  if [[ -f "$stamp" ]]; then
    stale=0
    if [[ -n "$(find "$ROOT/Tools" -newer "$stamp" -print -quit)" ]]; then stale=1; fi
    if [[ -z "$ref" && -n "$(find "$ROOT/Sources" "$ROOT/Package.swift" -newer "$stamp" -print -quit)" ]]; then stale=1; fi
    if [[ "$with_app" == 1 && ! -d "$out/Paneflo.app" ]]; then stale=1; fi
  fi
  if [[ "$stale" == 0 ]]; then echo "$name"; return; fi
  if [[ -n "$ref" ]]; then
    mkdir -p "$WT_DIR"
    WT_ACTIVE="$WT_DIR/$name"
    rm -rf "$WT_ACTIVE"; git worktree prune
    git worktree add --detach "$WT_ACTIVE" "$ref" >&2
    src="$WT_ACTIVE"
  fi
  rm -rf "$out"; mkdir -p "$out"
  ensure_fixture
  say "building surface bench ($name)"
  sh "$ROOT/Tools/build-surface-bench.sh" "$out/surface" --source "$src" >&2 || say "surface bench build failed for $name"
  say "building tile bench ($name)"
  sh "$ROOT/Tools/build-tile-bench.sh" "$out/tile" --source "$src" >&2 || say "tile bench build failed for $name"
  say "building capture bench ($name)"
  build_capture "$out" "$src" || say "capture bench build failed for $name"
  if [[ "$with_app" == 1 ]]; then
    say "building Paneflo.app ($name)"
    if [[ -n "$ref" ]]; then (cd "$src" && scripts/build.sh >&2) && ditto "$src/build/Paneflo.app" "$out/Paneflo.app" >&2
    else scripts/build.sh >&2 && ditto "$ROOT/build/Paneflo.app" "$out/Paneflo.app" >&2; fi
    # A separate bundle id keeps the bench copy's UserDefaults and permissions apart from the installed app's.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.paneflo.Paneflo.bench" "$out/Paneflo.app/Contents/Info.plist"
    codesign --force --sign - "$out/Paneflo.app" >&2
  fi
  sh "$ROOT/Tools/build-measure-process.sh" >&2 || true
  touch "$stamp"
  cleanup_wt
  echo "$name"
}

# ---------------------------------------------------------------- benches ----------------------------------------------
# surface_once <build> <cards> <run>
surface_once() {
  local build=$1 cards=$2 run=$3 dir app
  app="$TOOLS_DIR/$build/surface/SurfaceBench.app"
  [[ -d "$app" ]] || { skip "$build" surface "not built"; return; }
  dir=$(mktemp -d "${TMPDIR:-/tmp}/paneflo-surface.XXXXXX")
  open -W -n "$app" --args "$dir" "$cards"
  local f
  for f in "$dir"/samples-*.tsv; do
    [[ -f "$f" ]] || { skip "$build" surface "no samples written"; break; }
    awk -F'\t' 'NF==3 {print $2 "\t" $3}' "$f" | while IFS=$'\t' read -r metric value; do
      local unit=ms
      case "$metric" in *.MiB) unit=MiB ;; esac
      emit "$build" surface "$cards.$metric" "$unit" "$run" "$value"
    done
  done
  rm -rf "$dir"
}

# tile_once <build> <run>
tile_once() {
  local build=$1 run=$2 bin="$TOOLS_DIR/$build/tile/tile-bench" log status=0
  [[ -x "$bin" ]] || { skip "$build" tile "not built"; return; }
  log=$(mktemp "${TMPDIR:-/tmp}/paneflo-tile.XXXXXX")
  "$bin" "$FIXTURE_APP" --runs 10 > "$log" 2>&1 || status=$?
  if [[ "$status" == 3 ]]; then skip "$build" tile "Accessibility not granted to this terminal"; rm -f "$log"; return; fi
  if [[ "$status" != 0 ]]; then skip "$build" tile "tile-bench exit $status"; rm -f "$log"; return; fi
  # "tileToFinalFrame ms n=10 median=.. p90=.. min=.. max=.."
  while IFS= read -r line; do
    local name med p90
    name=$(echo "$line" | sed -E 's/ ms n=.*//; s/ /_/g')
    med=$(echo "$line" | sed -E 's/.*median=([0-9.]+).*/\1/'); p90=$(echo "$line" | sed -E 's/.*p90=([0-9.]+).*/\1/')
    emit "$build" tile "$name.median" ms "$run" "$med"; emit "$build" tile "$name.p90" ms "$run" "$p90"
  done < <(grep -E '^[A-Za-z]+ ms n=[0-9]+ median=' "$log")
  local fails; fails=$(grep -E '^endStateFailures' "$log" | sed -E 's/.*ordering=([0-9]+) tileFrame=([0-9]+).*/\1 \2/' || true)
  if [[ -n "$fails" ]]; then emit "$build" tile endStateFailures.ordering count "$run" "${fails% *}"; emit "$build" tile endStateFailures.tileFrame count "$run" "${fails#* }"; fi
  rm -f "$log"
}

# capture_once <build> <run>
capture_once() {
  local build=$1 run=$2 bin="$TOOLS_DIR/$build/capture/capture-bench" log status=0
  [[ -x "$bin" ]] || { skip "$build" capture "not built"; return; }
  log=$(mktemp "${TMPDIR:-/tmp}/paneflo-capture.XXXXXX")
  "$bin" "$FIXTURE_APP/Contents/MacOS/PanefloFixture" 6 > "$log" 2>&1 || status=$?
  if grep -q 'screenRecording=not-granted' "$log"; then skip "$build" capture "Screen Recording not granted to this terminal"; rm -f "$log"; return; fi
  if [[ "$status" != 0 ]]; then skip "$build" capture "capture-bench exit $status"; rm -f "$log"; return; fi
  # "RESULT <section> key=value ..." : numeric values only; suffix Ms -> ms, MiB -> MiB, else count
  grep '^RESULT ' "$log" | while IFS= read -r line; do
    local section; section=$(echo "$line" | awk '{print $2}')
    case "$section" in host) continue ;; esac
    for kv in $(echo "$line" | cut -d' ' -f3-); do
      case "$kv" in *=*) ;; *) continue ;; esac
      local k=${kv%%=*} v=${kv#*=} unit=count
      [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || continue
      case "$k" in *Ms) unit=ms ;; *MiB) unit=MiB ;; esac
      emit "$build" capture "$section.$k" "$unit" "$run" "$v"
    done
  done
  rm -f "$log"
}

# one_block <build> <run> : one iteration of every selected bench
ONLY="surface,tile,capture"; CARDS="20,60"; RUNS=5
one_block() {
  local build=$1 run=$2 c
  if [[ ",$ONLY," == *,surface,* ]]; then for c in ${CARDS//,/ }; do surface_once "$build" "$c" "$run"; done; fi
  if [[ ",$ONLY," == *,tile,* ]]; then tile_once "$build" "$run"; fi
  if [[ ",$ONLY," == *,capture,* ]]; then capture_once "$build" "$run"; fi
}

parse_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runs) RUNS=${2:?}; shift 2 ;;
      --cards) CARDS=${2:?}; shift 2 ;;
      --only) ONLY=${2:?}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || die "--runs must be a positive integer"
}

# ---------------------------------------------------------------- launch -----------------------------------------------
LAUNCHER=$(cat <<'PERL'
use strict; use Time::HiRes qw(time sleep);
my ($bin, $err, $mp, $mpout, $result) = @ARGV;
my $t0 = time;
my $pid = fork();
if (!$pid) { open STDERR, '>', $err; open STDOUT, '>', '/dev/null'; exec($bin, '--diagnostics', '--bench-no-input') or exit 127; }
my ($entry, $ready, $idle);
while (time - $t0 < 30) {
  if (open my $f, '<', $err) { local $/; my $t = <$f>; close $f;
    $entry //= (time - $t0) * 1000 if $t =~ /startup: entry/;
    $ready //= (time - $t0) * 1000 if $t =~ /menuReady=true/;
    # firstIdle: the launch turn (and whatever it queued on the main queue) is done and committed. Older builds lack it.
    $idle //= (time - $t0) * 1000 if $t =~ /startup firstIdle/;
    last if defined $ready && (defined $idle || time - $t0 > ($ready / 1000) + 2); }
  sleep 0.005;
}
if (defined $ready) {
  sleep 5;   # idle: 5 s after ready
  system("$mp --pid $pid --seconds 1 > $mpout 2>/dev/null");
}
kill 'TERM', $pid; my $d = time; while (time - $d < 3 && waitpid($pid, 1) == 0) { sleep 0.05 } kill 'KILL', $pid; waitpid($pid, 0);
open my $o, '>', $result;
printf $o "{\"entryMs\":%s,\"readyMs\":%s,\"idleMs\":%s}\n", defined $entry ? sprintf("%.1f", $entry) : 'null', defined $ready ? sprintf("%.1f", $ready) : 'null', defined $idle ? sprintf("%.1f", $idle) : 'null';
PERL
)

cmd_launch() {
  parse_opts "$@"
  local build; build=$(build_one "" 1)
  local app="$TOOLS_DIR/$build/Paneflo.app" mp="$ROOT/dev_acrtifacts/runtime/measure-process"
  [[ -x "$mp" ]] || die "measure-process missing"
  start_session launch
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/paneflo-launch.XXXXXX")
  printf '%s\n' "$LAUNCHER" > "$tmp/launch.pl"
  local i
  for ((i = 1; i <= RUNS; i++)); do
    say "launch $i/$RUNS"
    perl "$tmp/launch.pl" "$app/Contents/MacOS/Paneflo" "$tmp/err.txt" "$mp" "$tmp/mp.json" "$tmp/result.json"
    local ready entry
    ready=$(jq '.readyMs' "$tmp/result.json"); entry=$(jq '.entryMs' "$tmp/result.json")
    if [[ "$ready" == null ]]; then skip "$build" launch "menuReady mark not seen within 30 s"; continue; fi
    emit "$build" launch launch.processEntryMark ms "$i" "$entry"
    emit "$build" launch launch.menuReady ms "$i" "$ready"
    local idle; idle=$(jq '.idleMs' "$tmp/result.json")
    [[ "$idle" == null ]] || emit "$build" launch launch.firstIdle ms "$i" "$idle"
    emit "$build" launch idle5s.physicalFootprint MiB "$i" "$(jq '.samples[-1].physicalFootprintBytes / 1048576' "$tmp/mp.json")"
    emit "$build" launch idle5s.cpuTimeOver1s ms "$i" "$(jq '(.samples[-1].totalCPUTimeNanoseconds - .samples[0].totalCPUTimeNanoseconds) / 1e6' "$tmp/mp.json")"
    rm -f "$tmp/err.txt" "$tmp/mp.json" "$tmp/result.json"
  done
  rm -rf "$tmp"
  end_session
  cmd_report "$OUT"
}

# ---------------------------------------------------------------- report -----------------------------------------------
cmd_report() {
  [[ $# -ge 1 ]] || die "report needs at least one .jsonl file"
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || die "no such file: $f"
    echo "== $(basename "$f")"
    jq -rs '
      (map(select(.type=="session")) | .[0]) as $s | (map(select(.type=="sessionEnd")) | .[0]) as $e |
      def pn: if .==1 then "normal" elif .==2 then "WARNING" elif .==4 then "CRITICAL" else "unknown" end;
      "host: \($s.model) \($s.chip), \($s.memGiB) GiB, \($s.cpus) cpus, macOS \($s.macOS); " +
      "memory pressure start=\($s.pressureStart|pn) end=\(($e.pressureEnd // null)|if .==null then "n/a" else pn end); " +
      "load \($s.loadStart // "n/a") -> \($e.loadEnd // "n/a"); free \($s.freePctStart // "n/a")% -> \($e.freePctEnd // "n/a")%" +
      (if ($s.pressureStart != 1 or (($e.pressureEnd // 1) != 1)) then "\n  NOTE: memory pressure was not normal during this run; treat the numbers as noisy." else "" end) +
      "\nsynthetic: own-process / fixture windows only; host-specific."
    ' "$f"
    jq -rs '
      def pct($p): sort | (($p * (length - 1))) as $r | ($r | floor) as $l | ($r | ceil) as $h | .[$l] + (.[$h] - .[$l]) * ($r - $l);
      def f: (. * 100 | round / 100) | tostring;
      (map(select(.type=="sample")) ) as $S |
      ($S | reduce .[] as $x ([]; if index($x.build) then . else . + [$x.build] end)) as $builds |
      (map(select(.type=="skip")) | map("skipped: \(.bench) (\(.build)): \(.reason)") | unique | .[]),
      ( [$S | group_by(.bench + "|" + .metric)[] | . as $g | {key: ($g[0].bench + "  " + $g[0].metric), unit: $g[0].unit,
          stats: ( $g | group_by(.build) | map({(.[0].build): (map(.value) | {n: length, med: pct(0.5), p90: pct(0.9), min: min, max: max})}) | add )}]
        | if ($builds | length) <= 1 then
            ["bench  metric", "unit", "n", "median", "p90", "min", "max"],
            (.[] | .key as $k | .unit as $u | .stats[$builds[0]] | [$k, $u, .n, (.med|f), (.p90|f), (.min|f), (.max|f)])
          else
            ["bench  metric", "unit", "n A/B", "A median", "B median", "delta %", "A p90", "B p90"],
            (.[] | .key as $k | .unit as $u | .stats[$builds[0]] as $a | .stats[$builds[1]] as $b |
              [$k, $u, "\($a.n // 0)/\($b.n // 0)", ($a.med // "-" | if type=="number" then f else . end), ($b.med // "-" | if type=="number" then f else . end),
               (if ($a.med // 0) > 0 and $b.med != null then (($b.med - $a.med) / $a.med * 100 | . * 10 | round / 10 | tostring) else "-" end),
               ($a.p90 // "-" | if type=="number" then f else . end), ($b.p90 // "-" | if type=="number" then f else . end)])
          end | @tsv ),
      ( if ($builds | length) > 1 then "A = \($builds[0]), B = \($builds[1]) (first-seen order); delta = (B - A) / A." else "build = \($builds[0] // "none")" end )
    ' "$f" | column -t -s $'\t'
  done
}

# ---------------------------------------------------------------- main -----------------------------------------------
case "${1:-help}" in
  build)
    shift
    REF=""; APP=0
    while [[ $# -gt 0 ]]; do case "$1" in --app) APP=1; shift ;; -*) die "unknown option $1" ;; *) REF=$1; shift ;; esac; done
    NAME=$(build_one "$REF" "$APP")
    echo "$TOOLS_DIR/$NAME"
    ;;
  run)
    shift; parse_opts "$@"
    BUILD=$(build_one "" 0)
    start_session run
    for ((i = 1; i <= RUNS; i++)); do say "run $i/$RUNS"; one_block "$BUILD" "$i"; done
    end_session
    cmd_report "$OUT"
    ;;
  ab)
    shift
    A=${1:?ab needs <refA> <refB>}; B=${2:?ab needs <refA> <refB>}; shift 2
    parse_opts "$@"
    BA=$(build_one "$A" 0); BB=$(build_one "$B" 0)
    [[ "$BA" != "$BB" ]] || die "refs resolve to the same commit"
    start_session ab
    for ((i = 1; i <= RUNS; i++)); do
      say "block $i/$RUNS"
      if (( i % 2 )); then one_block "$BA" "$i"; one_block "$BB" "$i"; else one_block "$BB" "$i"; one_block "$BA" "$i"; fi
    done
    end_session
    cmd_report "$OUT"
    ;;
  launch) shift; cmd_launch "$@" ;;
  report) shift; cmd_report "$@" ;;
  help|-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command $1 (try: scripts/bench.sh help)" ;;
esac
