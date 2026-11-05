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

What it needs, before you start:
- An Apple Silicon Mac running macOS 27
- Apple Intelligence turned on, for the AI cleanup. Dictation still works without it,
  with only the basic tidy-up.

1. Drag ${APP_NAME} to Applications.
2. Open it from Applications. macOS will block it the first time: this app is free and
   open source, and it is not signed with a paid Apple Developer ID, so macOS cannot
   check who made it. That block is macOS doing its job. Try opening the app once more
   first: "Open Anyway" only appears in System Settings after a launch attempt has been
   blocked, and it does not stay on screen for long, so open System Settings right after
   a blocked attempt and click it. If you cannot see it where you are, search
   "Open Anyway" in System Settings. It is a one-time step.
3. Grant Microphone and Accessibility when asked. On macOS 27, Accessibility lives
   under System Settings > Device Control and Data Access. Then quit and reopen the app.
4. Look for the icon in the menu bar. There is no window. Hold control-command to talk,
   release to insert.

Updating:
The app asks GitHub at launch and once a day. When a newer version is out you get one
short notice on screen and the menu grows an "Update available: version X" item that
links to the release page; the icon itself does not change. The app never downloads or
installs anything itself. To update: quit the app, download
the new disk image from the release page, drag the app to Applications to replace the
old one, and reopen. macOS may ask for Microphone and Accessibility again after an
update: switch them back on if the hotkeys stop working, and if a switch already looks
on, turn it off and on again.

Your words stay on this Mac unless you turn on a custom service in Settings. With a
custom address, only the routes you switch (speech, cleanup, or both) go to that
address, plus your API key when the service asks for one. With no address, nothing
leaves the Mac except the version check at launch and once a day, which sends only the
app name and version; like any web request, it lets GitHub see your network address.
README

rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -format ULFO "$DMG"
hdiutil verify -quiet "$DMG"
echo "==> built: $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
