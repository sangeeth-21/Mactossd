#!/usr/bin/env bash
# Builds PhotoBridge.app into ./build. Usage:
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh --run      # build and launch
#   SIGN_IDENTITY="Apple Development: You (TEAMID)" scripts/build-app.sh
#     (a stable signing identity keeps Photos / Full Disk Access permissions across rebuilds)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PhotoBridge.app"
echo "▸ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/PhotoBridge"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  echo "▸ Rendering icon"
  ICONSET="$(swift scripts/make-icon.swift build)"
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET"
  cp build/Logo.png Resources/Logo.png
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing"
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"

echo "✓ Built $(pwd)/$APP"
if [[ "${1:-}" == "--run" ]]; then
  open "$APP"
fi
