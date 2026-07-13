#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/Codex Usage.app"
MACOS="$APP/Contents/MacOS"

mkdir -p "$MACOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

clang "$ROOT/Sources/main.m" \
  -o "$MACOS/Codex Usage" \
  -fmodules-cache-path="$ROOT/.module-cache" \
  -framework Cocoa \
  -framework CoreServices

echo "Built: $APP"
