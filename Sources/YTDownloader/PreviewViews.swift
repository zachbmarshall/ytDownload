import AVKit
import SwiftUI

/// AppKit's AVPlayerView wrapped for SwiftUI.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// A timeline with two draggable handles (clip start / end) and a playhead.
struct TrimSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    /// Read inside a child view, so playhead ticks redraw only the playhead line.
    let playhead: () -> Double
    var minimumLength: Double = 1
    /// Called while dragging so the player can show the frame under the handle.
    var onScrub: (Double) -> Void
    /// Called when a drag ends, so the player can land on the exact frame.
    var onScrubEnded: (Double) -> Void

    private let handleWidth: CGFloat = 14
    private let trackHeight: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - handleWidth * 2)
            let x: (Double) -> CGFloat = { t in
                handleWidth + CGFloat(duration > 0 ? t / duration : 0) * usable
            }
            let time: (CGFloat) -> Double = { px in
                Double((px - handleWidth) / usable) * duration
            }

            ZStack(alignment: .leading) {
                // Full track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: trackHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { v in onScrub(clamp(time(v.location.x), 0, duration)) }
                            .onEnded { v in onScrubEnded(clamp(time(v.location.x), 0, duration)) }
                    )

                // Dimmed regions outside the selection
                Rectangle()
                    .fill(Color.black.opacity(0.25))
                    .frame(width: max(0, x(start) - handleWidth), height: trackHeight)
                    .offset(x: handleWidth)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.black.opacity(0.25))
                    .frame(width: max(0, x(duration) - x(end)), height: trackHeight)
                    .offset(x: x(end))
                    .allowsHitTesting(false)

                // Selected region
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.18))
                    .frame(width: max(0, x(end) - x(start)) + handleWidth * 2, height: trackHeight)
                    .offset(x: x(start) - handleWidth)
                    .allowsHitTesting(false)

                PlayheadLine(position: { x(clamp(playhead(), 0, duration)) }, height: trackHeight + 10)

                handle(systemImage: "chevron.compact.left")
                    .offset(x: x(start) - handleWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { v in
                                start = clamp(time(v.location.x), 0, end - minimumLength)
                                onScrub(start)
                            }
                            .onEnded { _ in onScrubEnded(start) }
                    )
                    .help("Drag to set where the clip starts")

                handle(systemImage: "chevron.compact.right")
                    .offset(x: x(end))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { v in
                                end = clamp(time(v.location.x), start + minimumLength, duration)
                                onScrub(end)
                            }
                            .onEnded { _ in onScrubEnded(end) }
                    )
                    .help("Drag to set where the clip ends")
            }
            .frame(height: trackHeight + 10)
            .coordinateSpace(name: "trim")
            #if DEBUG
            .onAppear { DebugHooks.trimFrame = geo.frame(in: .global) }
            .onChange(of: geo.frame(in: .global)) { _, f in DebugHooks.trimFrame = f }
            #endif
        }
        .frame(height: trackHeight + 10)
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: trackHeight)
            .overlay(Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), max(lo, hi))
    }
}

/// The playhead marker. Its own view so frequent time updates only redraw this line.
private struct PlayheadLine: View {
    let position: () -> CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 2, height: height)
            .offset(x: position() - 1)
            .allowsHitTesting(false)
    }
}

private struct PlayheadLabel: View {
    let model: AppModel

    var body: some View {
        Text("Playhead \(TimeFormat.string(model.currentTime))")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// While the real preview starts, shows YouTube's low-res storyboard frame for the playhead,
/// so dragging the trim handles gives instant visual feedback.
private struct StoryboardPreview<Fallback: View>: View {
    let model: AppModel
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if model.currentTime > 0, let frame = model.storyboardFrame(at: model.currentTime) {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fallback()
        }
    }
}

/// A text field for timestamps like "1:23.5" that commits on Return or when focus leaves.
struct TimeField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 90)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: value) { _, newValue in if !focused { text = TimeFormat.string(newValue) } }
            .onAppear { text = TimeFormat.string(value) }
    }

    private func commit() {
        if let parsed = TimeFormat.parse(text) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        text = TimeFormat.string(value)
    }
}

