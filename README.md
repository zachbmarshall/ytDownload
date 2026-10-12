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
  Tools.swift             Finding yt-dlp/ffmpeg, running processes
  DebugHooks.swift        Debug-only automation used for testing
scripts/
  build-app.sh            Builds and packages the .app bundle
  make-icon.swift         Draws the app icon
```

Only download content you have the right to download. Respect YouTube's Terms of Service and copyright.
