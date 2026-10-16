#!/bin/zsh
# Builds a self-contained "YT Downloader.dmg" to hand to other people: the app with yt-dlp,
# ffmpeg, ffprobe and deno bundled inside (no Homebrew needed), plus a drag-to-Applications link.
# Apple silicon Macs only (the bundled tools are arm64 builds).
#   --refresh   re-download the bundled tools to pick up their latest versions
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="YT Downloader"
DMG="build/$APP_NAME.dmg"
STAGING="build/dmg-staging"

./scripts/fetch-tools.sh ${1:-}
./scripts/build-app.sh --bundle-tools

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "build/$APP_NAME.app" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/Read Me First.txt" <<'TXT'
YT Downloader
=============

Install
  Drag "YT Downloader" onto the Applications folder.

First launch
  This app isn't signed with a paid Apple Developer ID, so the first time you open it
  macOS will say it can't verify the app. To allow it (only needed once):

  1. Double-click YT Downloader in Applications, then click "Done" in the warning.
  2. Open System Settings > Privacy & Security.
  3. Scroll down to the message about "YT Downloader" and click "Open Anyway".
  4. Confirm with your password or Touch ID.

  After that it opens normally. The first launch also takes a few extra seconds while it
  sets up its download engine (yt-dlp).

Requirements
  A Mac with Apple silicon (M1 or newer) running macOS 14 Sonoma or later.

Everything the app needs (yt-dlp, ffmpeg, deno) is included, and yt-dlp updates itself
automatically. To check manually, use YT Downloader > Check for yt-dlp Updates.
TXT

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format ULMO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Built: $PWD/$DMG ($(du -h "$DMG" | awk '{print $1}'))"
