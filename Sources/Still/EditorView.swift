import SwiftUI
import StillCore

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var palette = ColorPalette.shared
    @FocusState private var textFocused: Bool
    private let tools: [MarkTool] = [.select, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pixelate, .spotlight, .number, .pen, .highlight, .blur]
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
            toolRail
            GeometryReader { geometry in
                let layout = model.canvasLayout
                let fit = min(max(100, geometry.size.width-60)/layout.size.width, max(100, geometry.size.height-60)/layout.size.height)
                let scale = model.zoom == 0 ? fit : model.zoom
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        background.frame(width: layout.size.width*scale, height: layout.size.height*scale).clipped()
                        AnnotationCanvas(model: model)
                            .frame(width: CGFloat(model.source.width)*scale, height: CGFloat(model.source.height)*scale)
                            .clipShape(RoundedRectangle(cornerRadius: model.frame == .none ? 0 : model.cornerRadius*scale))
                            .shadow(color: .black.opacity(0.2), radius: model.frame == .none ? 2 : model.shadow*scale, y: model.frame == .none ? 1 : model.shadow*scale/2)
                            .offset(x: layout.origin.x*scale, y: layout.origin.y*scale)
                    }.frame(width: layout.size.width*scale, height: layout.size.height*scale)
                        .padding(30)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
            }
            bottomBar
        }
        .font(.system(size: 12)).background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.addImage(url) } } } }
            return true
        }
        .onChange(of: model.recognizedText) { _, text in if text != nil, model.activeSheet == nil { model.activeSheet = .ocr } }
        .sheet(item: $model.activeSheet, onDismiss: { if model.recognizedText != nil { model.activeSheet = .ocr } }) { sheet in
            switch sheet {
            case .text: textSheet
            case .ocr: ocrSheet
            case .background: BackgroundEditor(model: model)
            case .resize: ResizeEditor(model: model)
            case .palette: PaletteEditor(model: model)
            }
        }
        .alert("Couldn’t complete that action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    @ViewBuilder private var background: some View {
        if let data = model.customBackground, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill().clipped() }
        else { LinearGradient(colors: model.frame.colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing) }
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                roundButton("crop", "Crop") { model.tool = .crop }
                Menu {
                    Button("Resize Image…") { model.activeSheet = .resize }
                    Divider()
                    Button("Rotate Clockwise") { model.transform(orientation: 6) }
                    Button("Rotate Counterclockwise") { model.transform(orientation: 8) }
                    Button("Flip Horizontally") { model.transform(orientation: 2) }
                    Button("Flip Vertically") { model.transform(orientation: 4) }
                    Divider()
                    Menu("Crop Aspect Ratio") {
                        Button("Freeform") { model.cropAspect = nil; model.tool = .crop }
                        ForEach([1.0, 4.0/3, 16.0/9, 9.0/16], id: \.self) { ratio in Button(aspectName(ratio)) { model.cropAspect = ratio; model.tool = .crop } }
                    }
                } label: { Image(systemName: "rectangle.and.arrow.up.right.and.arrow.down.left").frame(width: 25, height: 26) }.menuStyle(.borderlessButton).fixedSize().help("Resize, rotate & flip")
                roundButton("photo", "Background") { model.activeSheet = .background }
            }
            Menu {
                ForEach(palette.colors, id: \.self) { hex in
                    Button { model.setColor(hex) } label: { Label(colorName(hex), systemImage: model.color == hex ? "checkmark.circle.fill" : "circle.fill") }
                }
                Divider()
                Button("Custom Color…") { colorPanel() }
                Button("Pick from Screen…") { model.pickScreenColor() }
                Button("Save Current Color") { palette.add(model.color) }
                Button("Edit Palette…") { model.activeSheet = .palette }
            } label: { Image(systemName: "circle.fill").font(.system(size: 16)).foregroundStyle(Color(hex: model.color)).padding(.leading, 7).padding(.vertical, 6) }.menuStyle(.borderlessButton).fixedSize().help("Annotation color")
            Menu {
                ForEach([2.0, 4, 6, 8, 12, 16, 24, 32], id: \.self) { width in Button("\(Int(width)) px") { model.setWidth(width) } }
            } label: { Image(systemName: "line.diagonal").font(.system(size: 15, weight: .bold)).padding(5) }.menuStyle(.borderlessButton).fixedSize().help("Stroke width")
            Menu {
                if model.tool == .text || model.selectedMark?.tool == .text {
                    ForEach(["plain", "bold", "outline", "shadow", "label", "border", "bubble"], id: \.self) { style in Button(style.capitalized) { model.setStyle(style) } }
                } else if model.tool == .blur || model.selectedMark?.tool == .blur {
                    Button("Strong Blur") { model.setStyle("strong") }; Button("Smooth Blur") { model.setStyle("smooth") }
                } else {
                    ForEach(["plain", "filled", "double", "curved"], id: \.self) { style in Button(style.capitalized) { model.setStyle(style) } }
                    Divider(); Button("Solid Redaction") { model.tool = .redact }
                }
            } label: { Image(systemName: model.tool == .text ? "textformat" : "arrow.up.right").padding(5) }.menuStyle(.borderlessButton).fixedSize().help("Tool style")
            Spacer(minLength: 0)
            Menu("Save as…") {
                Button("Image…") { model.export() }.keyboardShortcut("e", modifiers: .command)
                Button("Editable Project…") { model.saveProject() }
                Button("Save to Capture History") { model.save() }.keyboardShortcut("s", modifiers: .command)
            }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 11).padding(.vertical, 6).background(Color.primary.opacity(0.07), in: Capsule())
            Button("Done") { model.save(); if !model.dirty { NSApp.keyWindow?.performClose(nil) } }.buttonStyle(.borderedProminent).controlSize(.small).clipShape(Capsule())
        }
        .padding(.leading, 79).padding(.trailing, 14).frame(height: 48)
        .background(NativeMaterial(material: .titlebar)).overlay(alignment: .bottom) { Divider() }
    }
    /// Still's tool rail: drawing tools stacked down the left edge of the editor.
    private var toolRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 3) {
                ForEach(tools) { tool in
                    Button { model.tool = tool; model.selectedID = nil } label: {
                        Image(systemName: tool.symbol).font(.system(size: 14, weight: .medium)).frame(width: 34, height: 32)
                            .foregroundStyle(model.tool == tool ? Color.black.opacity(0.85) : Color.primary)
                            .background(model.tool == tool ? Color(red: 0.85, green: 0.91, blue: 0.68) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("\(tool.title) (\(tool.key.uppercased()))").accessibilityLabel(tool.title).accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }.padding(.vertical, 10).padding(.horizontal, 7)
        }.frame(width: 48).background(NativeMaterial(material: .titlebar)).overlay(alignment: .trailing) { Divider() }
    }
    private var bottomBar: some View {
        HStack(spacing: 9) {
            Menu(model.zoom == 0 ? "Fit" : "\(Int(model.zoom*100))%") { Button("Fit to Window") { model.zoom = 0 }; ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 3, 4], id: \.self) { value in Button("\(Int(value*100))%") { model.zoom = value } } }.menuStyle(.borderlessButton).fixedSize().padding(7).background(Color.primary.opacity(0.06), in: Capsule())
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(!model.canUndo).help("Undo (⌘Z)").accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.plain).disabled(!model.canRedo).help("Redo (⇧⌘Z)").accessibilityLabel("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
            Text("\(model.source.width) × \(model.source.height)\(model.dirty ? " •" : "")").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text("Drag to share").padding(.horizontal, 13).padding(.vertical, 7).background(Color.primary.opacity(0.07), in: Capsule())
                .overlay(DragSource(file: { model.dragFile() }).accessibilityLabel("Drag the edited image to another app"))
            Spacer()
            EditorStatus(library: model.library).frame(maxWidth: 170)
            roundButton("text.viewfinder", model.isRecognizing ? "Recognizing text…" : "Recognize Text") { model.recognize() }.disabled(model.isRecognizing)
            roundButton("square.and.arrow.up", "Share") { model.share() }
            roundButton("pin.fill", "Pin to Screen") { do { AppController.shared.pin(try model.flattened()) } catch { model.error = error.localizedDescription } }
            roundButton("doc.on.doc.fill", "Copy") { model.copy() }.keyboardShortcut("c", modifiers: [.command, .shift])
            roundButton("square.and.arrow.down", "Save Image") { model.export() }
            roundButton("icloud.and.arrow.up", "Upload to Cloud") { AppController.shared.uploadEditor(model) }
        }.padding(.horizontal, 13).frame(height: 45).background(NativeMaterial(material: .titlebar)).overlay(alignment: .top) { Divider() }
    }
    private func roundButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 27).background(Color.primary.opacity(0.07), in: Capsule()) }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private var textSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text").font(.headline)
            TextField("Enter text…", text: $model.textInput, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...7).frame(width: 380).focused($textFocused)
            HStack { Spacer(); Button("Cancel") { model.showTextSheet = false }.keyboardShortcut(.cancelAction); Button("Add Text") {
                if model.tool == .select, var mark = model.selectedMark, mark.tool == .text { model.beginChange(); mark.text = String(model.textInput.prefix(2000)); model.replace(mark) }
                else { var mark = Mark(tool: .text, points: [PixelPoint(model.textPoint)], color: model.color, width: model.lineWidth, text: String(model.textInput.prefix(2000))); mark.style = model.markStyle; model.commit(mark) }
                model.showTextSheet = false
            }.keyboardShortcut(.defaultAction).disabled(model.textInput.isEmpty) }
        }.padding(25).onAppear { textFocused = true }
    }
    private var ocrSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text Recognition").font(.headline)
            TextEditor(text: Binding(get: { model.recognizedText ?? "" }, set: { model.recognizedText = $0 })).font(.system(size: 14)).frame(width: 520, height: 280).border(Color.secondary.opacity(0.2))
            HStack { Text("Processed on your Mac").foregroundStyle(.secondary); Spacer(); Button("Done") { model.recognizedText = nil; model.activeSheet = nil }.keyboardShortcut(.cancelAction); Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.recognizedText ?? "", forType: .string); model.recognizedText = nil; model.activeSheet = nil; model.library.toast("Copied text") }.keyboardShortcut(.defaultAction) }
        }.padding(25)
    }
    private func colorPanel() { NSColorPanel.shared.setTarget(ColorReceiver.shared); ColorReceiver.shared.callback = { [weak model = model] in model?.setColor($0) }; NSColorPanel.shared.setAction(#selector(ColorReceiver.changed(_:))); NSColorPanel.shared.orderFront(nil) }
    private func colorName(_ hex: String) -> String { ["FF414E":"Red", "FF9C30":"Orange", "F8CE46":"Yellow", "41CD52":"Green", "1687FF":"Blue", "9C55E8":"Purple", "FFFFFF":"White", "141414":"Black"][hex] ?? hex }
    private func aspectName(_ ratio: Double) -> String { ratio == 1 ? "1:1" : ratio > 1.7 ? "16:9" : ratio > 1 ? "4:3" : "9:16" }
}

struct NativeMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView { let view = NSVisualEffectView(); view.material = material; view.blendingMode = .behindWindow; view.state = .active; return view }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
@MainActor final class ColorReceiver: NSObject {
    static let shared = ColorReceiver()
    var callback: ((String) -> Void)?
    @objc func changed(_ sender: NSColorPanel) { if let c = sender.color.usingColorSpace(.sRGB) { callback?(String(format: "%02X%02X%02X", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))) } }
}
struct EditorStatus: View {
    @ObservedObject var library: Library
    var body: some View { if let message = library.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) } }
}
struct ResizeEditor: View {
    @ObservedObject var model: EditorModel
    @State private var width = ""
    @State private var height = ""
    @State private var locked = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Resize Image").font(.headline)
            HStack { TextField("Width", text: $width).frame(width: 90); Text("×"); TextField("Height", text: $height).frame(width: 90); Text("pixels"); Toggle("Keep aspect ratio", isOn: $locked) }
                .onChange(of: width) { _, value in if locked, let w = Int(value) { height = String(Int(Double(w)*Double(model.source.height)/Double(model.source.width))) } }
            HStack { Spacer(); Button("Cancel") { model.activeSheet = nil }.keyboardShortcut(.cancelAction); Button("Resize") { if let w = Int(width), let h = Int(height) { model.resize(width: w, height: h); model.activeSheet = nil } }.keyboardShortcut(.defaultAction).disabled(Int(width) == nil || Int(height) == nil) }
        }.padding(25).onAppear { width = String(model.source.width); height = String(model.source.height) }
    }
}
struct BackgroundEditor: View {
    @ObservedObject var model: EditorModel
    @State private var presetName = ""
    @State private var presets: [String: Data] = UserDefaults.standard.dictionary(forKey: "backgroundPresets") as? [String: Data] ?? [:]
    var body: some View {
        HStack(spacing: 0) {
            VStack {
                if let image = try? model.flattened() { Image(decorative: image, scale: 1).resizable().scaledToFit().shadow(radius: 8).padding(28) }
                Text("Background").font(.headline).padding(.bottom, 20)
            }.frame(width: 390, height: 510).background(Color(nsColor: .underPageBackgroundColor))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("Background").font(.headline); Spacer(); Button("Done") { model.activeSheet = nil }.keyboardShortcut(.defaultAction) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 5), spacing: 7) {
                        ForEach(FrameStyle.allCases) { style in Button { model.customBackground = nil; model.frame = style } label: { RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: style == .none ? [Color(nsColor: .windowBackgroundColor)] : style.colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(height: 30).overlay(RoundedRectangle(cornerRadius: 6).stroke(model.frame == style ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: model.frame == style ? 2 : 0.5)).overlay { if style == .none { Image(systemName: "nosign").font(.system(size: 12)) } } }.buttonStyle(.plain).help(style.title).accessibilityLabel(style.title) }
                    }
                    Button("Choose Image…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; if panel.runModal() == .OK, let url = panel.url { do { model.customBackground = try Data(contentsOf: url); if model.frame == .none { model.frame = .snow } } catch { model.error = error.localizedDescription } } }
                    Picker("Aspect ratio", selection: Binding(get: { model.aspectRatio ?? 0 }, set: { model.aspectRatio = $0 == 0 ? nil : $0 })) { Text("Auto").tag(0.0); Text("1:1").tag(1.0); Text("4:3").tag(4.0/3); Text("16:9").tag(16.0/9); Text("9:16").tag(9.0/16) }
                    setting("Padding", value: $model.padding, range: 0...256)
                    setting("Corner Radius", value: $model.cornerRadius, range: 0...80)
                    setting("Shadow", value: $model.shadow, range: 0...100)
                    HStack {
                        Text("Alignment"); Spacer()
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 4), count: 3), spacing: 4) {
                            ForEach(0..<9) { index in Button { model.alignmentX = Double(index%3)/2; model.alignmentY = Double(index/3)/2 } label: { RoundedRectangle(cornerRadius: 2).fill(model.alignmentX == Double(index%3)/2 && model.alignmentY == Double(index/3)/2 ? Color.accentColor : Color.secondary.opacity(0.2)).frame(width: 14, height: 14) }.buttonStyle(.plain).accessibilityLabel("Alignment row \(index/3+1), column \(index%3+1)") }
                        }.frame(width: 56)
                    }
                    Button("Auto Balance") { model.autoBalance() }
                    Divider()
                    Text("Presets").font(.headline)
                    ForEach(presets.keys.sorted(), id: \.self) { name in HStack { Button(name) { if let data = presets[name], let doc = try? JSONDecoder().decode(BackgroundPreset.self, from: data) { model.frame = FrameStyle(rawValue: doc.frame) ?? .none; model.padding = doc.padding; model.cornerRadius = doc.radius; model.shadow = doc.shadow; model.aspectRatio = doc.aspect; model.customBackground = doc.image; model.alignmentX = doc.x ?? 0.5; model.alignmentY = doc.y ?? 0.5 } }; Spacer(); Button { presets[name] = nil; UserDefaults.standard.set(presets, forKey: "backgroundPresets") } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("Delete \(name) preset") } }
                    HStack { TextField("Preset name", text: $presetName); Button("Save") { if let data = try? JSONEncoder().encode(BackgroundPreset(frame: model.frame.rawValue, padding: model.padding, radius: model.cornerRadius, shadow: model.shadow, aspect: model.aspectRatio, image: model.customBackground, x: model.alignmentX, y: model.alignmentY)) { presets[presetName] = data; UserDefaults.standard.set(presets, forKey: "backgroundPresets"); presetName = "" } }.disabled(presetName.isEmpty) }
                }.padding(22)
            }.frame(width: 310, height: 510)
        }
    }
    private func setting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View { VStack { HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue)) px").foregroundStyle(.secondary) }; Slider(value: value, in: range, step: 1) } }
}
struct BackgroundPreset: Codable { var frame: String; var padding: Double; var radius: Double; var shadow: Double; var aspect: Double?; var image: Data?; var x: Double?; var y: Double? }

/// A native drag source: SwiftUI's onDrag gets swallowed by the transparent title bar window, and it
/// can't show the screenshot under the pointer. This hands other apps a real PNG file.
struct DragSource: NSViewRepresentable {
    let file: () -> URL?
    func makeNSView(context: Context) -> DragSourceView { DragSourceView(file: file) }
    func updateNSView(_ view: DragSourceView, context: Context) { view.file = file }
}

final class DragSourceView: NSView, NSDraggingSource {
    var file: () -> URL?
    private var start: NSPoint?
    init(file: @escaping () -> URL?) { self.file = file; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start, hypot(event.locationInWindow.x-start.x, event.locationInWindow.y-start.y) > 3, let url = file() else { return }
        self.start = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSImage(contentsOf: url) ?? NSImage()
        let width: CGFloat = 220, height = image.size.width > 0 ? width*image.size.height/image.size.width : 140
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x-width/2, y: point.y-height/2, width: width, height: height), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
