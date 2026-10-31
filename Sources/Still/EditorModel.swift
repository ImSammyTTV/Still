import AppKit
import SwiftUI
import Vision
import StillCore
import UniformTypeIdentifiers

struct EditSnapshot {
    var image: CGImage
    var marks: [Mark]
    var presentation: PresentationState
}
struct PresentationState { var frame: FrameStyle; var padding: Double; var radius: Double; var shadow: Double; var aspect: Double?; var image: Data?; var x: Double; var y: Double }
enum EditorSheet: String, Identifiable { case text, ocr, background, resize, palette; var id: String { rawValue } }

@MainActor
final class EditorModel: ObservableObject {
    @Published var source: CGImage { didSet { highlightLines = []; textLineID = UUID(); if tool == .highlight { loadHighlightLines() } } }
    @Published var marks: [Mark] = []
    @Published var tool = MarkTool.arrow { didSet { if tool == .highlight { loadHighlightLines() } } }
    @Published private(set) var highlightLines: [CGRect] = []
    private var textLineID = UUID()
    private var lineTask: Task<Void, Never>?
    @Published var color = "FF6148"
    @Published var lineWidth: Double = 5
    @Published var markStyle = "plain"
    @Published var selectedID: UUID?
    @Published var activeSheet: EditorSheet?
    @Published var cropAspect: Double?
    @Published var cornerRadius: Double = 12 { willSet { if !suppressChanges, newValue != cornerRadius { snapshot() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var shadow: Double = 24 { willSet { if !suppressChanges, newValue != shadow { snapshot() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var aspectRatio: Double? { willSet { if !suppressChanges, newValue != aspectRatio { snapshot() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var customBackground: Data? { willSet { if !suppressChanges, newValue != customBackground { snapshot() } } didSet { if !suppressChanges { dirty = true }; backdrop = nil } }
    private var backdrop: NSImage?
    /// The custom background as one image, so redraws don't decode it again.
    var backdropImage: NSImage? {
        if backdrop == nil, let customBackground { backdrop = NSImage(data: customBackground) }
        return backdrop
    }
    private let previewCache = PreviewCache()
    @Published var frame = FrameStyle.none { willSet { if !suppressChanges, newValue != frame { snapshot() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var padding: Double = 64 { willSet { if !suppressChanges, newValue != padding { snapshot() } } didSet { if !suppressChanges, frame != .none { dirty = true } } }
    @Published var alignmentX: Double = 0.5 { willSet { if !suppressChanges, newValue != alignmentX { snapshot() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var alignmentY: Double = 0.5 { willSet { if !suppressChanges, newValue != alignmentY { snapshot() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var zoom: Double = 0
    @Published var isRecognizing = false
    @Published var dirty = false
    @Published var error: String?
    @Published var recognizedText: String?
    var showTextSheet: Bool {
        get { activeSheet == .text }
        set { activeSheet = newValue ? .text : nil }
    }
    @Published var textInput = ""
    var textPoint = CGPoint.zero
    var item: CaptureItem?
    let isSample: Bool
    let library: Library
    private var suppressChanges = false
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var nextNumber: Int { marks.filter { $0.tool == .number }.count+1 }

    init(image: CGImage, item: CaptureItem? = nil, library: Library, isSample: Bool = false) {
        source = image; self.item = item; self.library = library; self.isSample = isSample
        lineWidth = Preferences.shared.annotateDefaultWidth; color = Preferences.shared.annotateDefaultColor
        tool = MarkTool(rawValue: Preferences.shared.annotateDefaultTool) ?? .arrow
    }
    private var currentSnapshot: EditSnapshot { EditSnapshot(image: source, marks: marks, presentation: PresentationState(frame: frame, padding: padding, radius: cornerRadius, shadow: shadow, aspect: aspectRatio, image: customBackground, x: alignmentX, y: alignmentY)) }
    private func apply(_ state: EditSnapshot) {
        suppressChanges = true
        source = state.image; marks = state.marks; frame = state.presentation.frame; padding = state.presentation.padding; cornerRadius = state.presentation.radius; shadow = state.presentation.shadow
        aspectRatio = state.presentation.aspect; customBackground = state.presentation.image; alignmentX = state.presentation.x; alignmentY = state.presentation.y; selectedID = nil
        suppressChanges = false; dirty = true
    }
    private func snapshot() {
        undoStack.append(currentSnapshot)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    private func loadHighlightLines() {
        guard highlightLines.isEmpty else { return }
        lineTask?.cancel()
        let image = source, id = textLineID
        lineTask = Task { [weak self] in
            let lines = try? await Task.detached(priority: .utility) { try TextRecognition.lineBounds(image) }.value
            guard !Task.isCancelled, let self, self.textLineID == id else { return }
            self.highlightLines = lines ?? []
        }
    }
    func smartHighlight(from start: CGPoint, to end: CGPoint) -> (CGPoint, CGPoint)? {
        guard let line = highlightLines.first(where: { $0.insetBy(dx: -12, dy: -$0.height*0.35).contains(start) }), abs(end.y-start.y) < line.height*1.3, abs(end.x-start.x) > line.height else { return nil }
        return (CGPoint(x: min(start.x, end.x), y: line.minY-line.height*0.12), CGPoint(x: max(start.x, end.x), y: line.maxY+line.height*0.12))
    }
    func commit(_ mark: Mark) {
        snapshot(); marks.append(mark); selectedID = mark.id; dirty = true
    }
    var selectedMark: Mark? { marks.first { $0.id == selectedID } }
    func beginChange() { snapshot() }
    func replace(_ mark: Mark) { if let index = marks.firstIndex(where: { $0.id == mark.id }) { marks[index] = mark; dirty = true } }
    func select(_ mark: Mark?) { selectedID = mark?.id; if let mark { color = mark.color; lineWidth = mark.width; markStyle = mark.style ?? "plain" } }
    func removeSelected() {
        guard selectedID != nil else { return }
        snapshot(); marks.removeAll { $0.id == selectedID }; selectedID = nil; dirty = true
    }
    func duplicateSelected() {
        guard var mark = selectedMark else { return }
        mark = mark.moved(dx: 20, dy: 20); mark.id = UUID(); commit(mark)
    }
    func pickScreenColor() {
        NSColorSampler().show { [weak self] color in
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "%02X%02X%02X", Int(color.redComponent*255), Int(color.greenComponent*255), Int(color.blueComponent*255))
            Task { @MainActor in self?.setColor(hex); ColorPalette.shared.add(hex) }
        }
    }
    func setColor(_ value: String) { color = value; if var mark = selectedMark, tool == .select { snapshot(); mark.color = value; replace(mark) } }
    func setWidth(_ value: Double) { lineWidth = value; if var mark = selectedMark, tool == .select { snapshot(); mark.width = value; replace(mark) } }
    func setStyle(_ value: String) { markStyle = value; if var mark = selectedMark, tool == .select { snapshot(); mark.style = value; replace(mark) } }
    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot); apply(state)
    }
    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot); apply(state)
    }
    func crop(_ rect: CGRect) {
        do {
            let rendered = try ImageRenderer.render(source, marks: marks)
            let cropped = try ImageRenderer.crop(rendered, to: rect)
            snapshot(); source = cropped; marks = []; selectedID = nil; dirty = true
        } catch { self.error = error.localizedDescription }
    }
    /// The picture as it leaves the editor, with the watermark from Settings unless it's left off this one.
    func flattened(watermarked: Bool = true) throws -> CGImage {
        let image = try ImageRenderer.render(source, marks: marks, frame: frame, padding: Int(padding), cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY)
        guard watermarked, watermarkOn, let watermark = Preferences.shared.watermark else { return image }
        return watermark.apply(to: image)
    }
    /// Whether this picture gets the watermark; the stamp button in the toolbar turns it off for just this one.
    @Published var watermarkOn = true
    /// The flattened picture at the size the Background sheet shows it, quick enough to follow a slider.
    func flattenedPreview() throws -> CGImage {
        let image = try ImageRenderer.render(source, marks: marks, frame: frame, padding: Int(padding), cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY, maxDimension: 800, cache: previewCache)
        guard watermarkOn, let watermark = Preferences.shared.watermark else { return image }
        return watermark.apply(to: image)
    }
    func document() throws -> ProjectDocument { try ProjectDocument(source: source, marks: marks, frame: frame, padding: padding, cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY) }
    var canvasLayout: (size: CGSize, origin: CGPoint) { ImageRenderer.canvasLayout(source: CGSize(width: source.width, height: source.height), framed: frame != .none || customBackground != nil, padding: Int(padding), aspect: aspectRatio, alignmentX: alignmentX, alignmentY: alignmentY) }
    func autoBalance() {
        do { let image = try ImageRenderer.render(source, marks: marks); crop(ImageRenderer.contentBounds(image)); alignmentX = 0.5; alignmentY = 0.5 }
        catch { self.error = error.localizedDescription }
    }
    func restore(_ document: ProjectDocument) {
        guard let image = document.sourceImage() else { return }
        suppressChanges = true
        source = image; marks = document.marks; frame = FrameStyle(rawValue: document.frame) ?? .none
        padding = document.padding; cornerRadius = document.cornerRadius; shadow = document.shadow
        aspectRatio = document.aspectRatio; customBackground = document.customBackground; dirty = false
        alignmentX = document.alignmentX ?? 0.5; alignmentY = document.alignmentY ?? 0.5
        suppressChanges = false
    }
    func save() {
        do {
            let image = try flattened()
            // The capture was deleted from history while this editor was open: save it as a new one.
            if let current = item, !library.items.contains(where: { $0.id == current.id }) { item = nil }
            if item == nil { item = try library.add(image: image, title: isSample ? "Sample annotation" : "Edited image") }
            if let item { try library.update(item, image: image, document: document()) }
            dirty = false
            AppController.shared?.rekeyEditor(self)
            library.toast("Changes saved to library")
        } catch { self.error = error.localizedDescription }
    }
    func copy() {
        do { library.copy(try flattened()) }
        catch { self.error = error.localizedDescription }
    }
    func saveProject() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "local.sam.still.project", conformingTo: .json)]
        panel.nameFieldStringValue = "\(item?.title ?? "Capture").stillshot"
        if panel.runModal() == .OK, let url = panel.url { do { try document().write(url); library.toast("Editable project saved") } catch { self.error = error.localizedDescription } }
    }
    func transform(orientation: Int32) {
        do { let image = try ImageRenderer.orient(ImageRenderer.render(source, marks: marks), orientation: orientation); snapshot(); source = image; marks = []; selectedID = nil; dirty = true }
        catch { self.error = error.localizedDescription }
    }
    func resize(width: Int, height: Int) {
        do { let image = try ImageRenderer.resize(ImageRenderer.render(source, marks: marks), width: width, height: height); snapshot(); source = image; marks = []; selectedID = nil; dirty = true }
        catch { self.error = error.localizedDescription }
    }
    func addImage(_ url: URL, at point: CGPoint? = nil) {
        guard let image = ImageRenderer.load(url) else { error = "This image could not be opened."; return }
        do {
            let ratio = min(1, Double(source.width)/Double(image.width)*0.65, Double(source.height)/Double(image.height)*0.65)
            let w = Double(image.width)*ratio, h = Double(image.height)*ratio
            let origin = point ?? CGPoint(x: (Double(source.width)-w)/2, y: (Double(source.height)-h)/2)
            var mark = Mark(tool: .image, points: [PixelPoint(origin), PixelPoint(x: origin.x+w, y: origin.y+h)])
            mark.imageData = try ImageRenderer.data(image); commit(mark); tool = .select
        } catch { self.error = error.localizedDescription }
    }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { addImage(url) }
    }
    /// Writes the current edit to a temporary PNG named after the capture, for dragging into other apps.
    func dragFile() -> URL? {
        do {
            let name = (item?.title ?? "Screenshot").replacingOccurrences(of: "/", with: "-")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-drag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name + ".png")
            try ImageRenderer.data(flattened()).write(to: url)
            return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func dragProvider() -> NSItemProvider {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-\(UUID()).png")
            try ImageRenderer.data(flattened()).write(to: url)
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } catch { self.error = error.localizedDescription; return NSItemProvider() }
    }
    func share() {
        do {
            let image = NSImage(cgImage: try flattened(), size: .zero)
            let picker = NSSharingServicePicker(items: [image])
            if let view = NSApp.keyWindow?.contentView { picker.show(relativeTo: NSRect(x: view.bounds.maxX-200, y: 20, width: 1, height: 1), of: view, preferredEdge: .minY) }
        } catch { self.error = error.localizedDescription }
    }
    func export() {
        do { library.export(try flattened(), title: item?.title ?? "Still capture") }
        catch { self.error = error.localizedDescription }
    }
    /// Covers every email address, card number, key, IP address and phone number found in the picture with a redact
    /// box, as one step that a single undo takes back.
    func hidePrivate() {
        guard !isRecognizing else { return }
        isRecognizing = true
        let image = source
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) { try PrivateInfo.boxes(in: image) }.value
                let fresh = found.filter { box in !marks.contains { $0.tool == .redact && $0.rect.insetBy(dx: -1, dy: -1).contains(box) } }
                if fresh.isEmpty { library.toast(found.isEmpty ? "No private details found" : "Everything private is already hidden") }
                else {
                    snapshot()
                    for box in fresh { marks.append(Mark(tool: .redact, points: [PixelPoint(x: box.minX, y: box.minY), PixelPoint(x: box.maxX, y: box.maxY)], color: color, width: lineWidth)) }
                    selectedID = nil; dirty = true
                    library.toast("Hid \(fresh.count) private detail\(fresh.count == 1 ? "" : "s"). Undo brings them back.")
                }
            } catch { self.error = "Couldn’t look for private details: \(error.localizedDescription)" }
            isRecognizing = false
        }
    }
    func recognize() {
        guard !isRecognizing else { return }
        isRecognizing = true
        let image: CGImage
        do { image = try flattened(watermarked: false) } catch { self.error = error.localizedDescription; isRecognizing = false; return }
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try TextRecognition.recognize(image)
                }.value
                recognizedText = text.isEmpty ? "No readable text found. Try a larger, clearer capture." : text
            } catch { self.error = "Text recognition failed: \(error.localizedDescription)" }
            isRecognizing = false
        }
    }
}
