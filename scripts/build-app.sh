#!/bin/zsh
# Builds a release binary and wraps it in "YT Downloader.app".
#   --bundle-tools   also copy yt-dlp, ffmpeg, ffprobe and deno from build/vendor
#                    (see scripts/fetch-tools.sh) into the app, so it needs no Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_TOOLS=false
[[ "${1:-}" == "--bundle-tools" ]] && BUNDLE_TOOLS=true

APP_NAME="YT Downloader"
APP="build/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/YTDownloader"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YTDownloader"

# App icon
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.local.ytdownloader</string>
    <key>CFBundleExecutable</key><string>YTDownloader</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if $BUNDLE_TOOLS; then
    VENDOR="build/vendor"
    if [[ ! -f "$VENDOR/.complete" ]]; then
        echo "No tools in $VENDOR. Run scripts/fetch-tools.sh first." >&2
        exit 1
    fi
    HELPERS="$APP/Contents/Helpers"
    mkdir -p "$HELPERS"
    cp "$VENDOR/ffmpeg" "$VENDOR/ffprobe" "$VENDOR/deno" "$HELPERS/"
    # yt-dlp ships zipped; the app unpacks it to Application Support on first launch,
    # where it can also update itself.
    cp "$VENDOR/yt-dlp_macos.zip" "$VENDOR/yt-dlp-version.txt" "$APP/Contents/Resources/"
fi

# Ad-hoc sign so macOS will launch it. Not --deep: the bundled ffmpeg and deno keep their
# publishers' signatures.
codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
