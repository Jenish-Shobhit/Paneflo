#!/bin/sh
# Measures CaptureController snapshot/live latency, teardown, and cache bytes against Paneflo
# fixture windows only (never the user's windows). Requires Screen Recording for the calling
# terminal; without it the bench reports "not-granted" and exits 0.
#
#   sh Tools/measure-capture.sh [WINDOW_COUNT]
set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COUNT="${1:-6}"
FIXTURE="$PROJECT_ROOT/build/PanefloFixture.app/Contents/MacOS/PanefloFixture"
[ -x "$FIXTURE" ] || sh "$PROJECT_ROOT/Tools/build-fixture.sh" >/dev/null

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paneflo-capture-bench.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
cat "$PROJECT_ROOT/Sources/PanefloApp/Capture/CaptureController.swift" "$PROJECT_ROOT/Tools/CaptureBench.swift" \
    > "$TEMP_DIR/CaptureBench.swift"
xcrun swiftc -target "$TARGET_TRIPLE" -parse-as-library -O \
    -module-cache-path "$TEMP_DIR/module-cache" -emit-library -emit-module \
    -module-name PanefloCore "$PROJECT_ROOT"/Sources/PanefloCore/*.swift \
    -emit-module-path "$TEMP_DIR/PanefloCore.swiftmodule" -o "$TEMP_DIR/libPanefloCore.dylib"
xcrun swiftc -target "$TARGET_TRIPLE" -O -parse-as-library \
    -I "$TEMP_DIR" -L "$TEMP_DIR" -lPanefloCore -Xlinker -rpath -Xlinker "$TEMP_DIR" \
    -module-cache-path "$TEMP_DIR/module-cache" \
    "$PROJECT_ROOT/Sources/PanefloApp/RuntimeDiagnostics.swift" "$TEMP_DIR/CaptureBench.swift" \
    -o "$TEMP_DIR/capture-bench"
"$TEMP_DIR/capture-bench" "$FIXTURE" "$COUNT" ${PANEFLO_BENCH_DIAGNOSTICS:+--diagnostics} ${PANEFLO_BENCH_PREWARM:+--prewarm}
