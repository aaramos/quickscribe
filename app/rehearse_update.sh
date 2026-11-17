#!/usr/bin/env bash
# Rehearses a whole in-app update on this Mac, with nothing published and the
# real installed QuickScribe left alone:
#
#   1. builds an "old" and a "new" copy of this source as a separate app,
#      "QuickScribe Rehearsal" (bundle id local.quickscribe.rehearsal), so it
#      shares no settings, permissions or keychain items with the real one;
#   2. signs both with CODESIGN_IDENTITY (default "QuickScribe Release"), as a
#      release would be;
#   3. installs the old one in a private Applications folder;
#   4. serves a GitHub-shaped release feed for the new one on 127.0.0.1;
#   5. opens the old one pointed at that feed, and waits for you to choose
#      "Install version <new> and Relaunch" in its menu (the second QuickScribe
#      icon in the menu bar);
#   6. passes when the installed bundle is the new version, still validly signed,
#      and running again from the same path;
#   7. then serves a newer 9.0.2 signed ad-hoc (not with the release identity),
#      reopens the app and waits for a second Install click, and passes only if
#      that download is refused and the installed app is untouched.
#
# macOS asks for the microphone the first time the rehearsal app opens; the
# answer does not matter here. Afterwards:  ./rehearse_update.sh --clean
#
#   REHEARSAL_DIR      where everything goes (default: a fresh temporary folder)
#   REHEARSAL_PORT     the feed's port (default: a free one)
#   REHEARSAL_WAIT     seconds to wait for each click (default 600)
#   REHEARSAL_AUTOCLICK=1  click the menu items through System Events instead of
#                      waiting for you (needs Accessibility for the terminal app)
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"

NAME="QuickScribe Rehearsal"
ID="local.quickscribe.rehearsal"
OLD="9.0.0"
NEW="9.0.1"
PORT="${REHEARSAL_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
WAIT="${REHEARSAL_WAIT:-600}"
STATE="$HOME/Library/Caches/quickscribe-rehearsal-dir"

stop_all() {
    pkill -f -- "/$NAME.app/Contents/MacOS/" 2>/dev/null || true
    if [[ -f "$STATE" ]]; then
        local dir; dir=$(cat "$STATE")
        [[ -f "$dir/server.pid" ]] && kill "$(cat "$dir/server.pid")" 2>/dev/null || true
    fi
}

if [[ "${1:-}" == "--clean" ]]; then
    stop_all
    if [[ -f "$STATE" ]]; then
        dir=$(cat "$STATE"); [[ "$dir" == *rehearsal* && -d "$dir" ]] && rm -rf "$dir"
        rm -f "$STATE"
    fi
    defaults delete "$ID" 2>/dev/null || true
    tccutil reset All "$ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Application Support/$NAME"
    echo "==> rehearsal removed"
    exit 0
fi

export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-QuickScribe Release}"
WORK="${REHEARSAL_DIR:-$(mktemp -d -t quickscribe-rehearsal)}"
mkdir -p "$WORK"
echo "$WORK" > "$STATE"
stop_all

# One source copy per version, with only AppInfo changed. The build cache is
# copied along so the second build is quick.
make_copy() {
    local version=$1 dest="$WORK/src-$1"
    rm -rf "$dest"; mkdir -p "$dest"
    rsync -a --exclude build "$HERE/" "$dest/"
    sed -i '' \
        -e "s/static let displayName = \".*\"/static let displayName = \"$NAME\"/" \
        -e "s/static let bundleID = \".*\"/static let bundleID = \"$ID\"/" \
        -e "s/static let version = \".*\"/static let version = \"$version\"/" \
        "$dest/Sources/QuickScribe/AppInfo.swift"
    echo "==> building $NAME $version"
    (cd "$dest" && ./build_app.sh >"$WORK/build-$version.log" 2>&1) \
        || { echo "FATAL: build $version failed, see $WORK/build-$version.log" >&2; exit 1; }
}
make_copy "$OLD"
make_copy "$NEW"

INSTALLED="$WORK/Applications/$NAME.app"
rm -rf "$WORK/Applications"; mkdir -p "$WORK/Applications"
ditto "$WORK/src-$OLD/build/$NAME.app" "$INSTALLED"

echo "==> feed on http://127.0.0.1:$PORT"
FEED="$WORK/feed"
rm -rf "$FEED"; mkdir -p "$FEED/releases/tag" "$FEED/download/v$NEW"
ZIP="$FEED/download/v$NEW/QuickScribe.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK/src-$NEW/build/$NAME.app" "$ZIP"
SUM=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE=$(stat -f %z "$ZIP")
echo "<html>$NAME $NEW</html>" > "$FEED/releases/tag/v$NEW"
cat > "$FEED/releases/latest" <<JSON
{"tag_name": "v$NEW",
 "html_url": "http://127.0.0.1:$PORT/releases/tag/v$NEW",
 "assets": [{"name": "QuickScribe.zip",
             "browser_download_url": "http://127.0.0.1:$PORT/download/v$NEW/QuickScribe.zip",
             "digest": "sha256:$SUM", "size": $SIZE}]}
JSON
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED" >"$WORK/server.log" 2>&1 &
echo $! > "$WORK/server.pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://127.0.0.1:$PORT/releases/latest" 2>/dev/null | grep -q "\"v$NEW\"" && break
    sleep 0.5
done
curl -fsS "http://127.0.0.1:$PORT/releases/latest" 2>/dev/null | grep -q "\"v$NEW\"" \
    || { echo "FATAL: the feed did not come up on port $PORT, see $WORK/server.log" >&2; exit 1; }

