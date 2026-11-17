#!/usr/bin/env bash
# Builds everything a release publishes, and checks it, but publishes nothing:
#   build/QuickScribe.dmg   the drag-to-Applications disk image, for first installs
#   build/QuickScribe.zip   the signed app, zipped, for the in-app installer
#
# The in-app installer accepts a download only when the new app meets the running
# app's own designated requirement: this bundle id, signed by the same certificate.
# So a release must be signed with the release identity, never ad-hoc, and this
# script refuses to build one that is not. See RELEASING.md for the whole release.
#
#   CODESIGN_IDENTITY   the signing identity (default "QuickScribe Release")
set -euo pipefail
cd "$(dirname "$0")"

export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-QuickScribe Release}"
[[ "$CODESIGN_IDENTITY" != "-" ]] || { echo "FATAL: a release cannot be ad-hoc signed" >&2; exit 1; }

APP_NAME=$(sed -n 's/.*static let displayName = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
BUNDLE_ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/QuickScribe/AppInfo.swift)
APP="build/${APP_NAME}.app"
ZIP="build/${APP_NAME// /-}.zip"
DMG="build/${APP_NAME// /-}.dmg"

./make_installer.sh

echo "==> checking the signature"
codesign --verify --strict --deep "$APP"
DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
case "$DR" in
    *"identifier \"$BUNDLE_ID\""*"certificate leaf"*) ;;
    *) echo "FATAL: the designated requirement names no certificate: $DR" >&2
       echo "       (an ad-hoc build cannot be installed by the in-app updater)" >&2; exit 1 ;;
esac
echo "    $DR"

echo "==> zipping the app for the in-app installer"
rm -f "$ZIP"
# ditto keeps the bundle's symlinks, permissions and signature; --keepParent puts
# ${APP_NAME}.app at the top of the archive, which is what the installer expects.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Unpack it the way the installer will and check it again: what a friend's copy
# accepts is what is in the zip, not what is in build/.
CHECK=$(mktemp -d)
trap 'rm -rf "${CHECK:?}"' EXIT
ditto -x -k "$ZIP" "$CHECK"
[[ "$(ls "$CHECK")" == "${APP_NAME}.app" ]] || { echo "FATAL: the zip must hold ${APP_NAME}.app alone" >&2; exit 1; }
codesign --verify --strict --deep -R="$DR" "$CHECK/${APP_NAME}.app"
GOT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CHECK/${APP_NAME}.app/Contents/Info.plist")
[[ "$GOT" == "$VERSION" ]] || { echo "FATAL: zip holds version $GOT, AppInfo says $VERSION" >&2; exit 1; }

echo "==> ready to publish version $VERSION"
echo "    $DMG  $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    $ZIP  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
echo "Nothing has been published. When you are ready (see RELEASING.md):"
echo "    git tag v$VERSION && git push origin v$VERSION"
echo "    gh release create v$VERSION $DMG $ZIP --title \"$APP_NAME $VERSION\" --notes-file <notes.md>"
