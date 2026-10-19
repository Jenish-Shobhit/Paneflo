#!/bin/sh
# Builds the drag-to-edge arm latency bench (Tools/SnapBench.swift) against a source tree.
#
#   sh Tools/build-snap-bench.sh <output-dir> [--source <tree>]
#   <output-dir>/snap-bench <PanefloFixture executable>
#
# It reads one fixture window's bounds from the window list and replays synthetic drags through SnapDragTracker on a
# simulated clock. It moves no window, posts no input, installs no monitor and needs no permission.
set -eu
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Supply an output directory for the snap bench}"
shift
SOURCE_ROOT="$PROJECT_ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_ROOT="$(CDPATH= cd -- "$2" && pwd)"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
grep -qs "struct SnapDragTracker" "$SOURCE_ROOT"/Sources/PanefloCore/*.swift || { echo "no SnapDragTracker in $SOURCE_ROOT" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
FLAGS=""
# Builds whose service schedules one-shot samples at `nextSampleAt` (instead of a repeating timer).
if grep -qs "var nextSampleAt" "$SOURCE_ROOT"/Sources/PanefloCore/SnapAreas.swift; then FLAGS="-D SNAP_BENCH_NEXT_SAMPLE"; fi
xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -parse-as-library -O \
    -module-cache-path "$OUTPUT_DIR/module-cache" -emit-library -emit-module \
    -module-name PanefloCore "$SOURCE_ROOT"/Sources/PanefloCore/*.swift \
    -emit-module-path "$OUTPUT_DIR/PanefloCore.swiftmodule" -o "$OUTPUT_DIR/libPanefloCore.dylib"
# shellcheck disable=SC2086
xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -O $FLAGS \
    -I "$OUTPUT_DIR" -L "$OUTPUT_DIR" -lPanefloCore -Xlinker -rpath -Xlinker "$OUTPUT_DIR" \
    -parse-as-library -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$PROJECT_ROOT/Tools/SnapBench.swift" -o "$OUTPUT_DIR/snap-bench"
codesign --force --sign - "$OUTPUT_DIR/libPanefloCore.dylib" "$OUTPUT_DIR/snap-bench"
echo "Built $OUTPUT_DIR/snap-bench from $SOURCE_ROOT${FLAGS:+ ($FLAGS)}"
