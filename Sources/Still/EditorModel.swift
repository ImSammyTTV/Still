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
/// Everything needed to draw the edited picture, copied from the editor in one go. Drawing and encoding a full-size
/// picture can take a second on a big display, so Save, Copy, Pin, Share and Save As hand this to a background task
/// and the editor stays responsive meanwhile; later edits don't change a drawing already under way.
struct EditRender {
    let source: CGImage
    let marks: [Mark]
    let frame: FrameStyle
    let padding: Double, cornerRadius: Double, shadow: Double
    let aspectRatio: Double?
    let customBackground: Data?
    let alignmentX: Double, alignmentY: Double
    let watermark: Watermark?
    func image() throws -> CGImage {
        let image = try ImageRenderer.render(source, marks: marks, frame: frame, padding: Int(padding), cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY)
        return watermark?.apply(to: image) ?? image
    }
    func document() throws -> ProjectDocument {
        try ProjectDocument(source: source, marks: marks, frame: frame, padding: padding, cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY)
    }
    /// Writes the picture as "<name>.png" in a new temporary folder, for dragging into other apps, with a small copy
    /// for the picture that follows the pointer.
    func dragFile(named name: String) throws -> (url: URL, preview: CGImage?) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".png"), picture = try image()
        try ImageRenderer.data(picture).write(to: url)
        return (url, ImageRenderer.thumbnail(picture, maxPixelSize: 440))
    }
}
enum EditorSheet: String, Identifiable { case text, ocr, background, resize, palette, saveForSize; var id: String { rawValue } }

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
    /// A social media size the next crop is scaled to; it also locks the crop to that shape.
    @Published var cropSize: SocialSizes.Size?
    @Published var cornerRadius: Double = 12 { willSet { if !suppressChanges, newValue != cornerRadius { willChange() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var shadow: Double = 24 { willSet { if !suppressChanges, newValue != shadow { willChange() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var aspectRatio: Double? { willSet { if !suppressChanges, newValue != aspectRatio { willChange() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var customBackground: Data? { willSet { if !suppressChanges, newValue != customBackground { willChange() } } didSet { if !suppressChanges { dirty = true }; backdrop = nil; backgroundVersion &+= 1 } }
    /// Changes whenever the custom background does, so a view can tell without comparing the image's bytes.
    private(set) var backgroundVersion = 0
    private var backdrop: NSImage?
    /// The custom background as one image, so redraws don't decode it again.
    var backdropImage: NSImage? {
        if backdrop == nil, let customBackground { backdrop = NSImage(data: customBackground) }
        return backdrop
    }
    private let previewCache = PreviewCache()
    @Published var frame = FrameStyle.none { willSet { if !suppressChanges, newValue != frame { willChange() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var padding: Double = 64 { willSet { if !suppressChanges, newValue != padding { willChange() } } didSet { if !suppressChanges, frame != .none { dirty = true } } }
    @Published var alignmentX: Double = 0.5 { willSet { if !suppressChanges, newValue != alignmentX { willChange() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var alignmentY: Double = 0.5 { willSet { if !suppressChanges, newValue != alignmentY { willChange() } } didSet { if !suppressChanges { dirty = true } } }
    @Published var zoom: Double = 0
    @Published var isRecognizing = false
    @Published var dirty = false { didSet { if dirty { edits &+= 1; prepareDragFile() } } }
    /// Counts edits, so a save running in the background knows whether more were made while it ran.
    private var edits = 0
    @Published private(set) var saving = false
    /// Counts saves, so a background save that a newer one (saving as the window closes) has overtaken doesn't write
    /// its older picture over the newer one.
    private var saveGeneration = 0
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
        prepareDragFile()
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
        limitUndoPictures()
    }
    /// Steps that only add, move or restyle marks hold the very same picture as the step before (a CGImage is shared,
    /// never copied), so they cost next to nothing. A crop, turn or resize makes a new full-size picture, though, and
    /// thirty of those from a big display could hold gigabytes. So at most this many different pictures are kept for
    /// undo: past that the oldest steps are let go. The trade-off is that after many crops or resizes in a row, undo
    /// can't go all the way back to the first one, but the editor's memory stays bounded however long you edit.
    private static let undoPictureLimit = 8
    private func limitUndoPictures() {
        func pictures() -> Int { Set((undoStack+redoStack).map { ObjectIdentifier($0.image) }).count }
        while !undoStack.isEmpty, pictures() > Self.undoPictureLimit { undoStack.removeFirst() }
    }
    /// While a Background slider is held, the whole drag is one undo step: the picture before it is kept once, at the
    /// first change, instead of on every tick (which also pushed the earlier steps off the undo list).
    private var holdingSlider = false, sliderSnapshotTaken = false
    private func willChange() {
        if holdingSlider { if sliderSnapshotTaken { return }; sliderSnapshotTaken = true }
        snapshot()
    }
    /// Pass to a slider's onEditingChanged: true when it's grabbed, false when it's let go.
    func sliderEditing(_ editing: Bool) { holdingSlider = editing; sliderSnapshotTaken = false }
    private var previewRender: Task<CGImage?, Never>?
    /// The Background sheet's preview, drawn off the main thread so a slider never waits for it. One drawing runs at
    /// a time, as they share a cache.
    func backgroundPreview() async -> CGImage? {
        let previous = previewRender
        let source = source, marks = marks, frame = frame, padding = padding, cornerRadius = cornerRadius, shadow = shadow
        let aspectRatio = aspectRatio, customBackground = customBackground, alignmentX = alignmentX, alignmentY = alignmentY
        let watermark = watermarkOn ? Preferences.shared.watermark : nil, cache = previewCache
        let render = Task.detached(priority: .userInitiated) { () -> CGImage? in
            _ = await previous?.value
            guard let image = try? ImageRenderer.render(source, marks: marks, frame: frame, padding: Int(padding), cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY, maxDimension: 800, cache: cache) else { return nil }
            return watermark?.apply(to: image) ?? image
        }
        previewRender = render
        return await render.value
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
    /// The emoji the Stamp tool drops, remembered between pictures.
    @Published var stamp = UserDefaults.standard.string(forKey: "stampEmoji").flatMap { Mark.stamps.contains($0) ? $0 : nil } ?? "✅"
    func setStamp(_ emoji: String) {
        stamp = emoji; UserDefaults.standard.set(emoji, forKey: "stampEmoji")
        if var mark = selectedMark, mark.tool == .stamp { snapshot(); mark.text = emoji; replace(mark) }
    }
    func setStyle(_ value: String) { markStyle = value; if var mark = selectedMark, tool == .select { snapshot(); mark.style = value; replace(mark) } }
    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot); apply(state)
    }
    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot); apply(state)
    }
    /// Crops to `rect`, scaled to the social media size picked for it unless `sized` is false. Says whether it worked.
    @discardableResult
    func crop(_ rect: CGRect, sized: Bool = true) -> Bool {
        do {
            let rendered = try ImageRenderer.render(source, marks: marks)
            var cropped = try ImageRenderer.crop(rendered, to: rect)
            let size = sized ? cropSize : nil
            // A size crops and then scales to exactly its pixels, as one step that one undo takes back.
            if let size { cropped = try ImageRenderer.resize(cropped, width: size.width, height: size.height) }
            snapshot(); source = cropped; marks = []; selectedID = nil; dirty = true
            if let size { library.toast("\(size.title): \(SocialSizes.note(crop: rect, size: size))"); cropSize = nil; cropAspect = nil }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Locks the crop tool to a size (or back to any shape with nil).
    func chooseCropSize(_ size: SocialSizes.Size?) {
        cropSize = size; cropAspect = size?.aspect; tool = .crop
        if let size { library.toast("Drag over the part to keep for \(size.title)") }
    }
    /// What the picture looks like right now, to draw in the background, with the watermark from Settings unless it's
    /// left off this one.
    func renderSnapshot(watermarked: Bool = true) -> EditRender {
        EditRender(source: source, marks: marks, frame: frame, padding: padding, cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio,
                   customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY, watermark: watermarked && watermarkOn ? Preferences.shared.watermark : nil)
    }
    /// The picture as it leaves the editor, drawn right here. Only for when the answer is needed before returning
    /// (saving as the window closes); everything else draws a `renderSnapshot()` in the background.
    func flattened(watermarked: Bool = true) throws -> CGImage { try renderSnapshot(watermarked: watermarked).image() }
    /// Draws the picture off the main thread and hands it back here.
    private func renderedInBackground() async throws -> CGImage {
        let job = renderSnapshot()
        return try await Task.detached(priority: .userInitiated) { try job.image() }.value
    }
    /// Whether this picture gets the watermark; the stamp button in the toolbar turns it off for just this one.
    @Published var watermarkOn = true { didSet { prepareDragFile() } }
    func document() throws -> ProjectDocument { try ProjectDocument(source: source, marks: marks, frame: frame, padding: padding, cornerRadius: cornerRadius, shadow: shadow, aspectRatio: aspectRatio, customBackground: customBackground, alignmentX: alignmentX, alignmentY: alignmentY) }
    var canvasLayout: (size: CGSize, origin: CGPoint) { ImageRenderer.canvasLayout(source: CGSize(width: source.width, height: source.height), framed: frame != .none || customBackground != nil, padding: Int(padding), aspect: aspectRatio, alignmentX: alignmentX, alignmentY: alignmentY) }
    /// Trims the empty edges and centres the picture, as one step that a single undo takes back. It leaves out any
    /// social media size picked for the next crop, and if the trim fails nothing else changes.
    func autoBalance() {
        do {
            let image = try ImageRenderer.render(source, marks: marks)
            guard crop(ImageRenderer.contentBounds(image), sized: false) else { return }
            // The crop's undo step already holds the alignment from before, so this isn't a step of its own.
            suppressChanges = true; alignmentX = 0.5; alignmentY = 0.5; suppressChanges = false
            dirty = true
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ document: ProjectDocument) {
        guard let image = document.sourceImage() else { return }
        suppressChanges = true
        source = image; marks = document.marks; frame = FrameStyle(rawValue: document.frame) ?? .none
        padding = document.padding; cornerRadius = document.cornerRadius; shadow = document.shadow
        aspectRatio = document.aspectRatio; customBackground = document.customBackground; dirty = false
        alignmentX = document.alignmentX ?? 0.5; alignmentY = document.alignmentY ?? 0.5
        suppressChanges = false
        // A different picture without marking it edited: count it anyway, so the file kept ready for dragging is redrawn.
        edits &+= 1; prepareDragFile()
    }
    /// Saves to Capture History. Rendering and encoding a full-size picture takes a second or more on a big display,
    /// so it runs in the background and the editor stays responsive; `done` runs once it's saved.
    func save(then done: (() -> Void)? = nil) {
        if !dirty, let current = item, library.items.contains(where: { $0.id == current.id }) { done?(); return }
        guard !saving else { return }
        saving = true
        saveGeneration &+= 1
        let job = renderSnapshot(), started = edits, generation = saveGeneration
        Task {
            do {
                let (png, project, width, height) = try await Task.detached(priority: .userInitiated) { () throws -> (Data, ProjectDocument, Int, Int) in
                    let image = try job.image()
                    return (try ImageRenderer.libraryData(image), try job.document(), image.width, image.height)
                }.value
                // Saved again as the window closed while this was drawn: that save has the newer edits, so this one
                // writes nothing.
                guard generation == saveGeneration else { return }
                // The capture was deleted from history while this editor was open: save it as a new one.
                if let current = item, !library.items.contains(where: { $0.id == current.id }) { item = nil }
                if item == nil { item = try library.add(png: png, width: width, height: height, title: isSample ? "Sample annotation" : "Edited image") }
                if let item { try await library.update(item, png: png, width: width, height: height, document: project) }
                guard generation == saveGeneration else { return }
                if edits == started { dirty = false }
                saving = false
                AppController.shared?.rekeyEditor(self)
                library.toast("Changes saved to library")
                done?()
            } catch { if generation == saveGeneration { saving = false; self.error = error.localizedDescription } }
        }
    }
    /// Saves before returning, for the "Save your edits?" prompt when the window closes.
    func saveNow() {
        // A background save still under way drew an older picture: it stands down, and this one is the save that counts.
        saveGeneration &+= 1; saving = false
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
        let job = renderSnapshot()
        Task {
            do {
                let png = try await Task.detached(priority: .userInitiated) { try ImageRenderer.data(job.image()) }.value
                library.copy(png: png)
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Pin to Screen: the edited picture floats above other windows once it's drawn.
    func pin() {
        Task {
            do {
                let image = try await renderedInBackground()
                AppController.shared.pin(image)
            } catch { self.error = error.localizedDescription }
        }
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
    // "Drag to share" has to hand over a finished file the moment the drag starts, and drawing and encoding a big
    // picture right then froze the editor mid-gesture. So a PNG of the current edit is kept ready instead: it's redrawn
    // in the background half a second after the last change, and a drag just uses it.
    private struct DragKey: Equatable { var edits: Int; var watermark: Watermark?; var name: String }
    private struct DragFile { var key: DragKey; var url: URL; var preview: CGImage?; var handedOut: Bool }
    private var dragReady: DragFile?
    private var dragRefresh: Task<Void, Never>?
    private var dragName: String { (item?.title ?? "Screenshot").replacingOccurrences(of: "/", with: "-") }
    /// What the ready file must have been drawn from to still be the picture on screen.
    private var dragKey: DragKey { DragKey(edits: edits, watermark: watermarkOn ? Preferences.shared.watermark : nil, name: dragName) }
    /// Redraws the file kept ready for dragging once edits pause for half a second.
    private func prepareDragFile() {
        dragRefresh?.cancel()
        dragRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            let key = self.dragKey
            if self.dragReady?.key == key { return }
            let job = self.renderSnapshot(), name = key.name
            let drawn = try? await Task.detached(priority: .utility) { try job.dragFile(named: name) }.value
            guard let made = drawn else { return }
            // Edited again while it was drawn: this one is already out of date, and the next round replaces it.
            guard !Task.isCancelled, self.dragKey == key else { EditorModel.discardDragFolder(made.url); return }
            self.keepDragFile(DragFile(key: key, url: made.url, preview: made.preview, handedOut: false))
        }
    }
    private func keepDragFile(_ file: DragFile) {
        // A file already given to a drag stays for a while: the app it was dropped on may still be reading it.
        if let old = dragReady, old.url != file.url { EditorModel.discardDragFolder(old.url, after: old.handedOut ? Self.handedOutGrace : 0) }
        dragReady = file
    }
    /// When the editor closes: the file kept ready goes, after a while if a drag took it.
    func discardDragFile() {
        dragRefresh?.cancel(); dragRefresh = nil
        if let ready = dragReady { EditorModel.discardDragFolder(ready.url, after: ready.handedOut ? Self.handedOutGrace : 0) }
        dragReady = nil
    }
    /// How long a file given to a drag is kept, so the app it was dropped on has time to read it, before it goes.
    private static let handedOutGrace: Double = 10*60
    private static func discardDragFolder(_ file: URL, after delay: Double = 0) {
        let folder = file.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+delay) { try? FileManager.default.removeItem(at: folder) }
    }
    /// At launch: drag files left behind when Still last quit before it could tidy them away, once they're an hour old.
    nonisolated static func sweepDragFolders() {
        DispatchQueue.global(qos: .utility).async {
            let temporary = FileManager.default.temporaryDirectory, cutoff = Date().addingTimeInterval(-60*60)
            let folders = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for folder in folders where folder.lastPathComponent.hasPrefix("Still-drag-") {
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }
    /// The current edit as a PNG file named after the capture, for dragging into other apps, with a small preview to
    /// show under the pointer. Normally the file kept ready; only a drag within half a second of a change draws it here.
    func dragFile() -> (url: URL, preview: CGImage?)? {
        let key = dragKey
        if var ready = dragReady, ready.key == key {
            ready.handedOut = true; dragReady = ready
            return (ready.url, ready.preview)
        }
        do {
            let made = try renderSnapshot().dragFile(named: key.name)
            keepDragFile(DragFile(key: key, url: made.url, preview: made.preview, handedOut: true))
            return made
        } catch { self.error = error.localizedDescription; return nil }
    }
    func share() {
        // The picker opens on the window Share was clicked in, even if another is in front by the time it's drawn.
        let window = NSApp.keyWindow
        Task {
            do {
                let drawn = try await renderedInBackground()
                let image = NSImage(cgImage: drawn, size: .zero)
                let picker = NSSharingServicePicker(items: [image])
                if let view = (window ?? NSApp.keyWindow)?.contentView { picker.show(relativeTo: NSRect(x: view.bounds.maxX-200, y: 20, width: 1, height: 1), of: view, preferredEdge: .minY) }
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Save As: the Save panel opens straight away; the picture is drawn and encoded in the background once a place is
    /// chosen.
    func export() {
        let job = renderSnapshot()
        library.export(title: item?.title ?? "Still capture") { try job.image() }
    }
    @Published var makingSize = false
    /// Save for Size: the edited picture as a square or as it is, at a width, under a file size, then a Save panel.
    func saveForSize(square: Bool, width: Int, limitKB: Int, jpeg: Bool) {
        guard !makingSize else { return }
        makingSize = true
        let job = renderSnapshot(), title = item?.title ?? "Still capture"
        Task {
            defer { makingSize = false }
            do {
                let out = try await Task.detached(priority: .userInitiated) { () throws -> (data: Data, width: Int, height: Int, fits: Bool) in
                    let image = try job.image()
                    let plan = ExportSize.plan(width: image.width, height: image.height, square: square, width: width)
                    return try ExportSize.make(image, plan: plan, limit: limitKB*1024, jpeg: jpeg)
                }.value
                activeSheet = nil
                let panel = NSSavePanel(); panel.allowedContentTypes = [jpeg ? .jpeg : .png]
                panel.nameFieldStringValue = "\(title) \(out.width)×\(out.height).\(jpeg ? "jpg" : "png")"
                if !library.exportFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: library.exportFolder) }
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try out.data.write(to: destination, options: .atomic)
                let size = "\(out.width) × \(out.height), \(ExportSize.label(out.data.count))"
                library.toast(out.fits ? "Saved \(destination.lastPathComponent): \(size)" : "Saved at \(size): the smallest Still could make, still over \(limitKB) KB")
            } catch { self.error = error.localizedDescription }
        }
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
                // Cropped, turned, resized or undone while Still was looking: the boxes were found on the old picture
                // and would land in the wrong places on this one, leaving private details showing.
                guard source === image else { library.toast("The picture changed while Still was looking. Try again."); isRecognizing = false; return }
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
    /// Blurs every line of text found in the picture, as one step that a single undo takes back: the layout stays
    /// readable while the words don't.
    func blurAllText() {
        guard !isRecognizing else { return }
        isRecognizing = true
        let image = source
        Task {
            do {
                let lines = try await Task.detached(priority: .userInitiated) { try TextRecognition.lineBounds(image) }.value
                // The lines were found on the picture as it was; a crop, turn, resize or undo since would misplace them.
                guard source === image else { library.toast("The picture changed while Still was looking. Try again."); isRecognizing = false; return }
                if lines.isEmpty { library.toast("No text found") }
                else {
                    snapshot()
                    for line in lines {
                        let box = line.insetBy(dx: -3, dy: -3)
                        var mark = Mark(tool: .blur, points: [PixelPoint(x: box.minX, y: box.minY), PixelPoint(x: box.maxX, y: box.maxY)], color: color, width: lineWidth)
                        mark.style = "smooth"; marks.append(mark)
                    }
                    selectedID = nil; dirty = true
                    library.toast("Blurred \(lines.count) line\(lines.count == 1 ? "" : "s") of text. Undo brings them back.")
                }
            } catch { self.error = "Couldn’t look for text: \(error.localizedDescription)" }
            isRecognizing = false
        }
    }
    func recognize() {
        guard !isRecognizing else { return }
        isRecognizing = true
        let job = renderSnapshot(watermarked: false)
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try TextRecognition.recognize(job.image())
                }.value
                recognizedText = text.isEmpty ? "No readable text found. Try a larger, clearer capture." : text
            } catch { self.error = "Text recognition failed: \(error.localizedDescription)" }
            isRecognizing = false
        }
    }
}
