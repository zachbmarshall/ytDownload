import AppKit

/// Keeps the app's own copy of yt-dlp current. YouTube changes often, and an outdated yt-dlp is
/// the most common reason downloads stop working.
///
/// Only applies to DMG builds with bundled tools: the bundled yt-dlp zip is unpacked to
/// Application Support (the signed app bundle must not be modified) and updated there with
/// `yt-dlp -U`. Homebrew installs are left to `brew upgrade`.
@MainActor
enum YtDlpUpdater {
    private static let lastCheckKey = "lastYtdlpUpdateCheck"
    private static var running = false
    private static var setupTask: Task<Bool, Never>?

    /// Waits for the one-time setup of the bundled tools. Anything that runs yt-dlp calls this
    /// first, so a fresh install never reports yt-dlp as missing while it's being unpacked.
    @discardableResult
    static func ensureReady() async -> Bool {
        guard Tools.hasBundledTools else { return true }
        if setupTask == nil {
            setupTask = Task.detached(priority: .userInitiated) { prepareBundledTools() }
        }
        let ok = await setupTask!.value
        if !ok { setupTask = nil }   // allow a retry next time
        return ok
    }

    /// Called at launch. Makes sure the updatable copy exists, then checks for updates once a day.
    static func launchTasks() async {
        guard Tools.hasBundledTools, await ensureReady() else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 3600 {
            _ = await update()
        }
    }

    /// Runs `yt-dlp -U` on the managed copy and returns a message for the user.
    static func update() async -> String {
        guard Tools.hasBundledTools else {
            return "This copy of the app uses your system's yt-dlp. Update it with: brew upgrade yt-dlp"
        }
        guard !running else { return "An update check is already running." }
        running = true
        defer { running = false }

        guard await ensureReady() else { return "Couldn't set up yt-dlp." }

        do {
            let result = try await CLIProcess().run(Tools.managedYtdlp, arguments: ["-U", "--color", "never"])
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let output = result.stderr
            if result.status == 0 {
                let version = await currentVersion() ?? "unknown"
                if output.contains("Updated yt-dlp to") { return "yt-dlp was updated to \(version)." }
                return "yt-dlp is up to date (\(version))."
            }
            return "The update failed: " + (AppModel.friendlyError(output) ?? "exit code \(result.status)")
        } catch {
            return "The update failed: \(error.localizedDescription)"
        }
    }

    static func currentVersion() async -> String? {
        guard let ytdlp = Tools.ytdlp,
              let result = try? await CLIProcess().run(ytdlp, arguments: ["--version"], captureStdout: true),
              result.status == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Menu command: check now and report the result.
    static func checkFromMenu() {
        Task {
            let message = await update()
            let alert = NSAlert()
            alert.messageText = "yt-dlp Updates"
            alert.informativeText = message
            alert.runModal()
        }
    }

    // MARK: - Setup (runs off the main thread)

    /// Removes the quarantine flag from the bundled helpers and makes sure the unpacked copy of
    /// yt-dlp exists and isn't older than the one bundled with this version of the app.
    nonisolated private static func prepareBundledTools() -> Bool {
        // Downloaded DMGs mark everything inside as quarantined. Clearing it on the helper tools
        // (an attribute only; it doesn't change the signed files) lets the app run them directly.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Tools.helpersDirectory.path])

        let fm = FileManager.default
        let managed = Tools.managedYtdlp.path
        let bundled = (try? String(contentsOf: Tools.bundledYtdlpVersionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fm.isExecutableFile(atPath: managed), let mine = version(of: managed), mine >= bundled {
            return true   // existing copy is current (versions are dates like 2026.08.19)
        }

        // Unpack the bundled build into a temporary folder, then swap it in.
        let dir = Tools.managedYtdlpDirectory
        let staging = dir.deletingLastPathComponent().appendingPathComponent("yt-dlp.staging")
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", Tools.bundledYtdlpArchive.path, staging.path]) else { return false }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
        try? fm.removeItem(at: dir)
        do {
            try fm.moveItem(at: staging, to: dir)
        } catch {
            return false
        }
        // The first run of a fresh copy is slow while macOS scans it; get that out of the way now.
        return version(of: managed) != nil
    }

    nonisolated private static func version(of path: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
