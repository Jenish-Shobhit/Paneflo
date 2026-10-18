#!/bin/sh
# Builds the own-window surface latency bench against a source tree and optionally runs it.
#
#   sh Tools/build-surface-bench.sh <output-dir> [--source <tree>] [--runs <n>] [--cards "20 60"]
#
# --source builds the bench against another checkout (for example a scratch worktree at an
# older commit) while always using this tree's Tools/SurfaceBench.swift. --runs launches the
# bench through LaunchServices n times per card count and prints median/p90/min/max.
# The bench shows its own panels briefly. It installs no event tap, posts no global input and
# requests no permission.
set -eu
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Supply an output directory for the surface bench}"
shift
SOURCE_ROOT="$PROJECT_ROOT"
RUNS=0
CARDS="20 60"
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_ROOT="$(CDPATH= cd -- "$2" && pwd)"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --cards) CARDS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
APP_SOURCES="$SOURCE_ROOT/Sources/PanefloApp"

set -- "$APP_SOURCES/RuntimeDiagnostics.swift" "$APP_SOURCES/Capture/CaptureController.swift" \
    "$APP_SOURCES/WindowService.swift" "$APP_SOURCES/DesktopController.swift" "$APP_SOURCES/SampleViews.swift"
if [ -f "$APP_SOURCES/TilePairController.swift" ]; then set -- "$@" "$APP_SOURCES/TilePairController.swift"; fi
if [ -d "$APP_SOURCES/Surfaces" ]; then
    for file in "$APP_SOURCES"/Surfaces/*.swift; do set -- "$@" "$file"; done
fi
FLAGS=""
if grep -rqs "func prewarm()" "$APP_SOURCES"; then FLAGS="-D SURFACE_BENCH_PREWARM"; fi
if grep -rqs "func nativeCheckReplaceOutsideClickMonitor" "$APP_SOURCES"; then FLAGS="$FLAGS -D SURFACE_BENCH_MONITOR_HOOK"; fi
if grep -rqs "protocol PreviewProvider" "$APP_SOURCES"; then FLAGS="$FLAGS -D SURFACE_BENCH_PREVIEWS"; fi
if grep -rqs "protocol DesktopEntryProvider" "$APP_SOURCES"; then FLAGS="$FLAGS -D SURFACE_BENCH_DESKTOP"; fi

xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -parse-as-library -O \
    -module-cache-path "$OUTPUT_DIR/module-cache" -emit-library -emit-module \
    -module-name PanefloCore "$SOURCE_ROOT"/Sources/PanefloCore/*.swift \
    -emit-module-path "$OUTPUT_DIR/PanefloCore.swiftmodule" -o "$OUTPUT_DIR/libPanefloCore.dylib"
# shellcheck disable=SC2086
xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -O -D PANEFLO_NATIVE_CHECK $FLAGS \
    -I "$OUTPUT_DIR" -L "$OUTPUT_DIR" -lPanefloCore -Xlinker -rpath -Xlinker "$OUTPUT_DIR" \
    -parse-as-library -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$@" "$PROJECT_ROOT/Tools/SurfaceBench.swift" -o "$OUTPUT_DIR/surface-bench"
APP="$OUTPUT_DIR/SurfaceBench.app"
mkdir -p "$APP/Contents/MacOS"
cp "$OUTPUT_DIR/surface-bench" "$APP/Contents/MacOS/surface-bench"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>surface-bench</string>
<key>CFBundleIdentifier</key><string>org.paneflo.SurfaceBench</string>
<key>CFBundleName</key><string>SurfaceBench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$OUTPUT_DIR/libPanefloCore.dylib"
codesign --force --sign - "$APP"
echo "Built $APP from $SOURCE_ROOT${FLAGS:+ ($FLAGS)}"

if [ "$RUNS" -gt 0 ]; then
    RUN_DIR="$OUTPUT_DIR/samples"
    rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
    for count in $CARDS; do
        run=1
        while [ "$run" -le "$RUNS" ]; do
            open -W -n "$APP" --args "$RUN_DIR" "$count"
            run=$((run + 1))
        done
    done
    "$OUTPUT_DIR/surface-bench" --report "$RUN_DIR"
fi
