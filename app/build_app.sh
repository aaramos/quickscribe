#!/usr/bin/env bash
# Assembles the menu-bar app bundle.
# App display name + bundle id + version live in ONE place:
#   Sources/QuickScribe/AppInfo.swift (displayName, bundleID, version)
# This script extracts them; renaming the app = edit AppInfo.swift, rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=$(sed -n 's/.*static let displayName = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
BUNDLE_ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
[[ -n "$APP_NAME" && -n "$BUNDLE_ID" && -n "$VERSION" ]] || { echo "FATAL: could not read name/bundle id/version from AppInfo.swift" >&2; exit 1; }

echo "==> swift build -c release"
swift build -c release --product QuickScribe

BIN=".build/release/QuickScribe"
APP="build/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> assembling $APP"
# Kill any previous instance of THIS bundle BEFORE swapping it: a stale running
# app with a dead tap next to a fresh build is exactly the "hotkeys don't
# work" ghost. Match the full bundle path, never the bare name — this app and
# the original QuickScribe share an executable name, and a name match once
# killed a live original install during a rebuild.
STALE=$(pgrep -f -- "$PWD/$APP/Contents/MacOS/" || true)
if [[ -n "$STALE" ]]; then
    echo "==> killing stale instance(s) of this build: $(echo "$STALE" | tr '\n' ' ')"
    echo "$STALE" | xargs kill || true
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
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>          <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>   <string>27.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>${APP_NAME} listens while you hold the hotkey. Your voice is turned into text on this Mac, or at the address you set in Settings if you switch speech to a custom service.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>${APP_NAME} uses Apple's on-device speech recognition to turn your voice into text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APP_NAME} pastes dictated text into the app you are using.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>${APP_NAME} reaches the speech and cleanup service you set in Settings, which may live on this Mac or your local network.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
</dict>
</plist>
PLIST

# Ad-hoc by default, so a build carries nobody's name. Every ad-hoc rebuild looks like a
# new app to macOS, which drops its Microphone and Accessibility grants. To keep them while
# developing, set CODESIGN_IDENTITY to a signing certificate of your own.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY-}"

ENT_FILE="$(mktemp).entitlements"
cat > "$ENT_FILE" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key> <true/>
    <key>com.apple.security.automation.apple-events</key> <true/>
    <key>com.apple.security.network.client</key> <true/>
</dict>
</plist>
ENT

echo "==> codesign (${CODESIGN_IDENTITY:-ad-hoc})"
codesign --force --entitlements "$ENT_FILE" \
    -s "${CODESIGN_IDENTITY:-"-"}" "$APP"
rm -f "$ENT_FILE"

echo "==> built: $(cd build && pwd)/${APP_NAME}.app"
codesign -dv "$APP" 2>&1 | sed -n '1,4p'
