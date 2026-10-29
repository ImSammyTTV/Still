import AppKit
import SwiftUI
import AVKit
import StillCore

@MainActor final class VideoEditorModel: ObservableObject {
    let item: CaptureItem
    let library: Library
    let player = AVPlayer()
    let transcription = Transcription()
    @Published var transcribing = false
    private var transcriptionTask: Task<Void, Never>?
    @Published var settings = VideoSettings() { didSet { if !restoring { redoStack.removeAll(); undoStack.append(oldValue); if undoStack.count > 60 { undoStack.removeFirst() }; dirty = true } } }
    @Published var metadata = RecordingMetadata()
    @Published var duration: Double = 0
    @Published var playhead: Double = 0
    @Published var playing = false
    @Published var thumbnails: [NSImage] = []
    @Published var loading = true
    @Published var exporting = false
    @Published var exportProgress: Double = 0
    @Published var error: String?
    @Published var dirty = false
    @Published var panel = "Background"
    private var prepared: PreparedVideo?
    private var observer: Any?
    private var previewTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var undoStack: [VideoSettings] = []
    private var redoStack: [VideoSettings] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private var restoring = false
    init(item: CaptureItem, library: Library) {
        self.item = item; self.library = library
        metadata = library.recordingMetadata(item)
        if let data = try? Data(contentsOf: library.root.appendingPathComponent("\(item.id).videoedit.json")), let saved = try? JSONDecoder().decode(VideoSettings.self, from: data) { settings = saved }
        else { settings = metadata.presentation ?? Preferences.shared.recordingPresentation; settings.cursorScale = metadata.defaultShowCursor ? 1 : 0; settings.showClicks = metadata.defaultShowClicks; settings.showKeystrokes = metadata.defaultShowKeystrokes; settings.fps = Preferences.shared.recordingFPS; settings.quality = Preferences.shared.recordingQuality }
        dirty = false; undoStack = []; redoStack = []
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in Task { @MainActor in guard let self else { return }; if time.seconds.isFinite { self.playhead = self.settings.start+time.seconds }; self.playing = self.player.rate > 0 } }
        loadTask = Task { await load() }
    }
    private func load() async {
        do {
            let asset = AVURLAsset(url: library.videoSource(item))
            duration = try await asset.load(.duration).seconds
            restoring = true; if settings.end <= 0 { settings.end = duration }; restoring = false; dirty = false
            await rebuild()
            let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 220, height: 130); generator.appliesPreferredTrackTransform = true
            for index in 0..<9 { guard !Task.isCancelled else { return }; if let result = try? await generator.image(at: CMTime(seconds: max(0, min(duration-0.01, duration*Double(index)/9)), preferredTimescale: 600)) { thumbnails.append(NSImage(cgImage: result.image, size: .zero)) } }
        } catch { self.error = error.localizedDescription; loading = false }
    }
    func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { try? await Task.sleep(nanoseconds: 180_000_000); guard !Task.isCancelled else { return }; await rebuild() }
    }
    private func rebuild() async {
        do {
            let wasPlaying = player.rate > 0, position = playhead
            let camera = metadata.cameraFilename.map { library.root.appendingPathComponent($0) }
            let result = try await VideoEngine.prepare(url: library.videoSource(item), settings: settings, metadata: metadata, cameraURL: camera)
            guard !Task.isCancelled else { return }
            prepared = result
            let playerItem = AVPlayerItem(asset: result.asset); playerItem.videoComposition = result.composition; playerItem.audioMix = result.audioMix
            player.replaceCurrentItem(with: playerItem)
            await player.seek(to: CMTime(seconds: max(0, min(result.duration, position-settings.start)), preferredTimescale: 600))
            if wasPlaying { player.play() }
            loading = false
        } catch { self.error = error.localizedDescription; loading = false }
    }
    func togglePlay() { if player.rate > 0 { player.pause(); playing = false } else { if playhead >= settings.end-0.05 { seek(settings.start) }; player.play(); playing = true } }
    func seek(_ value: Double) { playhead = value; player.seek(to: CMTime(seconds: max(0, value-settings.start), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func save() {
        do { try JSONEncoder().encode(settings).write(to: library.root.appendingPathComponent("\(item.id).videoedit.json"), options: .atomic); dirty = false; library.toast("Video edits saved") }
        catch { self.error = error.localizedDescription }
    }
    func transcribe() {
        guard !transcribing else { return }; transcribing = true
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { transcribing = false }
            do {
                let result = try await transcription.transcribe(library.videoSource(item))
                metadata.transcript = result.0; metadata.captions = result.1
                try library.saveRecordingMetadata(item, metadata: metadata, camera: nil)
                library.toast("Transcript saved")
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancelTranscription() { transcriptionTask?.cancel(); transcription.cancel() }
    func close() { loadTask?.cancel(); player.pause(); previewTask?.cancel(); cancelTranscription(); if let observer { player.removeTimeObserver(observer); self.observer = nil } }
    func undo() { guard let state = undoStack.popLast() else { return }; redoStack.append(settings); restoring = true; settings = state; restoring = false; dirty = true; schedulePreview() }
    func redo() { guard let state = redoStack.popLast() else { return }; undoStack.append(settings); restoring = true; settings = state; restoring = false; dirty = true; schedulePreview() }
    func addZoom() {
        let position = metadata.pointer.min(by: { abs($0.time-playhead) < abs($1.time-playhead) })
        settings.zooms.append(ZoomSegment(start: max(settings.start, playhead-0.2), end: min(settings.end, playhead+2), x: position?.x ?? 0.5, y: position?.y ?? 0.5))
    }
    func smartZooms() {
        guard !metadata.clicks.isEmpty else { error = "No click metadata is available for this video. Use Add Zoom to place zooms manually."; return }
        var segments: [ZoomSegment] = []
        for click in metadata.clicks where click.time >= settings.start && click.time <= settings.end {
            if let last = segments.last, click.time-last.start < 1.8 { continue }
            segments.append(ZoomSegment(start: max(settings.start, click.time-0.35), end: min(settings.end, click.time+1.65), x: click.x, y: click.y))
        }
        settings.zooms = segments
    }
    func export(gif: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]; panel.nameFieldStringValue = "\(item.title)-edited.\(gif ? "gif" : "mp4")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.pause(); exporting = true; exportProgress = 0
        let settings = self.settings, metadata = self.metadata, source = library.videoSource(item), camera = metadata.cameraFilename.map { library.root.appendingPathComponent($0) }
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await VideoEngine.prepare(url: source, settings: settings, metadata: metadata, cameraURL: camera)
                let progress: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor in self?.exportProgress = value } }
                if gif { try await VideoEngine.gif(prepared, to: url, fps: Preferences.shared.gifFPS, width: Preferences.shared.gifWidth, progress: progress) }
                else { try await VideoEngine.export(prepared, to: url, progress: progress) }
                library.toast("Exported \(url.lastPathComponent)")
            } catch is CancellationError { try? FileManager.default.removeItem(at: url) }
            catch { self.error = error.localizedDescription; try? FileManager.default.removeItem(at: url) }
            exporting = false; exportTask = nil
        }
    }
    func cancelExport() { exportTask?.cancel() }
    deinit { previewTask?.cancel(); exportTask?.cancel(); if let observer { player.removeTimeObserver(observer) } }
}

