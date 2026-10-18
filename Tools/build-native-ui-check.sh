#!/bin/sh
set -eu
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Supply an output directory for the native UI check binary and module}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -parse-as-library \
    -module-cache-path "$OUTPUT_DIR/module-cache" -emit-library -emit-module \
    -module-name PanefloCore "$PROJECT_ROOT"/Sources/PanefloCore/*.swift \
    -emit-module-path "$OUTPUT_DIR/PanefloCore.swiftmodule" -o "$OUTPUT_DIR/libPanefloCore.dylib"
xcrun swiftc -target "$TARGET_TRIPLE" -swift-version 6 -D PANEFLO_NATIVE_CHECK \
    -I "$OUTPUT_DIR" -L "$OUTPUT_DIR" -lPanefloCore -Xlinker -rpath -Xlinker "$OUTPUT_DIR" \
    -parse-as-library -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$PROJECT_ROOT/Sources/PanefloApp/RuntimeDiagnostics.swift" \
    "$PROJECT_ROOT/Sources/PanefloApp/Capture/CaptureController.swift" \
    "$PROJECT_ROOT/Sources/PanefloApp/WindowService.swift" \
    "$PROJECT_ROOT/Sources/PanefloApp/DesktopController.swift" \
    "$PROJECT_ROOT/Sources/PanefloApp/TilePairController.swift" \
    "$PROJECT_ROOT"/Sources/PanefloApp/Design/*.swift \
    "$PROJECT_ROOT"/Sources/PanefloApp/Surfaces/*.swift \
    "$PROJECT_ROOT/Sources/PanefloApp/Input/GlobalShortcutService.swift" \
    "$PROJECT_ROOT/Sources/PanefloApp/SampleViews.swift" \
    "$PROJECT_ROOT/Tools/NativeUICheck.swift" -o "$OUTPUT_DIR/native-ui-check"
APP="$OUTPUT_DIR/NativeUICheck.app"
mkdir -p "$APP/Contents/MacOS"
cp "$OUTPUT_DIR/native-ui-check" "$APP/Contents/MacOS/native-ui-check"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>native-ui-check</string>
<key>CFBundleIdentifier</key><string>org.paneflo.NativeUICheck</string>
<key>CFBundleName</key><string>NativeUICheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$OUTPUT_DIR/libPanefloCore.dylib"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (launch through LaunchServices with an own-window PNG output directory argument)"
