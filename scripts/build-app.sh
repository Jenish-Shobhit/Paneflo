#!/bin/sh
set -eu

CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
set -- --build-system native --cache-path "$PROJECT_ROOT/.build/cache"
# Some restricted executor environments cannot nest SwiftPM's manifest sandbox.
# This opt-in applies only to the locally authored, dependency-free package.
if [ "${PANEFLO_SPM_DISABLE_SANDBOX:-0}" = "1" ]; then
    set -- "$@" --disable-sandbox
fi
swift build "$@" --configuration "$CONFIGURATION" --product Paneflo
BIN_DIRECTORY="$(swift build "$@" --configuration "$CONFIGURATION" --show-bin-path)"
APP_DIRECTORY="$PROJECT_ROOT/build/Paneflo.app"
mkdir -p "$APP_DIRECTORY/Contents/MacOS" "$APP_DIRECTORY/Contents/Resources"
install -m 755 "$BIN_DIRECTORY/Paneflo" "$APP_DIRECTORY/Contents/MacOS/Paneflo"
install -m 644 Resources/Info.plist "$APP_DIRECTORY/Contents/Info.plist"
codesign --force --sign - "$APP_DIRECTORY"
codesign --verify --strict --verbose=2 "$APP_DIRECTORY"
printf 'Built local developer preview: %s\n' "$APP_DIRECTORY"
printf 'Launch: open "%s"\n' "$APP_DIRECTORY"
