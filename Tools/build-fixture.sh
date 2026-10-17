#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=$(xcrun --show-sdk-path)
SWIFTC=$(xcrun --find swiftc)
TARGET_TRIPLE="$(uname -m)-apple-macosx26.0"
APP_DIR="$ROOT_DIR/build/PanefloFixture.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

mkdir -p "$MACOS" "$ROOT_DIR/.build/fixture-module-cache"
"$SWIFTC" -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" -module-cache-path "$ROOT_DIR/.build/fixture-module-cache" \
  -O -parse-as-library -framework AppKit -framework Foundation \
  "$ROOT_DIR/Tools/PanefloFixture.swift" -o "$MACOS/PanefloFixture"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PanefloFixture</string>
  <key>CFBundleIdentifier</key><string>dev.paneflo.fixture</string>
  <key>CFBundleName</key><string>Paneflo Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.paneflo.fixture "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
printf 'Built and verified %s\n' "$APP_DIR"