click_install() {   # $1 = version in the menu item
    [[ "${REHEARSAL_AUTOCLICK:-}" == "1" ]] || return 0
    sleep 3
    osascript - "$NAME" "Install version $1 and Relaunch" <<'OSA' >/dev/null
on run argv
    tell application "System Events" to tell process (item 1 of argv)
        click menu bar item 1 of menu bar 1
        delay 1
        click menu item (item 2 of argv) of menu 1 of menu bar item 1 of menu bar 1
    end tell
end run
OSA
    echo "    clicked \"Install version $1 and Relaunch\""
}

echo "==> opening $NAME $OLD"
open --env "QUICKSCRIBE_UPDATE_FEED=http://127.0.0.1:$PORT" "$INSTALLED"
sleep 2
OLD_PID=$(pgrep -f -- "$INSTALLED/Contents/MacOS/" | head -1 || true)
[[ -n "$OLD_PID" ]] || { echo "FATAL: $NAME $OLD did not start" >&2; exit 1; }
echo "    running as pid $OLD_PID"
echo
echo ">>> Open the second QuickScribe icon in the menu bar and choose"
echo ">>> \"Install version $NEW and Relaunch\". Waiting up to $WAIT s."
click_install "$NEW"

deadline=$((SECONDS + WAIT))
while (( SECONDS < deadline )); do
    VERSION_NOW=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)
    PID_NOW=$(pgrep -f -- "$INSTALLED/Contents/MacOS/" | head -1 || true)
    if [[ "$VERSION_NOW" == "$NEW" && -n "$PID_NOW" && "$PID_NOW" != "$OLD_PID" ]]; then
        echo "==> installed bundle is version $VERSION_NOW, running again as pid $PID_NOW"
        codesign --verify --strict --deep "$INSTALLED"
        echo "==> signature: $(codesign -dvv "$INSTALLED" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
        grep -q "GET /download/v$NEW/QuickScribe.zip" "$WORK/server.log" \
            && echo "==> the archive was fetched from the feed"
        if xattr -p com.apple.quarantine "$INSTALLED" >/dev/null 2>&1; then
            echo "    note: the new bundle carries a quarantine flag"
        else
            echo "==> no quarantine flag: no Open Anyway step after the update"
        fi
        echo "PASS: one click downloaded, checked, installed and relaunched $NAME $NEW"
        break
    fi
    sleep 1
done
[[ "${VERSION_NOW:-}" == "$NEW" ]] || { echo "FAIL: no relaunched $NEW within $WAIT s (installed version: ${VERSION_NOW:-?})" >&2; exit 1; }

# A newer build that is not signed by the release identity must never install.
BAD="9.0.2"
echo
echo "==> serving $NAME $BAD signed ad-hoc"
rm -rf "$WORK/bad"; mkdir -p "$WORK/bad" "$FEED/download/v$BAD"
ditto "$WORK/src-$NEW/build/$NAME.app" "$WORK/bad/$NAME.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BAD" -c "Set :CFBundleVersion $BAD" \
    "$WORK/bad/$NAME.app/Contents/Info.plist"
codesign --force -s - "$WORK/bad/$NAME.app" 2>/dev/null
BZIP="$FEED/download/v$BAD/QuickScribe.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK/bad/$NAME.app" "$BZIP"
echo "<html>$NAME $BAD</html>" > "$FEED/releases/tag/v$BAD"
cat > "$FEED/releases/latest" <<JSON
{"tag_name": "v$BAD",
 "html_url": "http://127.0.0.1:$PORT/releases/tag/v$BAD",
 "assets": [{"name": "QuickScribe.zip",
             "browser_download_url": "http://127.0.0.1:$PORT/download/v$BAD/QuickScribe.zip",
             "digest": "sha256:$(shasum -a 256 "$BZIP" | cut -d' ' -f1)", "size": $(stat -f %z "$BZIP")}]}
JSON
pkill -f -- "$INSTALLED/Contents/MacOS/" 2>/dev/null || true
sleep 1
open --env "QUICKSCRIBE_UPDATE_FEED=http://127.0.0.1:$PORT" "$INSTALLED"
sleep 2
echo ">>> Choose \"Install version $BAD and Relaunch\" in the same menu. It must be refused"
echo ">>> (a notice says so and the release page opens). Waiting up to $WAIT s."
click_install "$BAD"
deadline=$((SECONDS + WAIT))
while (( SECONDS < deadline )); do
    grep -q "GET /download/v$BAD/QuickScribe.zip" "$WORK/server.log" && break
    sleep 1
done
grep -q "GET /download/v$BAD/QuickScribe.zip" "$WORK/server.log" \
    || { echo "FAIL: the $BAD archive was never requested" >&2; exit 1; }
sleep 3
VERSION_NOW=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")
AUTH=$(codesign -dvv "$INSTALLED" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [[ "$VERSION_NOW" == "$NEW" && "$AUTH" == "$CODESIGN_IDENTITY" ]] && codesign --verify --strict --deep "$INSTALLED" \
   && pgrep -f -- "$INSTALLED/Contents/MacOS/" >/dev/null; then
    echo "PASS: the ad-hoc $BAD was downloaded and refused; $NEW is still installed, signed by $AUTH, and running"
    exit 0
fi
echo "FAIL: after the refused update the installed app is version $VERSION_NOW, signed by ${AUTH:-nothing}" >&2
exit 1
