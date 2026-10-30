import SwiftUI
import StillCore

struct RecordingSetupView: View {
    @ObservedObject var library: Library
    @ObservedObject private var prefs = Preferences.shared
    let selectedSize: CGSize?
    var selectedWindow = false
    let chooseArea: () -> Void
    let cancel: () -> Void
    let record: (String, Bool, Bool, CGSize) -> Void
    @State private var details = false
    @State private var width = ""
    @State private var height = ""
    @State private var fullscreen = false
    var body: some View {
        VStack(spacing: 12) {
            if selectedWindow && !fullscreen { Label("Selected window only", systemImage: "macwindow").font(.system(size: 12, weight: .semibold)) }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { details.toggle() } label: { Image(systemName: "slider.vertical.3").frame(width: 31) }.buttonStyle(.plain).help("Recording settings").popover(isPresented: $details) { VStack(alignment: .leading, spacing: 16) { Text("Recording Settings").font(.headline); Picker("Quality", selection: $prefs.recordingQuality) { ForEach(prefs.qualityOptions(including: prefs.recordingQuality), id: \.tag) { Text($0.title).tag($0.tag) } }; Picker("Frame Rate", selection: $prefs.recordingFPS) { ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) } }; Picker("Max Resolution", selection: $prefs.recordingResolution) { Text("Original").tag(0); Text("1080p").tag(1920); Text("4K").tag(3840) }; Toggle("Show Cursor", isOn: $prefs.recordingCursor); Toggle("Show Clicks", isOn: $prefs.recordingClicks); Toggle("Show Keystrokes", isOn: $prefs.recordingKeys); Toggle("Only Command Keys", isOn: $prefs.recordingCommandKeysOnly) }.padding(20).frame(width: 280) }
                    Divider().frame(height: 25)
                    TextField("Width", text: $width).disabled(selectedWindow && !fullscreen).textFieldStyle(.plain).multilineTextAlignment(.center).font(.system(size: 14, weight: .semibold)).frame(width: 56).padding(.vertical, 5).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $height).disabled(selectedWindow && !fullscreen).textFieldStyle(.plain).multilineTextAlignment(.center).font(.system(size: 14, weight: .semibold)).frame(width: 56).padding(.vertical, 5).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                    Button { fullscreen.toggle(); let size = fullscreen ? NSScreen.main?.frame.size : selectedSize; if let size { width = String(Int(size.width)); height = String(Int(size.height)) } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(fullscreen ? Color.white : Color.secondary) }.buttonStyle(.plain).help("Full screen")
                    Button(action: chooseArea) { Image(systemName: "crop").frame(width: 25) }.buttonStyle(.plain).help("Select recording area").accessibilityLabel("Select recording area")
                }.padding(12)
                Divider()
                HStack(spacing: 0) {
                    toggle("mic", "Microphone", binding: $library.microphoneAudio)
                    toggle("display", "System Audio", binding: $library.systemAudio)
                    toggle("video", "Camera", binding: $prefs.recordingCamera)
                    toggle("cursorarrow.click", "Click Effects", binding: $prefs.recordingClicks)
                    toggle("command.square", "Keystrokes", binding: $prefs.recordingKeys)
                }.padding(.vertical, 11)
            }.background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))
            VStack(spacing: 0) {
                action("Record GIF", symbol: "GIF", shortcut: "⌥↩") { start("gif", false) }.keyboardShortcut(.return, modifiers: .option)
                Divider().padding(.horizontal, 13)
                action("Record Video", symbol: "video.fill", shortcut: "↩") { start("mp4", false) }.keyboardShortcut(.defaultAction)
            }.background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
            action("Record in Studio Mode", symbol: "film.stack", shortcut: "⇧↩") { start("mp4", true) }.keyboardShortcut(.return, modifiers: .shift).background(.ultraThickMaterial, in: Capsule())
            Button("Cancel", action: cancel).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
        }.frame(width: 340).padding(10).environment(\.colorScheme, .dark)
        .onAppear { let size = selectedSize ?? NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080); width = String(Int(size.width)); height = String(Int(size.height)) }
    }
    private func start(_ format: String, _ studio: Bool) { let w = max(2, Double(width) ?? 1920), h = max(2, Double(height) ?? 1080); record(format, studio, fullscreen, CGSize(width: w, height: h)) }
    private func toggle(_ symbol: String, _ title: String, binding: Binding<Bool>) -> some View { Button { binding.wrappedValue.toggle() } label: { Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(binding.wrappedValue ? Color.white : Color.white.opacity(0.4)).frame(maxWidth: .infinity) }.buttonStyle(.plain).help("\(title): \(binding.wrappedValue ? "On" : "Off")").accessibilityLabel(title).accessibilityAddTraits(binding.wrappedValue ? .isSelected : []) }
    private func action(_ title: String, symbol: String, shortcut: String, perform: @escaping () -> Void) -> some View { Button(action: perform) { HStack(spacing: 14) { if symbol == "GIF" { Text("GIF").font(.system(size: 8, weight: .bold)).foregroundStyle(.black).padding(3).background(.white, in: RoundedRectangle(cornerRadius: 4)) } else { Image(systemName: symbol).frame(width: 24) }; Text(title).font(.system(size: 15, weight: .medium)); Spacer(); Text(shortcut).foregroundStyle(.secondary) }.padding(.horizontal, 17).frame(height: 47).contentShape(Rectangle()) }.buttonStyle(.plain) }
}
