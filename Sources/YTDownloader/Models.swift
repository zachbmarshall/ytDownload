import Foundation

// MARK: - yt-dlp metadata

/// The subset of `yt-dlp -J` output that the app uses.
struct VideoInfo: Decodable {
    let id: String
    let title: String
    let uploader: String?
    let channel: String?
    let duration: Double?
    let thumbnail: String?
    let webpageUrl: String?
    let isLive: Bool?
    let formats: [Format]?

    struct Format: Decodable {
        let formatId: String
        let url: String?
        let manifestUrl: String?
        let ext: String?
        let vcodec: String?
        let acodec: String?
        let height: Int?
        let `protocol`: String?
        let httpHeaders: [String: String]?
        // Storyboard (thumbnail sprite sheet) fields
        let width: Int?
        let rows: Int?
        let columns: Int?
        let fps: Double?
        let fragments: [Fragment]?

        struct Fragment: Decodable {
            let url: String?
            let duration: Double?
        }

        var hasVideo: Bool { (vcodec ?? "none") != "none" }
        var hasAudio: Bool { (acodec ?? "none") != "none" }
        var isHTTP: Bool { (`protocol` ?? "").hasPrefix("http") }
        var isHLS: Bool { (`protocol` ?? "").hasPrefix("m3u8") }
    }

    var author: String? { uploader ?? channel }

    /// Available video heights, highest first (e.g. [2160, 1440, 1080, 720, ...]).
    var videoHeights: [Int] {
        let heights = (formats ?? []).filter(\.hasVideo).compactMap(\.height).filter { $0 >= 144 }
        return Array(Set(heights)).sorted(by: >)
    }

    /// YouTube's storyboard: low-res frames packed into sprite sheets. These load instantly,
    /// so they can show the frame under the trim handles while the real preview is starting.
    var storyboard: Storyboard? {
        let candidates = (formats ?? []).filter {
            $0.formatId.hasPrefix("sb") && ($0.rows ?? 0) > 0 && ($0.columns ?? 0) > 0
                && ($0.fps ?? 0) > 0 && !($0.fragments ?? []).isEmpty
        }
        guard let best = candidates.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) else { return nil }
        var start = 0.0
        var sheets: [Storyboard.Sheet] = []
        for fragment in best.fragments ?? [] {
            guard let s = fragment.url, let url = URL(string: s) else { return nil }
            let duration = fragment.duration ?? 0
            sheets.append(.init(url: url, start: start, duration: duration))
            start += duration
        }
        return Storyboard(sheets: sheets, rows: best.rows!, columns: best.columns!, fps: best.fps!)
    }

    /// Streams AVPlayer can play for the in-app preview, best first:
    /// HLS master playlist (video + audio, adaptive) → progressive MP4 → video-only MP4 → M4A audio.
    var previewSources: [PreviewSource] {
        let fs = formats ?? []
        var sources: [PreviewSource] = []
        func add(_ f: VideoInfo.Format?, url: String?, video: Bool, audio: Bool) {
            guard let f, let url, let u = URL(string: url) else { return }
            sources.append(PreviewSource(url: u, headers: f.httpHeaders ?? [:], hasVideo: video, hasAudio: audio))
        }
        let byHeight: (Format, Format) -> Bool = { ($0.height ?? 0) < ($1.height ?? 0) }
        let hls = fs.first { $0.isHLS && $0.hasVideo && $0.manifestUrl != nil }
        add(hls, url: hls?.manifestUrl, video: true, audio: true)
        let http = fs.filter { $0.isHTTP && $0.url != nil }
        let progressive = http.filter { $0.hasVideo && $0.hasAudio && $0.ext == "mp4" }.max(by: byHeight)
        add(progressive, url: progressive?.url, video: true, audio: true)
        let videoOnly = http.filter { $0.hasVideo && !$0.hasAudio && ($0.vcodec ?? "").hasPrefix("avc1") && ($0.height ?? 0) <= 720 }
            .max(by: byHeight)
        add(videoOnly, url: videoOnly?.url, video: true, audio: false)
        let audioOnly = http.first { !$0.hasVideo && $0.hasAudio && $0.ext == "m4a" }
        add(audioOnly, url: audioOnly?.url, video: false, audio: true)
        return sources
    }
}

struct Storyboard {
    struct Sheet {
        let url: URL
        let start: Double
        let duration: Double
    }
    let sheets: [Sheet]
    let rows: Int
    let columns: Int
    let fps: Double

    /// Which sheet and which tile (row-major index) shows time `t`.
    func tile(at t: Double) -> (sheet: Int, index: Int)? {
        guard let sheetIndex = sheets.lastIndex(where: { $0.start <= t }) ?? (sheets.isEmpty ? nil : 0) else { return nil }
        let local = max(0, t - sheets[sheetIndex].start)
        return (sheetIndex, min(Int(local * fps), rows * columns - 1))
    }
}

struct PreviewSource {
    let url: URL
    let headers: [String: String]
    let hasVideo: Bool
    let hasAudio: Bool
}

// MARK: - Download options

enum DownloadMode: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio Only"
    var id: String { rawValue }
    var symbol: String { self == .video ? "film" : "music.note" }
}

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4, mkv, webm, mov
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp4: "MP4 (most compatible)"
        case .mkv: "MKV"
        case .webm: "WebM"
        case .mov: "MOV (QuickTime)"
        }
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, wav, flac, opus
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A (AAC)"
        case .wav: "WAV (uncompressed)"
        case .flac: "FLAC (lossless)"
        case .opus: "Opus"
        }
    }
    var isLossless: Bool { self == .wav || self == .flac }
    var supportsThumbnail: Bool { self == .mp3 || self == .m4a || self == .flac || self == .opus }
}

enum AudioBitrate: String, CaseIterable, Identifiable {
    case best = "0"
    case k320 = "320K"
    case k256 = "256K"
    case k192 = "192K"
    case k128 = "128K"
    var id: String { rawValue }
    var label: String { self == .best ? "Best" : rawValue.replacingOccurrences(of: "K", with: " kbps") }
}

// MARK: - Time helpers

enum TimeFormat {
    /// 75.5 → "1:15.5", 3725 → "1:02:05"
    static func string(_ seconds: Double, showFraction: Bool = true) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = max(0, seconds)
        let tenths = Int((s * 10).rounded()) % 10
        let total = Int(s.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        if showFraction { out += ".\(tenths)" }
        return out
    }

    /// Parses "83", "83.5", "1:23", "1:23.5", "01:02:03".
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Filename-safe stamp, e.g. 83 → "1m23s".
    static func fileStamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h\(m)m\(s)s" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }
}
