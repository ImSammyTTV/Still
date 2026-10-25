import SwiftUI
import StillCore
import AVFoundation

struct PreviewView: View {
    let item: CaptureItem
    @ObservedObject var library: Library
    let dismiss: () -> Void
    @State private var hovering = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
                if let image = library.thumbnail(item) { Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height).clipShape(RoundedRectangle(cornerRadius: 12)) }
                if item.isVideo { Button { AppController.shared.openItem(item); dismiss() } label: { Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white).shadow(radius: 4) }.buttonStyle(.plain).accessibilityLabel("Play recording") }
                if hovering {
                    VStack {
                        HStack { Button(action: dismiss) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white).shadow(radius: 2) }.buttonStyle(.plain).accessibilityLabel("Close overlay"); Spacer(); Text(item.isVideo ? "Recording" : "\(item.width) × \(item.height)").font(.system(size: 9)).foregroundStyle(.white).padding(5).background(.black.opacity(0.45), in: Capsule()) }.padding(8)
                        Spacer()
                        HStack(spacing: 0) {
                            action(item.isVideo ? "play.fill" : "pencil", item.isVideo ? "Edit Video" : "Annotate") { AppController.shared.openItem(item); dismiss() }
                            action("square.and.arrow.down", "Save") { if NSEvent.modifierFlags.contains(.option) { library.export(item) } else { library.quickSave(item) }; dismiss() }
                            action("doc.on.doc", "Copy") { library.copy(item); dismiss() }
                            if !item.isVideo { action("pin", "Pin") { if let image = ImageRenderer.load(library.url(item)) { AppController.shared.pin(image) }; dismiss() } }
                            action("icloud.and.arrow.up", "Upload to Cloud") { AppController.shared.upload(item) }
                            action("square.and.arrow.up", "Share") { AppController.shared.shareItem(item) }
                        }.padding(4).background(.ultraThickMaterial, in: Capsule()).padding(8)
                    }
                }
            }.contentShape(RoundedRectangle(cornerRadius: 12)).onHover { hovering = $0 }.onTapGesture(count: 2) { AppController.shared.openItem(item); dismiss() }
                .onDrag { NSItemProvider(contentsOf: library.url(item)) ?? NSItemProvider() }
                .contextMenu { Button(item.isVideo ? "Open Video Editor" : "Annotate") { AppController.shared.openItem(item); dismiss() }; Button("Copy") { library.copy(item) }; Button("Save") { library.quickSave(item) }; Button("Save As…") { library.export(item) }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.url(item)]) }; Button("Close Overlay") { dismiss() } }
        }.overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15))).accessibilityLabel("Quick Access Overlay for \(item.title)")
        .task {
            let timeout = Preferences.shared.previewTimeout
            guard timeout > 0 else { return }
            var remaining = timeout
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                remaining = hovering ? timeout : remaining-0.5
                if remaining <= 0 { dismiss(); return }
            }
        }
    }
    private func action(_ symbol: String, _ title: String, perform: @escaping () -> Void) -> some View { Button(action: perform) { Image(systemName: symbol).font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 27).contentShape(Rectangle()) }.buttonStyle(.plain).help(title).accessibilityLabel(title) }
}

struct PinView: View {
    let image: CGImage
    @ObservedObject var library: Library
    weak var panel: NSPanel?
    @State private var hovering = false
    @State private var opacity = 1.0
    var body: some View {
        ZStack(alignment: .top) {
            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).opacity(opacity)
                .clipShape(RoundedRectangle(cornerRadius: Preferences.shared.pinRounded ? 10 : 0))
                .overlay(RoundedRectangle(cornerRadius: Preferences.shared.pinRounded ? 10 : 0).stroke(Preferences.shared.pinBorder ? Color.white.opacity(0.7) : .clear, lineWidth: 1))
            if hovering {
                HStack(spacing: 8) {
                    Button { panel?.close() } label: { Image(systemName: "xmark.circle.fill") }.help("Close").accessibilityLabel("Close pinned screenshot")
                    Slider(value: $opacity, in: 0.15...1).frame(width: 80).help("Opacity").accessibilityLabel("Pinned screenshot opacity")
                    Button { resize(0.8) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Make smaller")
                    Button { resize(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Make larger")
                    Button { panel?.ignoresMouseEvents = true } label: { Image(systemName: "lock") }.help("Lock; unlock from the menu bar").accessibilityLabel("Lock screenshot and click through")
                }.buttonStyle(.plain).font(.system(size: 12)).padding(8).background(.ultraThickMaterial, in: Capsule()).padding(6)
            }
        }.onHover { hovering = $0 }.accessibilityLabel("Pinned screenshot; use arrow keys to move")
            .contextMenu { Button("Copy Image") { library.copy(image) }; Button("Save As…") { library.export(image) }; Button("Annotate") { AppController.shared.openEditor(image: image) }; Button("Actual Size") { panel?.setContentSize(NSSize(width: image.width, height: image.height)) }; Button("Lock (Click Through)") { panel?.ignoresMouseEvents = true }; Button("Close") { panel?.close() } }
    }
    private func resize(_ factor: Double) { if let panel { let frame = panel.frame; panel.setFrame(CGRect(x: frame.minX, y: frame.maxY-frame.height*factor, width: max(80, frame.width*factor), height: max(50, frame.height*factor)), display: true) } }
}
final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0, dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
            setFrameOrigin(CGPoint(x: frame.minX+dx, y: frame.minY+dy)); return
        }
        if event.type == .keyDown, event.keyCode == 53 { close(); return }
        super.sendEvent(event)
    }
}
struct RecordingHUD: View {
    @ObservedObject var recorder: Recorder
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(recorder.paused ? .yellow : .red).frame(width: 7, height: 7)
            Text(recorder.stopping ? "Saving…" : recorder.pausing ? "Pausing…" : String(format: "%02d:%02d", Int(recorder.elapsed)/60, Int(recorder.elapsed)%60)).monospacedDigit().font(.system(size: 12, weight: .medium)).frame(minWidth: 55)
            Button { recorder.togglePause() } label: { Image(systemName: recorder.paused ? "play.fill" : "pause.fill") }.buttonStyle(.plain).disabled(recorder.stopping || recorder.pausing).help(recorder.paused ? "Resume" : "Pause").accessibilityLabel(recorder.paused ? "Resume recording" : "Pause recording")
            Button { recorder.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }.buttonStyle(.plain).disabled(recorder.stopping || recorder.pausing).help("Stop recording").accessibilityLabel("Stop recording")
        }.padding(.horizontal, 18).frame(height: 42).background(.ultraThickMaterial, in: Capsule()).environment(\.colorScheme, .dark)
    }
}
struct CameraBubble: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.wantsLayer = true; let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; view.layer = layer; view.layer?.masksToBounds = true; return view }
    func updateNSView(_ view: NSView, context: Context) { view.layer?.cornerRadius = Preferences.shared.recordingCameraShape == "circle" ? view.bounds.width/2 : 18 }
}
