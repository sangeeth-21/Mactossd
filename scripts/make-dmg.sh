#!/usr/bin/env bash
# Builds PhotoBridge.app and packages it into a drag-to-install DMG:  build/PhotoBridge-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/PhotoBridge-${VERSION}.dmg"
STAGE="build/dmg-stage"

echo "▸ Staging installer"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/PhotoBridge.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp build/AppIcon.icns "$STAGE/.VolumeIcon.icns"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
PhotoBridge ${VERSION}

Install: drag PhotoBridge onto the Applications folder.

First launch: right-click PhotoBridge in Applications and choose Open
(it is not from the App Store, so macOS asks once).

Permissions:
 • Photos access: asked on first launch.
 • People filter: System Settings › Privacy & Security › Full Disk Access › add PhotoBridge.
 • iPhone: connect with a cable, unlock it and tap "Trust".

Safety: PhotoBridge never deletes anything unless you click Delete and confirm.
It never changes or deletes anything on your iPhone. Copies are full-quality originals.
TXT

echo "▸ Creating disk image"
hdiutil create -volname "PhotoBridge" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
# Custom volume icon (best effort).
if command -v SetFile >/dev/null; then
  TMP_RW="build/tmp-rw.dmg"
  hdiutil convert "$DMG" -format UDRW -o "$TMP_RW" -ov >/dev/null
  MNT=$(hdiutil attach "$TMP_RW" -nobrowse -noverify | awk -F'\t' '/\/Volumes\// {print $NF}')
  SetFile -a C "$MNT" || true
  hdiutil detach "$MNT" -quiet
  rm -f "$DMG"
  hdiutil convert "$TMP_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -f "$TMP_RW"
fi
rm -rf "$STAGE"
codesign --force --sign "${SIGN_IDENTITY:--}" "$DMG" >/dev/null 2>&1 || true
hdiutil verify "$DMG" >/dev/null && echo "✓ Verified"
echo "✓ Installer: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
