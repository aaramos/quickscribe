#!/usr/bin/env bash
# Assembles the menu-bar app bundle.
# App display name + bundle id live in ONE place:
#   Sources/QuickScribe/AppInfo.swift (displayName, bundleID)
# This script extracts them; renaming the app = edit AppInfo.swift, rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=$(sed -n 's/.*static let displayName = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
BUNDLE_ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
[[ -n "$APP_NAME" && -n "$BUNDLE_ID" ]] || { echo "FATAL: could not read name/bundle id from AppInfo.swift" >&2; exit 1; }

echo "==> swift build -c release"
swift build -c release --product QuickScribe

BIN=".build/release/QuickScribe"
APP="build/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> assembling $APP"
# Kill any previous instance BEFORE swapping the bundle: a stale running
# app with a dead tap next to a fresh build is exactly the "hotkeys don't
# work" ghost from t_49e2302f.
if pgrep -x "$APP_NAME" >/dev/null; then
    echo "==> killing stale $APP_NAME instance(s): $(pgrep -x "$APP_NAME" | tr '\n' ' ')"
    pkill -x "$APP_NAME" || true
    sleep 1
fi
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>      <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>       <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>       <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>LSMinimumSystemVersion</key>   <string>27.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>${APP_NAME} listens while you hold the hotkey and turns your voice into text on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>${APP_NAME} uses Apple's on-device speech recognition to turn your voice into text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APP_NAME} pastes dictated text into the app you are using.</string>
</dict>
</plist>
PLIST

# Stable dev identity by default: ad-hoc signs a NEW cdhash every rebuild,
# which resets TCC (Mic/Accessibility) grants and kills the hotkey tap.
# "Pure Voice Local Development" keeps grants stable across rebuilds.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY-Pure Voice Local Development}"

ENT_FILE="$(mktemp).entitlements"
cat > "$ENT_FILE" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key> <true/>
    <key>com.apple.security.automation.apple-events</key> <true/>
</dict>
</plist>
ENT

echo "==> codesign (${CODESIGN_IDENTITY:-ad-hoc})"
codesign --force --entitlements "$ENT_FILE" \
    -s "${CODESIGN_IDENTITY:-"-"}" "$APP"
rm -f "$ENT_FILE"

echo "==> built: $(cd build && pwd)/${APP_NAME}.app"
codesign -dv "$APP" 2>&1 | sed -n '1,4p'
