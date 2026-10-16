#!/bin/sh
set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_SOURCE="$PROJECT_ROOT/Tools/CaptureOwnershipCheck.swift"
CAPTURE_SOURCE="$PROJECT_ROOT/Sources/PanefloApp/Capture/CaptureController.swift"
DIAGNOSTICS_SOURCE="$PROJECT_ROOT/Sources/PanefloApp/RuntimeDiagnostics.swift"

for source in "$TEST_SOURCE" "$CAPTURE_SOURCE" "$DIAGNOSTICS_SOURCE"; do
    if [ ! -f "$source" ]; then
        echo "Missing capture ownership test input: $source" >&2
        exit 1
    fi
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paneflo-capture-ownership.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

# These helpers are fileprivate in production. Concatenating the test entrypoint
# into a temporary copy keeps production visibility and sources untouched.
cat "$CAPTURE_SOURCE" "$TEST_SOURCE" > "$TEMP_DIR/CaptureOwnershipCheck.swift"
TARGET_TRIPLE="$(uname -m)-apple-macosx14.0"
# Capture's thumbnail identities/accounting use the actual core module. Build that
# small dependency locally without SwiftPM state or third-party packages.
xcrun swiftc -target "$TARGET_TRIPLE" -parse-as-library -sanitize=address \
    -module-cache-path "$TEMP_DIR/module-cache" -emit-library -emit-module \
    -module-name PanefloCore "$PROJECT_ROOT"/Sources/PanefloCore/*.swift \
    -emit-module-path "$TEMP_DIR/PanefloCore.swiftmodule" -o "$TEMP_DIR/libPanefloCore.dylib"
xcrun swiftc -target "$TARGET_TRIPLE" \
    -I "$TEMP_DIR" -L "$TEMP_DIR" -lPanefloCore -Xlinker -rpath -Xlinker "$TEMP_DIR" \
    -parse-as-library \
    -module-cache-path "$TEMP_DIR/module-cache" \
    -sanitize=address \
    "$DIAGNOSTICS_SOURCE" \
    "$TEMP_DIR/CaptureOwnershipCheck.swift" \
    -o "$TEMP_DIR/capture-ownership-check"
"$TEMP_DIR/capture-ownership-check"
