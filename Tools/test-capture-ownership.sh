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
xcrun swiftc \
    -parse-as-library \
    -module-cache-path "$TEMP_DIR/module-cache" \
    -sanitize=address \
    "$DIAGNOSTICS_SOURCE" \
    "$TEMP_DIR/CaptureOwnershipCheck.swift" \
    -o "$TEMP_DIR/capture-ownership-check"
"$TEMP_DIR/capture-ownership-check"
