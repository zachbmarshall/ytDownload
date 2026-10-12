import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var toolsMissing = Tools.ytdlp == nil || Tools.ffmpeg == nil

    var body: some View {
        VStack(spacing: 0) {
            URLBar(model: model)
            Divider()
            if toolsMissing {
                MissingToolsView { toolsMissing = Tools.ytdlp == nil || Tools.ffmpeg == nil }
            } else {
                mainContent
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .task {
            // Allow `YTDownloader --url=<link>` to open straight to a video.
            if let url = CommandLine.arguments.first(where: { $0.hasPrefix("--url=") })?.dropFirst(6) {
                model.urlText = String(url)
                await model.fetch()
            }
            #if DEBUG
            await DebugHooks.run(model: model)
            #endif
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.info != nil {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    PreviewSection(model: model).padding(20)
                }
                .frame(maxWidth: .infinity)
                Divider()
                OptionsPanel(model: model)
                    .frame(width: 340)
            }
        } else if model.phase == .fetching {
            VStack(spacing: 12) {
                ProgressView()
                Text("Fetching video info…").foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.fetchError {
            ContentUnavailableView {
                Label("Couldn't load that video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.fetch() } }
            }
        } else {
            ContentUnavailableView {
                Label("Paste a YouTube link to get started", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Download full videos or just a clip, as video or audio.")
            }
        }
    }
}

struct URLBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://www.youtube.com/watch?v=…", text: $model.urlText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { Task { await model.fetch() } }
                if !model.urlText.isEmpty {
                    Button { model.urlText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))

            Button {
                if let s = NSPasteboard.general.string(forType: .string) {
                    model.urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await model.fetch() }
                }
            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            .help("Paste a link from the clipboard and load it")

            Button {
                Task { await model.fetch() }
            } label: {
                Label("Load", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
        }
        .controlSize(.large)
        .padding(14)
        .onAppear { focused = true }
    }
}

struct OptionsPanel: View {
    @Bindable var model: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Download as", selection: $model.mode) {
                        ForEach(DownloadMode.allCases) { m in
                            Label(m.rawValue, systemImage: m.symbol).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if model.mode == .video {
                    Section("Video") {
                        Picker("Quality", selection: $model.maxHeight) {
                            Text("Best available").tag(Int?.none)
                            ForEach(model.info?.videoHeights ?? [], id: \.self) { h in
                                Text(Self.heightLabel(h)).tag(Int?.some(h))
                            }
                        }
                        Picker("Format", selection: $model.container) {
                            ForEach(VideoContainer.allCases) { Text($0.label).tag($0) }
                        }
                        if model.limitedFormats {
                            HStack(alignment: .firstTextBaseline) {
                                Text("YouTube only offered low-quality formats this time. Reloading often brings back higher resolutions.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Reload") { Task { await model.fetch() } }
                                    .controlSize(.small)
                            }
                        }
                        if (model.container == .mp4 || model.container == .mov),
                           (model.maxHeight ?? model.info?.videoHeights.first ?? 0) > 1080 {
                            Text("Above 1080p, YouTube only offers VP9/AV1, which some players (like QuickTime on older Macs) can't play. Choose 1080p for maximum compatibility.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Audio") {
                        Picker("Format", selection: $model.audioFormat) {
                            ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Quality", selection: $model.audioBitrate) {
                            ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(model.audioFormat.isLossless)
                    }
                }

                Section("Extras") {
                    Toggle("Embed title & artist info", isOn: $model.embedMetadata)
                    Toggle("Embed thumbnail as cover art", isOn: $model.embedThumbnail)
                        .disabled(!thumbnailSupported)
                    if model.trimEnabled {
                        Toggle(isOn: $model.preciseCuts) {
                            Text("Frame-accurate cuts")
                            Text("Re-encodes the clip so it starts exactly where you chose. Slower.")
                        }
                    }
                }

                Section("Save to") {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(model.outputFolder.path(percentEncoded: false).replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), with: "~/"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.outputFolder.path)
                        Spacer()
                        Button("Change…") { model.chooseOutputFolder() }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.phase == .downloading)

            Divider()
            downloadArea.padding(16)
        }
        .sheet(isPresented: $showLog) { LogView(lines: model.log) }
    }

    private var thumbnailSupported: Bool {
        model.mode == .video ? model.container != .webm : model.audioFormat.supportsThumbnail
    }

    @ViewBuilder
    private var downloadArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.phase == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    if let p = model.progress {
                        ProgressView(value: p)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(model.statusText).lineLimit(1)
                        Spacer()
                        if let p = model.progress { Text("\(Int(p * 100))%").monospacedDigit() }
                    }
                    .font(.caption)
                    HStack {
                        if !model.speedText.isEmpty { Text(model.speedText) }
                        Spacer()
                        if !model.etaText.isEmpty { Text("\(model.etaText) left") }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Button(role: .cancel) { model.cancel() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                if model.phase == .finished {
                    finishedBanner
                } else if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.statusText == "Cancelled" {
                    Text("Download cancelled.").font(.callout).foregroundStyle(.secondary)
                }
                Button { Task { await model.download() } } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("d", modifiers: [.command])
            }

            if !model.log.isEmpty {
                Button("Show details") { showLog = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var finishedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            if let file = model.downloadedFile {
                Text(file.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Button { model.revealDownloadedFile() } label: { Label("Show in Finder", systemImage: "folder") }
                Button { model.openDownloadedFile() } label: { Label("Open", systemImage: "play.circle") }
                    .disabled(model.downloadedFile == nil)
            }
        }
    }

    static func heightLabel(_ h: Int) -> String {
        switch h {
        case 4320: "4320p (8K)"
        case 2160: "2160p (4K)"
        case 1440: "1440p (2K)"
        case 1080: "1080p (Full HD)"
        case 720: "720p (HD)"
        default: "\(h)p"
        }
    }
}

struct LogView: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("yt-dlp output").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
        }
        .frame(width: 720, height: 460)
    }
}

struct MissingToolsView: View {
    var recheck: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("yt-dlp and ffmpeg are needed", systemImage: "wrench.and.screwdriver")
        } description: {
            VStack(spacing: 10) {
                Text("This app is a friendly front end for yt-dlp. Install the tools with Homebrew, then click Check Again:")
                Text("brew install yt-dlp ffmpeg deno")
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    status("yt-dlp", Tools.ytdlp)
                    status("ffmpeg", Tools.ffmpeg)
                }
            }
        } actions: {
            Button("Check Again", action: recheck)
        }
    }

    private func status(_ name: String, _ url: URL?) -> some View {
        Label(name, systemImage: url == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
            .foregroundStyle(url == nil ? .red : .green)
    }
}
