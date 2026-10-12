#if DEBUG
import AppKit
import AVFoundation

/// Debug-only automation used for testing builds:
///   --snapshot=<dir>    writes PNGs of the window every few seconds
///   --clip=<start>,<end> --mode=audio --out=<dir> --download
/// (Values use `=` because AppKit treats bare arguments as files to open.)
@MainActor
enum DebugHooks {
    static var trimFrame: CGRect = .zero
    nonisolated(unsafe) static var seekLog: [(Date, Date, Bool)] = []

    /// Sends a synthetic mouse event to the main window (SwiftUI global coords → window coords).
    static func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) {
        guard let window = NSApp.windows.first else { return }
        // SwiftUI's global space starts at the top of the window frame (content extends under the title bar).
        let p = NSPoint(x: x, y: window.frame.height - y)
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(e)
    }

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

        if !args.contains("--immediate-drag-test") { try? await Task.sleep(for: .seconds(2)) }
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
        if args.contains("--immediate-drag-test") {
            // Mirrors the user's flow: link loaded → enable clip → drag the start handle right away.
            model.trimEnabled = true
            try? await Task.sleep(for: .seconds(0.3))
            if args.contains("--wait-ready") {
                for _ in 0..<80 where model.previewState == .loading { try? await Task.sleep(for: .seconds(0.1)) }
                try? await Task.sleep(for: .seconds(0.3))
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            let f = trimFrame
            let y = f.minY + 18
            var x = f.minX + 7
            let t0 = Date()
            var worst = 0.0
            var readyAt: Double?
            mouse(.leftMouseDown, x: x, y: y)
            for i in 0..<400 {
                if readyAt == nil, model.previewState == .ready {
                    readyAt = Date().timeIntervalSince(t0)
                    print(String(format: "PREVIEW READY at +%.2fs after link loaded", readyAt!))
                }
                let s = Date()
                if i % 2 == 0 { x += 1 }
                mouse(.leftMouseDragged, x: x, y: y)
                try? await Task.sleep(for: .milliseconds(16))
                let gap = Date().timeIntervalSince(s)
                worst = max(worst, gap)
                if gap > 0.1 { print(String(format: "STALL at +%.2fs: %.2fs (preview: %@)", s.timeIntervalSince(t0), gap, "\(model.previewState)")) }
                if i == 50 {
                    print("AT +\(Date().timeIntervalSince(t0))s preview=\(model.previewState) storyboard frame:", model.storyboardFrame(at: model.currentTime).map { "\($0.width)x\($0.height)" } ?? "nil", "t=\(model.currentTime)")
                    snap()
                }
                if i % 60 == 0 { print(String(format: "t=+%.1fs clipStart=%.1f preview=%@", s.timeIntervalSince(t0), model.clipStart, "\(model.previewState)")) }
            }
            mouse(.leftMouseUp, x: x, y: y)
            print(String(format: "DONE worst %.2fs clipStart=%.1f currentTime=%.1f frame=%@", worst, model.clipStart, model.currentTime, "\(trimFrame)")); fflush(stdout)
            NSApp.terminate(nil)
        }
        if args.contains("--mouse-drag-test") {
            for _ in 0..<80 where model.previewState == .loading { try? await Task.sleep(for: .seconds(0.25)) }
            print("PREVIEW STATE:", model.previewState, "source:", (model.player.currentItem?.asset as? AVURLAsset)?.url.absoluteString.contains("m3u8") == true || (model.player.currentItem?.asset as? AVURLAsset)?.url.absoluteString.contains("hls") == true ? "HLS" : "progressive")
            if args.contains("--play-first") {
                model.player.play()
                try? await Task.sleep(for: .seconds(4))
                model.player.pause()
            }
            model.trimEnabled = true
            try? await Task.sleep(for: .seconds(1.5))
            let f = trimFrame
            if let w = NSApp.windows.first { print("TRIM FRAME:", f, "window:", w.frame.size, "content:", w.contentView!.bounds.size) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            if let w = NSApp.windows.first, let c = w.contentView {
                for dy in stride(from: -40.0, through: 60.0, by: 10.0) {
                    let hp = c.convert(NSPoint(x: f.minX + 7, y: w.frame.height - (f.minY + dy)), from: nil)
                    print("HIT dy=\(dy)", c.hitTest(hp).map { String(describing: type(of: $0)) } ?? "nil")
                }
            }
            let y = f.minY + 18
            var x = f.minX + 7   // start handle centre
            print("DRAG START", Date().timeIntervalSince1970); fflush(stdout)
            var worst = 0.0
            let t0 = Date()
            func cpu() -> Double {
                var u = rusage(); getrusage(RUSAGE_SELF, &u)
                return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
            }
            let cpu0 = cpu()
            mouse(.leftMouseDown, x: x, y: y)
            for i in 0..<120 {
                let s = Date()
                x += 3
                mouse(.leftMouseDragged, x: x, y: y)
                try? await Task.sleep(for: .milliseconds(16))
                let gap = Date().timeIntervalSince(s)
                worst = max(worst, gap)
                if gap > 0.1 { print(String(format: "STALL step %d at %.2fs: %.2fs  clipStart=%.1f", i, Date().timeIntervalSince(t0), gap, model.clipStart)) }
            }
            mouse(.leftMouseUp, x: x, y: y)
            print(String(format: "CPU during drag: %.2fs over %.2fs", cpu() - cpu0, Date().timeIntervalSince(t0)))
            try? await Task.sleep(for: .seconds(8))
            let completed = seekLog.filter { $0.0 >= t0 }
            let done = completed.filter(\.2)
            print("SEEKS issued-during-drag:", completed.count, "finished:", done.count)
            if let first = done.first { print(String(format: "first completed seek: issued +%.2fs, completed +%.2fs", first.0.timeIntervalSince(t0), first.1.timeIntervalSince(t0))) }
            for d in done.prefix(8) { print(String(format: "  done seek issued +%.2f -> +%.2f (%.2fs)", d.0.timeIntervalSince(t0), d.1.timeIntervalSince(t0), d.1.timeIntervalSince(d.0))) }
            print(String(format: "DRAG DONE total %.2fs worst step %.2fs clipStart=%.1f", Date().timeIntervalSince(t0), worst, model.clipStart))
            fflush(stdout)
            NSApp.terminate(nil)
        }
        if args.contains("--drag-test") {
            // Simulates dragging the start handle at ~60 Hz and reports main-thread stalls.
            for _ in 0..<80 where model.previewState == .loading { try? await Task.sleep(for: .seconds(0.25)) }
            print("PREVIEW STATE:", model.previewState)
            model.trimEnabled = true
            try? await Task.sleep(for: .seconds(1))
            print("DRAG START", Date().timeIntervalSince1970)
            fflush(stdout)
            var worst = 0.0
            for i in 0..<180 {
                let t0 = Date()
                let t = Double(i) * 0.25
                model.clipStart = t
                model.scrub(to: t)
                try? await Task.sleep(for: .milliseconds(16))
                let gap = Date().timeIntervalSince(t0)
                worst = max(worst, gap)
                if gap > 0.1 { print(String(format: "STALL step %d: %.2fs", i, gap)) }
            }
            print(String(format: "DRAG DONE worst step %.2fs", worst))
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
