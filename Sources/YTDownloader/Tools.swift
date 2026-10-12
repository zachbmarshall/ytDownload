import Foundation

/// Locates the command line tools the app depends on. Apps launched from Finder get a
/// minimal PATH, so we search the usual Homebrew / MacPorts / pip locations explicitly.
enum Tools {
    static let searchDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    static func find(_ name: String) -> URL? {
        let envPath = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in searchDirectories + envPath {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static var ytdlp: URL? { find("yt-dlp") }
    static var ffmpeg: URL? { find("ffmpeg") }

    /// Environment for child processes: extended PATH so yt-dlp can find ffmpeg and a
    /// JavaScript runtime (deno/node), which YouTube extraction needs.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? ""
        env["PATH"] = (searchDirectories + [existing]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }
}

/// Thin async wrapper around `Process` that streams output line by line.
final class CLIProcess: @unchecked Sendable {
    private let process = Process()

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs the executable. `onLine` receives each line of output (split on both `\n`
    /// and `\r`, since ffmpeg redraws its progress with carriage returns).
    /// If `captureStdout` is true, stdout is collected as raw data and not passed to `onLine`.
    func run(
        _ executable: URL,
        arguments: [String],
        captureStdout: Bool = false,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Tools.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdoutData = Locked(Data())
        let stderrText = Locked("")
        let outSplitter = LineSplitter()
        let errSplitter = LineSplitter()

        let handleOut: @Sendable (Data) -> Void = { data in
            if captureStdout {
                stdoutData.withValue { $0.append(data) }
            } else {
                outSplitter.feed(data).forEach { onLine?($0) }
            }
        }
        let handleErr: @Sendable (Data) -> Void = { data in
            let lines = errSplitter.feed(data)
            stderrText.withValue { text in lines.forEach { text += $0 + "\n" } }
            lines.forEach { onLine?($0) }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { handleOut(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { handleErr(data) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        // Drain anything left in the pipes after exit.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        handleOut(captureStdout ? remainingOut : remainingOut + Data([0x0A]))
        handleErr(remainingErr + Data([0x0A]))

        return Result(
            status: status,
            stdout: stdoutData.withValue { $0 },
            stderr: stderrText.withValue { $0 }
        )
    }

    /// Sends SIGINT so yt-dlp / ffmpeg can clean up partial files.
    func cancel() {
        if process.isRunning { process.interrupt() }
    }
}

/// A value guarded by a lock.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

/// Accumulates bytes and returns complete lines, splitting on `\n` and `\r`.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
