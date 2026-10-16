import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case fetching
        case ready
        case downloading
        case finished
        case failed(String)
    }

    // MARK: Input / metadata
    var urlText = ""
    var phase: Phase = .idle
    var info: VideoInfo?
    var fetchError: String?

    // MARK: Preview / trimming
    let player = AVPlayer()
    var currentTime: Double = 0
    var isPlaying = false
    enum PreviewState { case unavailable, loading, ready, failed }
    var previewState: PreviewState = .unavailable
    var previewAvailable: Bool { previewState == .ready }
    private var previewTask: Task<Void, Never>?
    private var storyboard: Storyboard?
    private var storyboardSheets: [Int: CGImage] = [:]
    private var storyboardTask: Task<Void, Never>?
    var trimEnabled = false
    var clipStart: Double = 0
    var clipEnd: Double = 0
    var loopClip = false
    private var playingClip = false
    private var timeObserver: Any?
    // "Chase" seeking: at most one seek in flight; newer targets wait for it to finish.
    private var pendingSeek: (time: CMTime, exact: Bool)?
    private var isSeeking = false

    var duration: Double { info?.duration ?? 0 }
    var clipLength: Double { max(0, clipEnd - clipStart) }
    var canTrim: Bool { duration > 0 && info?.isLive != true }
    /// YouTube occasionally serves only a single 360p stream; a re-fetch usually returns the full set.
    var limitedFormats: Bool {
        guard let info else { return false }
        return (info.videoHeights.first ?? 0) <= 360 && (info.formats ?? []).filter(\.hasVideo).count <= 2
    }

    // MARK: Options
    var mode: DownloadMode = .video
    var maxHeight: Int? = nil            // nil = best available
    var container: VideoContainer = .mp4
    var audioFormat: AudioFormat = .mp3
    var audioBitrate: AudioBitrate = .best
    var embedMetadata = true
    var embedThumbnail = true
    var preciseCuts = true
    var outputFolder: URL {
        didSet { UserDefaults.standard.set(outputFolder.path, forKey: "outputFolder") }
    }

    // MARK: Download state
    var progress: Double?                 // 0...1, nil = indeterminate
    var statusText = ""
    var speedText = ""
    var etaText = ""
    var downloadedFile: URL?
    var log: [String] = []
    private var activeProcess: CLIProcess?
    private var streamCount = 1
    private var streamIndex = 0
    private var lastError: String?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "outputFolder"),
           FileManager.default.fileExists(atPath: saved) {
            outputFolder = URL(fileURLWithPath: saved)
        } else {
            outputFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    var isBusy: Bool { phase == .fetching || phase == .downloading }

    // MARK: - Fetching

    func fetch() async {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        if Tools.hasBundledTools && Tools.ytdlp == nil {
            phase = .fetching
            statusText = "Setting up yt-dlp (first launch only)…"
        }
        await YtDlpUpdater.ensureReady()
        guard let ytdlp = Tools.ytdlp else {
            fetchError = "yt-dlp was not found. Install it with: brew install yt-dlp"
            return
        }
        player.pause()
        previewTask?.cancel()
        loadStoryboard(nil)
        player.replaceCurrentItem(with: nil)
        previewState = .unavailable
        info = nil
        fetchError = nil
        downloadedFile = nil
        phase = .fetching
        statusText = "Fetching video info…"

        let proc = CLIProcess()
        activeProcess = proc
        defer { activeProcess = nil }
        do {
            let result = try await proc.run(
                ytdlp,
                arguments: ["-J", "--no-playlist", "--no-warnings", "--color", "never", "--socket-timeout", "20", url],
                captureStdout: true
            )
            guard result.status == 0 else {
                phase = .idle
                fetchError = Self.friendlyError(result.stderr) ?? "yt-dlp exited with code \(result.status)."
                return
            }
            let data = result.stdout
            let decoded = try await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(VideoInfo.self, from: data)
            }.value
            load(decoded)
        } catch {
            phase = .idle
            fetchError = "Couldn't read video info: \(error.localizedDescription)"
        }
    }

    private func load(_ info: VideoInfo) {
        self.info = info
        phase = .ready
        statusText = ""
        progress = nil
        clipStart = 0
        clipEnd = info.duration ?? 0
        trimEnabled = false
        currentTime = 0
        if let h = maxHeight, !info.videoHeights.contains(h) { maxHeight = nil }

        loadStoryboard(info.storyboard)
        loadPreview()
    }

    // MARK: - Storyboard

    private func loadStoryboard(_ board: Storyboard?) {
        storyboardTask?.cancel()
        storyboard = board
        storyboardSheets = [:]
        guard let board else { return }
        storyboardTask = Task { [weak self] in
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for (i, sheet) in board.sheets.enumerated() {
                    group.addTask {
                        guard let (data, _) = try? await URLSession.shared.data(from: sheet.url),
                              let image = NSImage(data: data) else { return (i, nil) }
                        return (i, image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    }
                }
                for await (i, image) in group {
                    guard let self, !Task.isCancelled else { return }
                    if let image { self.storyboardSheets[i] = image }
                }
            }
        }
    }

    /// The low-res storyboard frame for time `t`, if its sheet has loaded.
    func storyboardFrame(at t: Double) -> CGImage? {
        guard let board = storyboard, let tile = board.tile(at: t),
              let sheet = storyboardSheets[tile.sheet] else { return nil }
        let w = sheet.width / board.columns, h = sheet.height / board.rows
        let rect = CGRect(x: (tile.index % board.columns) * w, y: (tile.index / board.columns) * h, width: w, height: h)
        return sheet.cropping(to: rect)
    }

    /// Loads the preview into the player.
    ///
    /// YouTube rejects a freshly issued stream URL (HTTP 403) for the first few seconds. Rather than
    /// letting AVPlayer fail and backing off, each candidate is probed with a tiny range request and
    /// handed to the player as soon as the server accepts it.
    func loadPreview() {
        previewTask?.cancel()
        let sources = info?.previewSources ?? []
        guard !sources.isEmpty else {
            previewState = .unavailable
            return
        }
        previewState = .loading
        previewTask = Task { [weak self] in
            for source in sources {
                guard await Self.waitUntilReachable(source) else { continue }
                // Usually opens first time once reachable; one quick retry covers stragglers.
                for attempt in 0..<2 {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(0.5)) }
                    guard let self, !Task.isCancelled else { return }
                    if await self.tryPreview(source) {
                        self.previewState = .ready
                        // Show whatever the user picked while the preview was loading.
                        if self.currentTime > 0 { self.seek(to: self.currentTime) }
                        return
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.player.replaceCurrentItem(with: nil)
            self.previewState = .failed
        }
    }

    /// Polls the stream URL until the server answers with a success status (or gives up).
    private nonisolated static func waitUntilReachable(_ source: PreviewSource, timeout: Double = 15) async -> Bool {
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        if let ua = source.headers["User-Agent"] { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let status = (response as? HTTPURLResponse)?.statusCode {
                if (200..<300).contains(status) { return true }
                if status != 403 { return false }   // 403 = not active yet; anything else won't recover
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    private func tryPreview(_ source: PreviewSource) async -> Bool {
        var options: [String: Any] = [:]
        if let ua = source.headers["User-Agent"] {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["User-Agent": ua]
        }
        let asset = AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        // Wait (up to 15s) for the item to become ready or fail.
        for _ in 0..<60 where item.status == .unknown {
            try? await Task.sleep(for: .seconds(0.25))
            if Task.isCancelled { return false }
        }
        guard item.status == .readyToPlay else { return false }

        // YouTube's HLS manifests auto-select captions; keep the preview clean.
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            item.select(nil, in: group)
        }
        return true
    }

    // MARK: - Playback

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        isPlaying = player.rate != 0
        // While seeking, the player still reports the old position; keep the target instead.
        guard !isSeeking else { return }
        currentTime = t
        if playingClip && trimEnabled && t >= clipEnd {
            if loopClip {
                seek(to: clipStart)
            } else {
                player.pause()
                playingClip = false
                seek(to: clipEnd)
            }
        }
    }

    /// Seeks the preview. `exact: false` allows snapping to a nearby keyframe, which is far
    /// cheaper for streamed video and is used while dragging; the final position is exact.
    ///
    /// Issuing a new seek cancels the one in flight, so firing one per drag event means none
    /// ever finishes and the picture freezes. Instead, only one seek runs at a time and the
    /// latest target is applied when it completes (Apple Technical Q&A QA1820).
    func seek(to seconds: Double, exact: Bool = true) {
        currentTime = seconds
        // Until the preview is ready, just remember the position; it's applied once loaded.
        guard previewState == .ready else { return }
        pendingSeek = (CMTime(seconds: max(0, seconds), preferredTimescale: 600), exact)
        if !isSeeking { startNextSeek() }
    }

    private func startNextSeek() {
        guard let next = pendingSeek else {
            isSeeking = false
            return
        }
        pendingSeek = nil
        isSeeking = true
        let tolerance = next.exact ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        #if DEBUG
        let issued = Date()
        #endif
        player.seek(to: next.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            #if DEBUG
            DebugHooks.seekLog.append((issued, Date(), finished))
            #endif
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.startNextSeek() }
            }
        }
    }

    /// Seek triggered by the user dragging on the timeline; cancels clip-only playback.
    /// Pass `final: true` when the drag ends to land on the exact frame.
    func scrub(to seconds: Double, final: Bool = false) {
        playingClip = false
        seek(to: seconds, exact: final)
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            playingClip = false
        } else {
            if duration > 0 && currentTime >= duration - 0.1 { seek(to: 0) }
            player.play()
        }
    }

    /// Plays exactly the selected clip from its start point.
    func playClip() {
        seek(to: clipStart)
        playingClip = true
        player.play()
    }

    /// Plays the last few seconds before the end point, to check where the clip cuts off.
    func playClipEnding(seconds: Double = 3) {
        seek(to: max(clipStart, clipEnd - seconds))
        playingClip = true
        player.play()
    }

    func setStartToPlayhead() {
        clipStart = min(currentTime, max(0, clipEnd - 1))
    }

    func setEndToPlayhead() {
        clipEnd = max(currentTime, min(duration, clipStart + 1))
    }

    func resetClip() {
        clipStart = 0
        clipEnd = duration
    }

    // MARK: - Downloading

    var summary: String {
        var parts: [String] = []
        switch mode {
        case .video:
            let q = maxHeight.map { "\($0)p" } ?? "Best quality"
            parts.append("\(q) \(container.rawValue.uppercased()) video")
        case .audio:
            let q = audioFormat.isLossless ? "" : (audioBitrate == .best ? " (best)" : " \(audioBitrate.label)")
            parts.append("\(audioFormat.rawValue.uppercased()) audio\(q)")
        }
        if trimEnabled && canTrim {
            parts.append("clip \(TimeFormat.string(clipStart)) – \(TimeFormat.string(clipEnd)) (\(TimeFormat.string(clipLength)))")
        } else {
            parts.append("full length" + (duration > 0 ? " (\(TimeFormat.string(duration, showFraction: false)))" : ""))
        }
        return parts.joined(separator: ", ")
    }

    func buildArguments(ffmpeg: URL) -> [String] {
        let isClip = trimEnabled && canTrim
        var args = [
            "--no-playlist", "--newline", "--progress", "--no-quiet",
            "--color", "never", "--socket-timeout", "20",
            "--ffmpeg-location", ffmpeg.path,
            "-P", outputFolder.path,
            "--progress-template", "download:__PROG__ %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "after_move:__FILE__ %(filepath)s",
        ]

        var name = "%(title)s"
        if isClip {
            name += " (clip \(TimeFormat.fileStamp(clipStart))-\(TimeFormat.fileStamp(clipEnd)))"
        } else if mode == .video, let h = maxHeight {
            name += " [\(h)p]"
        }
        args += ["-o", name + ".%(ext)s"]

        switch mode {
        case .video:
            if let h = maxHeight {
                args += ["-f", "bv*[height<=\(h)]+ba/b[height<=\(h)]/bv*+ba/b"]
            } else {
                args += ["-f", "bv*+ba/b"]
            }
            let res = maxHeight.map { "res:\($0)," } ?? ""
            switch container {
            case .mp4, .mov: args += ["-S", "\(res)vcodec:h264,acodec:aac"]
            case .webm: args += ["-S", "\(res)ext:webm:webm"]
            case .mkv: if !res.isEmpty { args += ["-S", String(res.dropLast())] }
            }
            args += ["--merge-output-format", container.rawValue]
            // WebM can't hold H.264/AAC, so only force a remux for containers that accept anything.
            if container != .webm { args += ["--remux-video", container.rawValue] }
            if embedThumbnail && container != .webm { args.append("--embed-thumbnail") }
        case .audio:
            args += ["-f", audioFormat == .m4a ? "ba[ext=m4a]/ba/b" : "ba/b"]
            args += ["-x", "--audio-format", audioFormat.rawValue]
            if !audioFormat.isLossless { args += ["--audio-quality", audioBitrate.rawValue] }
            if embedThumbnail && audioFormat.supportsThumbnail { args.append("--embed-thumbnail") }
        }
        if embedMetadata { args.append("--embed-metadata") }

        if isClip {
            args += ["--download-sections", String(format: "*%.2f-%.2f", clipStart, clipEnd)]
            if preciseCuts { args.append("--force-keyframes-at-cuts") }
        }

        args.append(info?.webpageUrl ?? urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        return args
    }

    func download() async {
        await YtDlpUpdater.ensureReady()
        guard let ytdlp = Tools.ytdlp, let ffmpeg = Tools.ffmpeg else {
            phase = .failed("yt-dlp and ffmpeg are required. Install them with: brew install yt-dlp ffmpeg")
            return
        }
        player.pause()
        phase = .downloading
        progress = nil
        statusText = "Starting…"
        speedText = ""
        etaText = ""
        downloadedFile = nil
        lastError = nil
        streamCount = 1
        streamIndex = 0
        log = ["$ yt-dlp " + buildArguments(ffmpeg: ffmpeg).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")]

        let proc = CLIProcess()
        activeProcess = proc
        defer { activeProcess = nil }
        do {
            let result = try await proc.run(ytdlp, arguments: buildArguments(ffmpeg: ffmpeg)) { line in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.handle(line: line) }
                }
            }
            // The main queue is FIFO, so this waits for all queued line handlers to run.
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            guard phase == .downloading else { return } // cancelled
            if result.status == 0 {
                phase = .finished
                progress = 1
                statusText = "Download complete"
                speedText = ""
                etaText = ""
            } else {
                phase = .failed(lastError ?? Self.friendlyError(result.stderr) ?? "yt-dlp exited with code \(result.status).")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        activeProcess?.cancel()
        if phase == .downloading {
            phase = .ready
            statusText = "Cancelled"
            progress = nil
        } else if phase == .fetching {
            phase = .idle
        }
    }

    private func handle(line: String) {
        log.append(line)
        if log.count > 800 { log.removeFirst(log.count - 800) }

        if line.hasPrefix("__PROG__") {
            let fields = line.dropFirst("__PROG__".count).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let pctText = fields.first, let pct = Double(pctText.replacingOccurrences(of: "%", with: "")) {
                progress = pct / 100
            }
            if fields.count > 1, !fields[1].contains("Unknown"), fields[1] != "NA" { speedText = fields[1] }
            if fields.count > 2, !fields[2].contains("Unknown"), fields[2] != "NA" { etaText = fields[2] }
            statusText = streamCount > 1
                ? "Downloading \(streamIndex <= 1 ? "video" : "audio") (\(max(streamIndex, 1)) of \(streamCount))…"
                : "Downloading…"
        } else if line.hasPrefix("__FILE__ ") {
            downloadedFile = URL(fileURLWithPath: String(line.dropFirst("__FILE__ ".count)))
        } else if line.contains("Downloading 1 format(s):"), let ids = line.split(separator: ":").last {
            streamCount = ids.split(separator: "+").count
        } else if line.hasPrefix("[download] Destination:") {
            streamIndex += 1
            progress = nil
        } else if line.hasPrefix("[youtube]") || line.hasPrefix("[info]") {
            statusText = "Preparing…"
        } else if line.hasPrefix("[Merger]") {
            statusText = "Merging video and audio…"
            progress = nil
        } else if line.hasPrefix("[ExtractAudio]") {
            statusText = "Converting audio…"
            progress = nil
        } else if line.hasPrefix("[VideoRemuxer]") || line.hasPrefix("[VideoConvertor]") {
            statusText = "Converting video…"
            progress = nil
        } else if line.hasPrefix("[EmbedThumbnail]") || line.hasPrefix("[Metadata]") {
            statusText = "Adding metadata…"
        } else if line.hasPrefix("ERROR:") {
            lastError = Self.friendlyError(line)
        } else if let t = Self.ffmpegTime(line), trimEnabled, clipLength > 0 {
            // Clip downloads go through ffmpeg, which reports elapsed output time.
            progress = min(1, t / clipLength)
            statusText = "Downloading and cutting clip…"
            if let speed = line.range(of: #"speed=\s*[\d.]+x"#, options: .regularExpression) {
                speedText = line[speed].replacingOccurrences(of: "speed=", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private static func ffmpegTime(_ line: String) -> Double? {
        guard line.contains("time="),
              let r = line.range(of: #"time=(\d+):(\d+):([\d.]+)"#, options: .regularExpression) else { return nil }
        let parts = line[r].dropFirst(5).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func friendlyError(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let err = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last else { return nil }
        var msg = err.replacingOccurrences(of: "ERROR: ", with: "")
        if let r = msg.range(of: #"^\[[^\]]+\] [\w-]+: "#, options: .regularExpression) { msg.removeSubrange(r) }
        if msg.contains("is not a valid URL") || msg.contains("Unsupported URL") {
            return "That doesn't look like a supported video link."
        }
        if msg.contains("Video unavailable") { return "This video is unavailable (private, removed, or region-locked)." }
        if msg.contains("Sign in to confirm") {
            return "YouTube is asking to sign in to confirm you're not a bot. Try again later or update yt-dlp (brew upgrade yt-dlp)."
        }
        return msg
    }

    // MARK: - Files

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    func revealDownloadedFile() {
        if let file = downloadedFile, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(outputFolder)
        }
    }

    func openDownloadedFile() {
        if let file = downloadedFile { NSWorkspace.shared.open(file) }
    }
}
