import AppKit
import CryptoKit

/// Keeps the app's own copy of yt-dlp current. YouTube changes often, and an outdated yt-dlp is
/// the most common reason downloads stop working.
///
/// Only applies to DMG builds with bundled tools: the bundled yt-dlp zip is unpacked to
/// Application Support (the signed app bundle must not be modified), and newer releases are
/// installed there. yt-dlp's own `-U` can't be used: it refuses to update the folder build the
/// app ships (the single-file build it can update takes ~7s to start every time).
/// Homebrew installs are left to `brew upgrade`.
@MainActor
enum YtDlpUpdater {
    enum Outcome {
        case updated(String)
        case upToDate(String)
        case failed(String)
        case notApplicable

        var message: String {
            switch self {
            case .updated(let v): "yt-dlp was updated to \(v)."
            case .upToDate(let v): "yt-dlp is up to date (\(v))."
            case .failed(let reason): "Couldn't update yt-dlp: \(reason)"
            case .notApplicable: "This copy of the app uses your system's yt-dlp. Update it with: brew upgrade yt-dlp"
            }
        }
    }

    private static let lastCheckKey = "lastYtdlpUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 3600
    private static var currentUpdate: Task<Outcome, Never>?
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

    /// Called at launch. Sets up the bundled yt-dlp, then checks for a new release once a day,
    /// including while the app stays open.
    static func launchTasks() async {
        guard Tools.hasBundledTools, await ensureReady() else { return }
        while !Task.isCancelled {
            if Date().timeIntervalSince(lastCheck) >= checkInterval {
                _ = await update()
            }
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// After a failed fetch or download. An outdated yt-dlp is the usual cause, so check right away
    /// (unless that already happened in the last hour). Returns true if a newer yt-dlp was installed.
    static func updateAfterFailure() async -> Bool {
        guard Tools.hasBundledTools else { return false }
        // A check already in progress (e.g. at launch) counts; otherwise don't re-check hourly.
        guard currentUpdate != nil || Date().timeIntervalSince(lastCheck) > 3600 else { return false }
        if case .updated = await update() { return true }
        return false
    }

    /// Installs the latest yt-dlp release if it's newer than the current copy. Overlapping calls
    /// (launch check, a failure, the menu) share the check already in progress.
    static func update() async -> Outcome {
        guard Tools.hasBundledTools else { return .notApplicable }
        if let inFlight = currentUpdate { return await inFlight.value }
        let task = Task { await performUpdate() }
        currentUpdate = task
        defer { currentUpdate = nil }
        return await task.value
    }

    private static func performUpdate() async -> Outcome {
        guard await ensureReady() else { return .failed("yt-dlp couldn't be set up.") }
        do {
            let installed = await Task.detached { version(of: Tools.managedYtdlp.path) }.value ?? ""
            let latest = try await latestRelease()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            // Versions are dates (2026.08.19, sometimes with a .N suffix), so text order works.
            guard latest > installed else { return .upToDate(installed) }
            try await Task.detached(priority: .utility) { try await install(latest) }.value
            return .updated(latest)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func currentVersion() async -> String? {
        guard let ytdlp = Tools.ytdlp else { return nil }
        return await Task.detached { version(of: ytdlp.path) }.value
    }

    /// Menu command: check now and report the result.
    static func checkFromMenu() {
        Task {
            let outcome = await update()
            let alert = NSAlert()
            alert.messageText = "yt-dlp Updates"
            alert.informativeText = outcome.message
            alert.runModal()
        }
    }

    private static var lastCheck: Date {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
    }

    // MARK: - Downloading a release

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The newest release tag, read from where GitHub's "latest release" link redirects.
    nonisolated private static func latestRelease() async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        let tag = response.url?.lastPathComponent ?? ""
        guard tag.range(of: #"^\d{4}\.\d{2}\.\d{2}(\.\d+)?$"#, options: .regularExpression) != nil else {
            throw UpdateError("couldn't find the latest version on GitHub.")
        }
        return tag
    }

    /// Downloads a release, verifies its checksum, unpacks it and swaps it in.
    nonisolated private static func install(_ tag: String) async throws {
        let base = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/")!
        let (zip, zipResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("yt-dlp_macos.zip"))
        let (sums, _) = try await URLSession.shared.data(from: base.appendingPathComponent("SHA2-256SUMS"))
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("the download failed.") }

        let expected = String(decoding: sums, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.hasSuffix(" yt-dlp_macos.zip") }?
            .split(separator: " ").first.map(String.init)
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard let expected, actual == expected else { throw UpdateError("the download didn't match its checksum.") }

        let fm = FileManager.default
        let support = Tools.managedYtdlpDirectory.deletingLastPathComponent()
        let zipFile = support.appendingPathComponent("yt-dlp_macos.zip")
        let staging = support.appendingPathComponent("yt-dlp.staging")
        try? fm.removeItem(at: staging)
        try zip.write(to: zipFile)
        defer { try? fm.removeItem(at: zipFile) }
        guard run("/usr/bin/ditto", ["-x", "-k", zipFile.path, staging.path]) else {
            throw UpdateError("the download couldn't be unpacked.")
        }
        guard version(of: staging.appendingPathComponent("yt-dlp_macos").path) == tag else {
            try? fm.removeItem(at: staging)
            throw UpdateError("the new version didn't start correctly.")
        }
        try swapIn(staging)
    }

    /// Moves a freshly unpacked copy into place. The previous copy is renamed rather than deleted,
    /// since a download may still be using it; leftovers are removed on the next launch.
    nonisolated private static func swapIn(_ staging: URL) throws {
        let fm = FileManager.default
        let dir = Tools.managedYtdlpDirectory
        let old = dir.deletingLastPathComponent().appendingPathComponent("yt-dlp.old-\(UUID().uuidString)")
        let hadOld = fm.fileExists(atPath: dir.path)
        if hadOld { try fm.moveItem(at: dir, to: old) }
        do {
            try fm.moveItem(at: staging, to: dir)
        } catch {
            if hadOld { try? fm.moveItem(at: old, to: dir) }
            throw error
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
        // Remove copies replaced by earlier updates.
        let support = Tools.managedYtdlpDirectory.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: support.path)) ?? [] where name.hasPrefix("yt-dlp.old-") {
            try? fm.removeItem(at: support.appendingPathComponent(name))
        }
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
        do {
            try swapIn(staging)
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
