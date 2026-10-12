#if DEBUG
import AppKit

/// Debug-only automation used for testing builds:
///   --snapshot=<dir>    writes PNGs of the window every few seconds
///   --clip=<start>,<end> --mode=audio --out=<dir> --download
/// (Values use `=` because AppKit treats bare arguments as files to open.)
@MainActor
enum DebugHooks {
    static func run(model: AppModel) async {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.first(where: { $0.hasPrefix(flag + "=") }).map { String($0.dropFirst(flag.count + 1)) }
        }
        let snapDir = value("--snapshot")
        var shot = 0
        func snap() {
            guard let dir = snapDir, let view = NSApp.windows.first?.contentView else { return }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            shot += 1
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("shot\(shot).png"))
        }

        try? await Task.sleep(for: .seconds(2))
        snap()
        if args.contains("--player-status") {
            // Wait for preview retries to settle, then try playing.
            for _ in 0..<80 where model.previewState == .loading { try? await Task.sleep(for: .seconds(0.25)) }
            print("PREVIEW STATE:", model.previewState)
            snap()
            model.player.play()
            try? await Task.sleep(for: .seconds(3))
            print("PLAYBACK TIME:", model.player.currentTime().seconds)
            fflush(stdout)
            NSApp.terminate(nil)
        }
        let clip = value("--clip")?.split(separator: ",").compactMap { Double($0) } ?? []
        if clip.count == 2 {
            let (s, e) = (clip[0], clip[1])
            model.trimEnabled = true
            model.clipStart = s
            model.clipEnd = e
            model.seek(to: s)
        }
        if value("--mode") == "audio" { model.mode = .audio }
        if let out = value("--out") { model.outputFolder = URL(fileURLWithPath: out) }
        try? await Task.sleep(for: .seconds(2))
        snap()
        if args.contains("--download") {
            Task { await model.download() }
            try? await Task.sleep(for: .seconds(0.5))
            while model.phase == .downloading {
                try? await Task.sleep(for: .seconds(1.5))
                snap()
            }
            snap()
            print("PHASE:", model.phase, "FILE:", model.downloadedFile?.path ?? "nil")
            model.log.forEach { print("LOG:", $0) }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}
#endif
