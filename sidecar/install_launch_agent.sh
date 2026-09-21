#!/usr/bin/env bash
# Install the sidecar LaunchAgent from the repo template.
# Why a script: launchd does not expand $HOME or ~ inside plist strings
# (a literal "$HOME/..." job dies with exit 78 EX_CONFIG), so the repo
# keeps a template with __REPO__ / __HOME__ placeholders and this script
# renders it with the real absolute paths for the current machine.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"          # .../quickscribe/sidecar
REPO="$(dirname "$HERE")"                       # repo root
LABEL="com.quickscribe.sidecar"
TPL="$HERE/com.quickscribe.sidecar.plist"
OUT="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

mkdir -p "$HOME/Library/Logs/quickscribe" "$HOME/Library/LaunchAgents"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" "$TPL" > "$OUT.tmp"
plutil -lint "$OUT.tmp" >/dev/null
mv "$OUT.tmp" "$OUT"

# Reload idempotently (bootout is allowed to fail on first install).
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$OUT"
echo "installed: $OUT"
launchctl print "gui/$UID_NUM/$LABEL" | sed -n '1,8p'