/// Video preview plus the clip selection controls.
struct PreviewSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let info = model.info { header(info) }

            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                // The player view stays in the hierarchy the whole time. Inserting an AppKit view
                // while the user is dragging a trim handle cancels the drag, so loading/fallback
                // states are drawn as overlays on top of it instead.
                PlayerView(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                switch model.previewState {
                case .ready:
                    EmptyView()
                case .loading:
                    ZStack(alignment: .topTrailing) {
                        Color.black
                        StoryboardPreview(model: model) { thumbnail(message: nil) }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading video…")
                        }
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                case .failed:
                    ZStack {
                        Color.black
                        thumbnail(message: "The preview couldn't be loaded. You can still download the video or a clip.", retry: true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                case .unavailable:
                    ZStack {
                        Color.black
                        thumbnail(message: "No preview is available for this video. You can still download it.")
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)

            trimControls
        }
    }

    private func header(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                if let author = info.author { Label(author, systemImage: "person.crop.circle") }
                if model.duration > 0 {
                    Label(TimeFormat.string(model.duration, showFraction: false), systemImage: "clock")
                }
                if info.isLive == true { Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func thumbnail(message: String?, retry: Bool = false) -> some View {
        ZStack(alignment: .bottom) {
            if let thumb = model.info?.thumbnail, let url = URL(string: thumb) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { Color.clear }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message {
                HStack(spacing: 10) {
                    Text(message).font(.callout)
                    if retry {
                        Button("Retry Preview") { model.loadPreview() }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var trimControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(isOn: $model.trimEnabled.animation(.snappy)) {
                        Label("Download only a clip", systemImage: "scissors")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)
                    .disabled(!model.canTrim)
                    Spacer()
                    PlayheadLabel(model: model)
                }

                if !model.canTrim {
                    Text("Clipping isn't available for live streams or videos without a known length.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.trimEnabled {
                    TrimSlider(
                        start: $model.clipStart,
                        end: $model.clipEnd,
                        duration: model.duration,
                        playhead: { model.currentTime },
                        onScrub: { model.scrub(to: $0) },
                        onScrubEnded: { model.scrub(to: $0, final: true) }
                    )

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                TimeField(value: $model.clipStart, range: 0...max(0, model.clipEnd - 1))
                                Button { model.setStartToPlayhead() } label: { Image(systemName: "arrow.down.to.line") }
                                    .help("Set start to the current playhead position")
                            }
                        }
                        Spacer()
                        VStack(spacing: 4) {
                            Text("Clip length").font(.caption).foregroundStyle(.secondary)
                            Text(TimeFormat.string(model.clipLength))
                                .font(.title3.monospacedDigit().weight(.medium))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("End").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Button { model.setEndToPlayhead() } label: { Image(systemName: "arrow.down.to.line") }
                                    .help("Set end to the current playhead position")
                                TimeField(value: $model.clipEnd, range: min(model.duration, model.clipStart + 1)...model.duration)
                            }
                        }
                    }

                    HStack {
                        Button { model.playClip() } label: { Label("Preview Clip", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.previewAvailable)
                            .keyboardShortcut("p", modifiers: [.command])
                        Button { model.playClipEnding() } label: { Label("Play Ending", systemImage: "forward.end") }
                            .disabled(!model.previewAvailable)
                            .help("Play the last 3 seconds of the clip to check the end point")
                        Button { model.togglePlay() } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .disabled(!model.previewAvailable)
                        .help("Play / pause")
                        Toggle("Loop", isOn: $model.loopClip)
                            .toggleStyle(.checkbox)
                        Spacer()
                        Button("Reset") { model.resetClip() }
                    }
                } else {
                    Text("Turn this on to pick a start and end point and save just that part.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}
