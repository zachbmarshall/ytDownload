# YT Downloader

A simple native macOS app (SwiftUI) that puts a friendly interface on [yt-dlp](https://github.com/yt-dlp/yt-dlp).

- Paste a YouTube link and get a live preview of the video
- Download as **Video** (MP4, MKV, WebM, MOV; choose the max resolution) or **Audio only** (MP3, M4A, WAV, FLAC, Opus; choose the bitrate)
- **Clip mode:** drag the start/end handles on the timeline (or type times like `1:23.5`), preview exactly the clip you'll get, and download only that part
- Embeds the title, artist and thumbnail as cover art
- Shows progress, speed and ETA, and can show the file in Finder when it's done

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15.3 or newer, or just the Command Line Tools (Swift 5.10+). To install the Command Line Tools, run `xcode-select --install`.
- [Homebrew](https://brew.sh), for the tools the app runs behind the scenes

## Build from source

1. Install the command line tools the app uses:

   ```bash
   brew install yt-dlp ffmpeg deno
   ```

   (`deno` is the JavaScript runtime yt-dlp uses to handle YouTube's player challenges.)

2. Clone the repository:

   ```bash
   git clone https://github.com/zachbmarshall/ytDownload.git
   cd ytDownload
   ```

3. Build the app:

   ```bash
   ./scripts/build-app.sh
   ```

   This compiles a release build, draws the icon, and creates `build/YT Downloader.app`. The first build takes a minute or two.

4. Open it, or drag it into `/Applications`:

   ```bash
   open "build/YT Downloader.app"
   ```

To work on the code, `swift run` builds and launches a debug version directly. To open the project in Xcode, run `open Package.swift`.

### Notes

- The app is signed "ad hoc" for your own Mac only. If you copy the built `.app` to another Mac and macOS refuses to open it, right-click it and choose **Open**, or build it on that Mac instead.
- If you get `permission denied` running the script, make it executable: `chmod +x scripts/build-app.sh`.
- yt-dlp and ffmpeg aren't bundled. The app finds them in the usual Homebrew locations (`/opt/homebrew/bin`, `/usr/local/bin`). If they're missing, it shows a setup screen with the install command.

## Make a DMG to share

To give the app to someone who doesn't have Homebrew or any of the tools:

```bash
./scripts/build-dmg.sh
```

This creates `build/YT Downloader.dmg` (about 120 MB). It contains the app with **yt-dlp, ffmpeg, ffprobe and deno bundled inside**, an Applications shortcut to drag onto, and a "Read Me First" note. The recipient doesn't need to install anything else.

- **Where the tools come from:** `scripts/fetch-tools.sh` downloads standalone builds of yt-dlp (GitHub), deno (GitHub) and ffmpeg/ffprobe ([martin-riedl.de](https://ffmpeg.martin-riedl.de)). It checks each against its publisher's SHA-256 checksum and caches them in `build/vendor`. Use `./scripts/build-dmg.sh --refresh` to pick up newer versions.
- **yt-dlp updates itself:** on first launch the app unpacks yt-dlp into `~/Library/Application Support/YT Downloader`. It checks for a newer yt-dlp once a day; **YT Downloader > Check for yt-dlp Updates** checks right away.
- **Apple silicon only:** the bundled tools are arm64 builds, so the DMG won't run on Intel Macs.
- **First launch on someone else's Mac:** the app isn't signed with a paid Apple Developer ID, so macOS blocks it the first time. The recipient opens it once, clicks **Done**, then goes to **System Settings > Privacy & Security** and clicks **Open Anyway**. The "Read Me First" note in the DMG walks them through it. Removing this step requires an [Apple Developer Program](https://developer.apple.com/programs/) membership to sign and notarize the app.
- **Licenses:** yt-dlp is public domain (Unlicense), deno is MIT, and the ffmpeg builds are GPL. If you distribute the DMG publicly, the GPL requires making ffmpeg's source available, for example by linking to [ffmpeg.org](https://ffmpeg.org/download.html) and the [build scripts](https://git.martin-riedl.de/ffmpeg/build-script).

## Using clips

1. Load a video and turn on **Download only a clip**.
2. Drag the blue handles on the timeline. The player jumps to show the frame under each handle.
3. Or play the video and use the ⤓ buttons to set the start or end at the current playhead.
4. Click **Preview Clip** to play exactly the selected range (turn on **Loop** to repeat it). Click **Play Ending** to check the end point.
5. Click **Download**. With **Frame-accurate cuts** on, the clip is re-encoded so it starts exactly where you chose. Turn it off for faster, keyframe-aligned cuts.

## Troubleshooting

- **Downloads start failing:** YouTube changes often. Update yt-dlp with `brew upgrade yt-dlp`.
- **"Show details"** (under the Download button) shows the full yt-dlp output and the exact command that was run.
- **MP4 above 1080p:** YouTube only serves VP9/AV1 at those resolutions, so some players may not play the file. Pick 1080p, or use MKV with a player like IINA or VLC.

## Project layout

```
Sources/YTDownloader/
  YTDownloaderApp.swift   App entry point
  ContentView.swift       URL bar, options panel, download/progress UI
  PreviewViews.swift      Video player, trim slider, clip controls
  AppModel.swift          State, yt-dlp argument building, progress parsing
  Models.swift            yt-dlp JSON model, format options, time helpers
  Tools.swift             Finding yt-dlp/ffmpeg (bundled or Homebrew), running processes
  YtDlpUpdater.swift      Unpacking and auto-updating the bundled yt-dlp
  DebugHooks.swift        Debug-only automation used for testing
scripts/
  build-app.sh            Builds and packages the .app bundle (--bundle-tools to include the tools)
  build-dmg.sh            Builds the shareable DMG with everything bundled
  fetch-tools.sh          Downloads and verifies the standalone tools for bundling
  make-icon.swift         Draws the app icon
```

Only download content you have the right to download. Respect YouTube's Terms of Service and copyright.
