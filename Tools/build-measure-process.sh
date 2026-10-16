#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=$(xcrun --show-sdk-path)
SWIFTC=$(xcrun --find swiftc)
TARGET_TRIPLE="$(uname -m)-apple-macosx14.0"
OUT_DIR="$ROOT_DIR/dev_acrtifacts/runtime"
mkdir -p "$ROOT_DIR/.build/measure-module-cache" "$OUT_DIR"
"$SWIFTC" -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" -module-cache-path "$ROOT_DIR/.build/measure-module-cache" \
  -O "$ROOT_DIR/Tools/MeasureProcess.swift" -o "$OUT_DIR/measure-process"
printf 'Built %s\n' "$OUT_DIR/measure-process"
