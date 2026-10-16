#!/bin/zsh
# Downloads standalone Apple silicon builds of the tools the app runs, verifying each
# against its publisher's SHA-256 checksum, into build/vendor/.
#   yt-dlp  – github.com/yt-dlp/yt-dlp (folder build, kept zipped: starts much faster than the single-file one)
#   ffmpeg, ffprobe – ffmpeg.martin-riedl.de (static macOS builds)
#   deno    – github.com/denoland/deno (JavaScript runtime yt-dlp needs for YouTube)
# Pass --refresh to re-download even if tools are already present.
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="build/vendor"
if [[ "${1:-}" != "--refresh" && -f "$VENDOR/.complete" ]]; then
    echo "Tools already downloaded (use --refresh to update):"
    cat "$VENDOR/.complete"
    exit 0
fi

rm -rf "$VENDOR"
mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# verify <file> <expected sha256>
verify() {
    local actual
    actual="$(shasum -a 256 "$1" | awk '{print $1}')"
    if [[ "$actual" != "$2" ]]; then
        echo "Checksum mismatch for $1" >&2
        echo "  expected $2" >&2
        echo "  got      $actual" >&2
        exit 1
    fi
}

echo "==> yt-dlp"
YTDLP_BASE="https://github.com/yt-dlp/yt-dlp/releases/latest/download"
curl -fsSL -o "$TMP/yt-dlp_macos.zip" "$YTDLP_BASE/yt-dlp_macos.zip"
curl -fsSL -o "$TMP/SHA2-256SUMS" "$YTDLP_BASE/SHA2-256SUMS"
verify "$TMP/yt-dlp_macos.zip" "$(awk '$2 == "yt-dlp_macos.zip" {print $1}' "$TMP/SHA2-256SUMS")"
# The app ships this zip as a resource and unpacks it on first launch (see YtDlpUpdater.swift).
cp "$TMP/yt-dlp_macos.zip" "$VENDOR/yt-dlp_macos.zip"
mkdir -p "$TMP/yt-dlp"
ditto -x -k "$TMP/yt-dlp_macos.zip" "$TMP/yt-dlp"
"$TMP/yt-dlp/yt-dlp_macos" --version > "$VENDOR/yt-dlp-version.txt"

echo "==> deno"
DENO_URL="https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
curl -fsSL -o "$TMP/deno.zip" "$DENO_URL"
curl -fsSL -o "$TMP/deno.sha" "$DENO_URL.sha256sum"
verify "$TMP/deno.zip" "$(awk '{print $1}' "$TMP/deno.sha")"
ditto -x -k "$TMP/deno.zip" "$VENDOR"

echo "==> ffmpeg + ffprobe"
FF_SITE="https://ffmpeg.martin-riedl.de"
# Newest *release* build folder (snapshot folders are named N-xxxx instead of a version number).
FF_DIR="$(curl -fsSL "$FF_SITE/" | grep -oE '/download/macos/arm64/[0-9]+_[0-9]+\.[0-9]+(\.[0-9]+)?/' | sort -t_ -k1,1 -r | head -1)"
if [[ -z "$FF_DIR" ]]; then
    echo "Couldn't find an ffmpeg release build on $FF_SITE" >&2
    exit 1
fi
for tool in ffmpeg ffprobe; do
    curl -fsSL -o "$TMP/$tool.zip" "$FF_SITE$FF_DIR$tool.zip"
    curl -fsSL -o "$TMP/$tool.sha" "$FF_SITE$FF_DIR$tool.zip.sha256"
    verify "$TMP/$tool.zip" "$(awk '{print $1}' "$TMP/$tool.sha")"
    ditto -x -k "$TMP/$tool.zip" "$VENDOR"
done

chmod +x "$VENDOR/deno" "$VENDOR/ffmpeg" "$VENDOR/ffprobe"
# These were just downloaded by curl, so they aren't quarantined, but be explicit.
xattr -dr com.apple.quarantine "$VENDOR" 2>/dev/null || true

{
    echo "yt-dlp  $(cat "$VENDOR/yt-dlp-version.txt")"
    echo "ffmpeg  $("$VENDOR/ffmpeg" -version | head -1 | awk '{print $3}')"
    echo "deno    $("$VENDOR/deno" --version | head -1 | awk '{print $2}')"
} > "$VENDOR/.complete"
cat "$VENDOR/.complete"
echo "Done: $PWD/$VENDOR"