struct VideoEditorView: View {
    @State private var trimDragOrigin: Double?
    @StateObject private var model: VideoEditorModel
    init(model: VideoEditorModel) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Still / Motion").font(.custom("Baskerville", size: 23)); Spacer(); Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo").disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command); Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo").disabled(!model.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]); Menu("Export") { Button("Export MP4…") { model.export(gif: false) }; Button("Export GIF…") { model.export(gif: true) } }.menuStyle(.borderlessButton).fixedSize().tint(.white).foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 6).background(Studio.accent, in: Capsule()); Button("Done") { model.save(); if !model.dirty { NSApp.keyWindow?.performClose(nil) } } }.padding(13).background(Studio.surface)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack { Color.black.opacity(0.08); NativeVideoPlayer(player: model.player); if model.loading { ProgressView("Loading video…") } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack { Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 25) }.buttonStyle(.plain).keyboardShortcut(.space, modifiers: []); Text(time(model.playhead)).monospacedDigit(); Slider(value: Binding(get: { model.playhead }, set: { model.seek($0) }), in: model.settings.start...max(model.settings.start+0.01, model.settings.end)); Text(time(model.settings.end)).monospacedDigit(); Button { model.settings.muted.toggle() } label: { Image(systemName: model.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.plain) }.font(.system(size: 11)).padding(13)
                }
                inspector.frame(width: 265).background(Studio.paper).overlay(alignment: .leading) { Divider() }
            }
            timeline
        }.font(.system(size: 12)).background(Studio.paper)
        .onChange(of: model.settings) { _, _ in model.schedulePreview() }
        .sheet(isPresented: $model.exporting) { VStack(spacing: 18) { Text("Exporting…").font(.headline); ProgressView(value: model.exportProgress).frame(width: 300); Text("\(Int(model.exportProgress*100))%").monospacedDigit().foregroundStyle(.secondary); Button("Cancel") { model.cancelExport() } }.padding(30).interactiveDismissDisabled() }
        .alert("Video Editor", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) { ForEach([("Background", "photo"), ("Zoom", "plus.magnifyingglass"), ("Cursor", "cursorarrow"), ("Camera", "video"), ("Audio", "speaker.wave.2")], id: \.0) { name, symbol in Button { model.panel = name } label: { Image(systemName: symbol).frame(width: 39, height: 33).background(model.panel == name ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help(name).accessibilityLabel(name) } }.padding(10)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 17) { Text(model.panel).font(Studio.heading); controls }.padding(18) }
        }
    }
    @ViewBuilder private var controls: some View {
        switch model.panel {
        case "Background":
            Picker("Quality", selection: Binding(get: { model.settings.quality ?? "high" }, set: { model.settings.quality = $0 })) { ForEach(VideoQuality.allCases) { Text($0.title).tag($0.rawValue) } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 7) { ForEach(FrameStyle.allCases) { frame in Button { model.settings.frame = frame.rawValue } label: { RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: frame == .none ? [.gray.opacity(0.1)] : frame.colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(height: 30).overlay(RoundedRectangle(cornerRadius: 5).stroke(model.settings.frame == frame.rawValue ? Color.accentColor : .clear, lineWidth: 2)) }.buttonStyle(.plain).help(frame.title) } }
            Picker("Aspect Ratio", selection: $model.settings.aspect) { Text("Auto").tag(0.0); Text("16:9").tag(16.0/9); Text("1:1").tag(1.0); Text("9:16").tag(9.0/16) }
            slider("Padding", value: $model.settings.padding, range: 0...200)
            slider("Corner Radius", value: $model.settings.radius, range: 0...80)
            slider("Shadow", value: $model.settings.shadow, range: 0...80)
            slider("Motion Blur", value: $model.settings.motionBlur, range: 0...1)
        case "Zoom":
            HStack { Button("Add Zoom") { model.addZoom() }; Button("Smart Zooms") { model.smartZooms() } }
            ForEach($model.settings.zooms) { $zoom in
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text("Zoom \(Int(zoom.scale*100))%").fontWeight(.medium); Spacer(); Button { model.settings.zooms.removeAll { $0.id == zoom.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel("Remove zoom") }
                    HStack { TextField("Start", value: $zoom.start, format: .number.precision(.fractionLength(2))); Text("→"); TextField("End", value: $zoom.end, format: .number.precision(.fractionLength(2))) }
                    Slider(value: $zoom.scale, in: 1.1...3)
                    HStack { Text("X"); Slider(value: $zoom.x, in: 0...1); Text("Y"); Slider(value: $zoom.y, in: 0...1) }
                }.padding(11).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }
            if model.settings.zooms.isEmpty { Text("Add a zoom at the playhead, or generate zooms from recorded clicks.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        case "Cursor":
            if model.metadata.cursorIncludedInVideo { Text("This video has its cursor baked in. Record with Still’s cursor tracking to edit its appearance.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            slider("Cursor Size", value: $model.settings.cursorScale, range: 0...3)
            Picker("Style", selection: $model.settings.cursorStyle) { Text("Arrow").tag("arrow"); Text("Dot").tag("dot") }
            Toggle("Smooth Cursor", isOn: $model.settings.smoothCursor)
            Divider(); Toggle("Click Effects", isOn: $model.settings.showClicks)
            ColorPicker("Click Color", selection: hexColor($model.settings.clickColor), supportsOpacity: false)
            slider("Click Size", value: defaulted($model.settings.clickSize, 1), range: 0.4...2.5)
            Picker("Click Style", selection: defaulted($model.settings.clickStyle, "outline")) { Text("Outline").tag("outline"); Text("Filled").tag("filled") }
            Toggle("Animate Clicks", isOn: defaulted($model.settings.clickAnimated, true))
            Divider(); Toggle("Show Keystrokes", isOn: $model.settings.showKeystrokes)
            Picker("Key Style", selection: defaulted($model.settings.keysStyle, "dark")) { Text("Dark").tag("dark"); Text("Light").tag("light") }
            slider("Key Size", value: defaulted($model.settings.keysSize, 1), range: 0.5...2)
            slider("Key Horizontal Position", value: defaulted($model.settings.keysX, 0.5), range: 0...1)
            slider("Key Vertical Position", value: defaulted($model.settings.keysY, 0.97), range: 0...1)
        case "Camera":
            if model.metadata.cameraFilename == nil { Text("No camera was recorded with this video.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Toggle("Show Camera", isOn: $model.settings.cameraEnabled)
            Toggle("Fullscreen Camera", isOn: defaulted($model.settings.cameraFullscreen, false))
            Toggle("Mirror Camera", isOn: defaulted($model.settings.cameraMirror, true))
            Picker("Shape", selection: $model.settings.cameraShape) { Text("Circle").tag("circle"); Text("Rounded").tag("rounded") }
            slider("Size", value: $model.settings.cameraSize, range: 0.1...0.6)
            slider("Horizontal Position", value: $model.settings.cameraX, range: 0...1)
            slider("Vertical Position", value: $model.settings.cameraY, range: 0...1)
        default:
            Toggle("Mute Audio", isOn: $model.settings.muted)
            Divider()
            Text("Transcript").fontWeight(.semibold)
            Text("Transcribe audio on this Mac. Speech Recognition permission is requested when you start.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.transcribing { ProgressView("Transcribing…"); Button("Cancel") { model.cancelTranscription() } }
            else { Button(model.metadata.transcript == nil ? "Transcribe Recording" : "Transcribe Again") { model.transcribe() } }
            if let transcript = model.metadata.transcript { Text(transcript).textSelection(.enabled).font(.system(size: 11)); Button("Copy Transcript") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string) } }
            Text("Microphone and system audio are preserved in MP4 exports. GIFs have no audio.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Trim bar: drag the handles at either end of the film strip; the kept part is framed, the rest dimmed.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Trim").fontWeight(.semibold)
                Text("\(time(model.settings.start)) — \(time(model.settings.end))  ·  \(time(model.settings.end-model.settings.start))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { model.settings.start = min(model.playhead, model.settings.end-0.2) } label: { Label("Set In", systemImage: "arrow.right.to.line") }.help("Start the video at the playhead (I)").keyboardShortcut("i", modifiers: [])
                Button { model.settings.end = max(model.playhead, model.settings.start+0.2) } label: { Label("Set Out", systemImage: "arrow.left.to.line") }.help("End the video at the playhead (O)").keyboardShortcut("o", modifiers: [])
                Button("Reset") { model.settings.start = 0; model.settings.end = model.duration }.disabled(model.settings.start <= 0 && model.settings.end >= model.duration - 0.01)
                Text(model.dirty ? "Unsaved edits" : "Edits saved").foregroundStyle(.secondary).font(.system(size: 10))
            }.buttonStyle(.borderless).controlSize(.small)
            GeometryReader { geometry in
                let width = geometry.size.width, total = max(0.01, model.duration)
                let x = { (t: Double) in CGFloat(t/total)*width }
                let startX = x(model.settings.start), endX = x(model.settings.end)
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) { ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in Image(nsImage: image).resizable().scaledToFill().frame(width: width/9, height: 52).clipped() } }
                        .frame(width: width, height: 52, alignment: .leading).clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(max(model.settings.start, min(model.settings.end, Double($0.location.x/width)*total))) })
                    ForEach(model.settings.zooms) { zoom in Rectangle().fill(Color.accentColor.opacity(0.4)).frame(width: max(3, x(zoom.end-zoom.start)), height: 8).offset(x: x(zoom.start), y: 22).allowsHitTesting(false) }
                    // Dim what gets cut.
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, startX), height: 52).allowsHitTesting(false)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, width-endX), height: 52).offset(x: endX).allowsHitTesting(false)
                    // Frame around the kept part.
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Studio.accent, lineWidth: 3).frame(width: max(14, endX-startX), height: 58).offset(x: startX).allowsHitTesting(false)
                    Rectangle().fill(.white).frame(width: 2, height: 64).shadow(radius: 2).offset(x: x(model.playhead)-1).allowsHitTesting(false)
                    // Handles move by how far you drag from where you grabbed them.
                    handle(edge: .leading).offset(x: startX-7)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let origin = trimDragOrigin ?? model.settings.start; trimDragOrigin = origin
                            model.settings.start = max(0, min(origin+Double(value.translation.width/width)*total, model.settings.end-0.2)); model.seek(model.settings.start)
                        }.onEnded { _ in trimDragOrigin = nil })
                    handle(edge: .trailing).offset(x: endX-7)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let origin = trimDragOrigin ?? model.settings.end; trimDragOrigin = origin
                            model.settings.end = min(total, max(origin+Double(value.translation.width/width)*total, model.settings.start+0.2)); model.seek(model.settings.end)
                        }.onEnded { _ in trimDragOrigin = nil })
                }
            }.frame(height: 64)
        }.padding(16).background(Color.primary.opacity(0.035)).overlay(alignment: .top) { Divider() }
    }
    private func handle(edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: edge == .leading ? 6 : 0, bottomLeadingRadius: edge == .leading ? 6 : 0, bottomTrailingRadius: edge == .trailing ? 6 : 0, topTrailingRadius: edge == .trailing ? 6 : 0)
            .fill(Studio.accent).frame(width: 14, height: 64)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 3, height: 20))
            .contentShape(Rectangle()).onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .accessibilityLabel(edge == .leading ? "Trim start" : "Trim end")
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View { VStack { HStack { Text(title); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1)))).foregroundStyle(.secondary) }; Slider(value: value, in: range) } }
    private func time(_ seconds: Double) -> String { let value = max(0, seconds.isFinite ? seconds : 0); return String(format: "%02d:%05.2f", Int(value)/60, value.truncatingRemainder(dividingBy: 60)) }
}
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
