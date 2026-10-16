#!/bin/sh
set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
set -- --build-system native --cache-path "$PROJECT_ROOT/.build/cache" --enable-swift-testing --disable-xctest "$@"
if [ "${PANEFLO_SPM_DISABLE_SANDBOX:-0}" = "1" ]; then
    set -- "$@" --disable-sandbox
fi

# CLT and full Xcode place their bundled testing frameworks in different directories.
# A toolchain that resolves Testing itself can use its normal search paths.
PANEFLO_DEVELOPER_DIRECTORY="${DEVELOPER_DIR:-$(xcode-select --print-path)}"
for PANEFLO_FRAMEWORK_DIRECTORY in \
    "$PANEFLO_DEVELOPER_DIRECTORY/Library/Developer/Frameworks" \
    "$PANEFLO_DEVELOPER_DIRECTORY/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
    "$PANEFLO_DEVELOPER_DIRECTORY/Library/Frameworks"
do
    if [ -d "$PANEFLO_FRAMEWORK_DIRECTORY/Testing.framework" ]; then
        set -- "$@" \
            -Xswiftc -F -Xswiftc "$PANEFLO_FRAMEWORK_DIRECTORY" \
            -Xlinker -F -Xlinker "$PANEFLO_FRAMEWORK_DIRECTORY" \
            -Xlinker -rpath -Xlinker "$PANEFLO_FRAMEWORK_DIRECTORY"
        break
    fi
done

swift test "$@"
