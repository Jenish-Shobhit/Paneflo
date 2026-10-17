#!/bin/sh
# Builds the own-fixture tiling latency bench against a source tree.
#
#   sh Tools/build-tile-bench.sh <output-dir> [--source <tree>]
#
# --source builds the bench against another checkout (for example a scratch worktree at an
# older commit) while always using this tree's Tools/TileBench.swift. A tree that still has
# SelectionCommitGate is built with BENCH_LEGACY_GATE so the old release wiring is emulated.
# The result is a plain binary: run it directly from a terminal that holds Accessibility access.
#   <output-dir>/tile-bench <PanefloFixture.app> [--runs N] [--min-width W] [--max-width W]
# It drives PanefloFixture windows only, installs no event tap and posts no global input.
set -eu
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Supply an output directory for the tile bench}"
shift
SOURCE_ROOT="$PROJECT_ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_ROOT="$(CDPATH= cd -- "$2" && pwd)"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
APP_SOURCES="$SOURCE_ROOT/Sources/PanefloApp"
FLAGS=""
if [ -f "$SOURCE_ROOT/Sources/PanefloCore/SelectionCommitGate.swift" ]; then FLAGS="-D BENCH_LEGACY_GATE"; fi

xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -parse-as-library -O \
    -module-cache-path "$OUTPUT_DIR/module-cache" -emit-library -emit-module \
    -module-name PanefloCore "$SOURCE_ROOT"/Sources/PanefloCore/*.swift \
    -emit-module-path "$OUTPUT_DIR/PanefloCore.swiftmodule" -o "$OUTPUT_DIR/libPanefloCore.dylib"
# shellcheck disable=SC2086
xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -O -D PANEFLO_NATIVE_CHECK $FLAGS \
    -I "$OUTPUT_DIR" -L "$OUTPUT_DIR" -lPanefloCore -Xlinker -rpath -Xlinker "$OUTPUT_DIR" \
    -parse-as-library -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$APP_SOURCES/RuntimeDiagnostics.swift" "$APP_SOURCES/WindowService.swift" \
    "$PROJECT_ROOT/Tools/TileBench.swift" -o "$OUTPUT_DIR/tile-bench"
codesign --force --sign - "$OUTPUT_DIR/libPanefloCore.dylib" "$OUTPUT_DIR/tile-bench"
echo "Built $OUTPUT_DIR/tile-bench from $SOURCE_ROOT${FLAGS:+ ($FLAGS)}"
