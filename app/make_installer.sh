#!/usr/bin/env bash
# Builds the drag-to-Applications installer: build/QuickScribe.dmg
set -euo pipefail
cd "$(dirname "$0")"

./build_app.sh

APP_NAME=$(sed -n 's/.*static let displayName = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
DMG="build/${APP_NAME// /-}.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE:?}"' EXIT

cp -R "build/${APP_NAME}.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<README
Installing ${APP_NAME}

1. Drag ${APP_NAME} to Applications.
2. Open it from Applications. macOS will block it the first time. Go to System Settings >
   Privacy & Security, scroll down and click Open Anyway.
3. Grant Microphone and Accessibility when asked, then quit and reopen the app.
4. Look for the icon in the menu bar. There's no window.

Needs an Apple Silicon Mac on macOS 27. Turn on Apple Intelligence for AI cleanup.
README

rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -format ULFO "$DMG"
hdiutil verify -quiet "$DMG"
echo "==> built: $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
