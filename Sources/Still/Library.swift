import AppKit
import SwiftUI
import StillCore
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []
    @Published var message: String?
    @Published var busy = false
    @Published var query = ""
    @Published var page = "General"
    @Published var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published var permissionError: String?
    @AppStorage("autoCopy") var autoCopy = true
    @AppStorage("showPreview") var showPreview = true
    @AppStorage("captureSound") var captureSound = false
    @AppStorage("systemAudio") var systemAudio = false
    @AppStorage("microphoneAudio") var microphoneAudio = false
    @AppStorage("exportJPEG") var exportJPEG = false
    @AppStorage("exportFolder") var exportFolder = ""
    let root: URL
    /// Decoded previews, bounded so a long history can't grow without limit. 560 px previews cost about 1 MB each.
    private let thumbnails: NSCache<NSUUID, NSImage> = { let cache = NSCache<NSUUID, NSImage>(); cache.totalCostLimit = 128*1024*1024; return cache }()
    /// One token per decode in flight, so a result for a file that has since changed is dropped.
    private var loadingThumbnails: [UUID: UUID] = [:]
    /// PNG decoding is the slow part of showing History; it never runs on the main thread, and only a few run at once.
    static let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Still thumbnails"; queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount-2)); return queue
    }()
    private var thumbnailChangeQueued = false
    private var toastID = UUID()
    private var defaultsObserver: NSObjectProtocol?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/Captures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
            let index = self.root.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                if let decoded = try? JSONDecoder().decode([CaptureItem].self, from: Data(contentsOf: index)) {
                    items = decoded.filter { !$0.filename.contains("/") && FileManager.default.fileExists(atPath: self.root.appendingPathComponent($0.filename).path) }
                } else {
                    // A damaged index must never be overwritten by the next capture: keep it aside and rebuild the
                    // history from the capture files themselves, so nothing is orphaned.
                    let stamp = Int(Date().timeIntervalSince1970)
                    try? FileManager.default.moveItem(at: index, to: self.root.appendingPathComponent("index-damaged-\(stamp).json"))
                    items = rebuiltItems()
                    try? persist()
                    message = "Capture history was damaged and has been rebuilt from your capture files."
                }
            }
        } catch { message = "Couldn’t load capture history: \(error.localizedDescription)" }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
    }

    /// Every capture file in the folder, newest first, for when the index can't be read.
    private func rebuiltItems() -> [CaptureItem] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return files.filter { ["png", "mp4", "gif"].contains($0.pathExtension.lowercased()) }
            .sorted { ((try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .map { file in
                let video = file.pathExtension.lowercased() != "png", image = video ? nil : ImageRenderer.load(file)
                return CaptureItem(filename: file.lastPathComponent, title: "Recovered capture", isVideo: video, width: image?.width ?? 0, height: image?.height ?? 0)
            }
    }
    var filtered: [CaptureItem] {
        items.filter { (page != "recordings" || $0.isVideo) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    func url(_ item: CaptureItem) -> URL { root.appendingPathComponent(item.filename) }
    func persist() throws {
        try JSONEncoder().encode(items).write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }
    @discardableResult
    func add(file: URL, title: String, video: Bool = false) throws -> CaptureItem {
        pruneHistory()
        let name = "\(UUID().uuidString).\(video ? (file.pathExtension.lowercased() == "gif" ? "gif" : "mp4") : "png")"
        let destination = root.appendingPathComponent(name)
        if video { try FileManager.default.copyItem(at: file, to: destination) }
        else {
            guard let image = ImageRenderer.load(file) else { throw RenderError.encoding }
            try ImageRenderer.data(image).write(to: destination, options: .atomic)
        }
        let image = video ? nil : ImageRenderer.load(destination)
        let item = CaptureItem(filename: name, title: title, isVideo: video, width: image?.width ?? 0, height: image?.height ?? 0)
        items.insert(item, at: 0)
        do { try persist() } catch { items.removeAll { $0.id == item.id }; try? FileManager.default.removeItem(at: destination); throw error }
        return item
    }
    @discardableResult
    func add(image: CGImage, title: String) throws -> CaptureItem {
        try add(png: try ImageRenderer.libraryData(image), width: image.width, height: image.height, title: title)
    }
    /// Stores PNG bytes from ImageRenderer.libraryData as they are, for captures encoded off the main thread.
    @discardableResult
    func add(png: Data, width: Int, height: Int, title: String) throws -> CaptureItem {
        pruneHistory()
        let name = "\(UUID().uuidString).png"
        let destination = root.appendingPathComponent(name)
        try png.write(to: destination, options: .atomic)
        let item = CaptureItem(filename: name, title: title, isVideo: false, width: width, height: height)
        items.insert(item, at: 0)
        do { try persist() } catch { items.removeAll { $0.id == item.id }; try? FileManager.default.removeItem(at: destination); throw error }
        return item
    }
    func update(_ item: CaptureItem, image: CGImage, document: ProjectDocument? = nil) throws {
        try ImageRenderer.data(image).write(to: url(item), options: .atomic)
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx].width = image.width; items[idx].height = image.height }
        if let document, let idx = items.firstIndex(where: { $0.id == item.id }) {
            let name = "\(item.id.uuidString).stillshot"
            try document.write(root.appendingPathComponent(name)); items[idx].projectFilename = name
        }
        forgetThumbnail(item.id)
        try persist()
        objectWillChange.send()
    }
    func rename(_ item: CaptureItem, title: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].title = String(title.prefix(200))
        do { try persist() } catch { toast(error.localizedDescription) }
    }
    func project(_ item: CaptureItem) -> ProjectDocument? {
        guard let saved = items.first(where: { $0.id == item.id }), let name = saved.projectFilename, !name.contains("/") else { return nil }
        return try? ProjectDocument.read(root.appendingPathComponent(name))
    }
    func pruneHistory() {
        let days = Preferences.shared.retentionDays
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        for item in items where item.date < cutoff { delete(item) }
    }
    func delete(_ item: CaptureItem) {
        do {
            try FileManager.default.trashItem(at: url(item), resultingItemURL: nil)
            let camera = recordingMetadata(item).cameraFilename
            let sidecars = [item.projectFilename, item.metadataFilename, item.sourceVideoFilename, camera, "\(item.id).videoedit.json"].compactMap { $0 }
            for name in Set(sidecars) where !name.contains("/") && name != "." && name != ".." {
                let file = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            }
            items.removeAll { $0.id == item.id }; forgetThumbnail(item.id)
            try persist(); toast("Moved to Trash")
        } catch { toast("Couldn’t remove capture: \(error.localizedDescription)") }
    }
    /// The preview if it's ready. If not this returns nil, starts loading it off the main thread, and the views
    /// update when it arrives, so scrolling a long history never waits for a PNG.
    func thumbnail(_ item: CaptureItem) -> NSImage? {
        if let cached = thumbnails.object(forKey: item.id as NSUUID) { return cached }
        guard loadingThumbnails[item.id] == nil else { return nil }
        let id = item.id, token = UUID(), file = url(item)
        loadingThumbnails[id] = token
        if item.isVideo && !item.filename.hasSuffix("gif") {
            Task {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                generator.maximumSize = CGSize(width: 560, height: 360)
                generator.appliesPreferredTrackTransform = true
                finishThumbnail(id, token: token, image: try? await generator.image(at: .zero).image)
            }
        } else {
            Self.thumbnailQueue.addOperation { [weak self] in
                let image = ImageRenderer.thumbnail(file, maxPixelSize: 560)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishThumbnail(id, token: token, image: image) } }
            }
        }
        return nil
    }
    /// Loads a picture's preview right now, for the Floating Preview, which appears with its image already in place.
    func loadThumbnail(_ item: CaptureItem) {
        guard !item.isVideo || item.filename.hasSuffix("gif"), thumbnails.object(forKey: item.id as NSUUID) == nil, let image = ImageRenderer.thumbnail(url(item), maxPixelSize: 560) else { return }
        storeThumbnail(item.id, image: image)
    }
    func storeThumbnail(_ id: UUID, image: CGImage) {
        thumbnails.setObject(NSImage(cgImage: image, size: .zero), forKey: id as NSUUID, cost: image.bytesPerRow*image.height)
    }
    private func finishThumbnail(_ id: UUID, token: UUID, image: CGImage?) {
        guard loadingThumbnails[id] == token else { return }
        loadingThumbnails[id] = nil
        guard let image else { return }
        storeThumbnail(id, image: image)
        // A screenful of previews lands in a burst; redraw once for all of them.
        guard !thumbnailChangeQueued else { return }
        thumbnailChangeQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now()+0.03) { [weak self] in MainActor.assumeIsolated { self?.thumbnailChangeQueued = false; self?.objectWillChange.send() } }
    }
    private func forgetThumbnail(_ id: UUID) { thumbnails.removeObject(forKey: id as NSUUID); loadingThumbnails[id] = nil }
    func toast(_ text: String) {
        let id = UUID(); toastID = id; message = text
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            if self?.toastID == id { self?.message = nil }
        }
    }
    func copy(_ image: CGImage) {
        do {
            let data = try ImageRenderer.data(image)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            toast("Copied image")
        } catch { toast(error.localizedDescription) }
    }
    /// Puts PNG bytes that are already encoded on the clipboard.
    func copy(png: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        toast("Copied image")
    }
    func copy(_ item: CaptureItem) {
        if item.isVideo { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url(item) as NSURL]); toast("Copied recording file") }
        else if let image = ImageRenderer.load(url(item)) { copy(image) }
    }
    func export(_ item: CaptureItem) {
        if item.isVideo {
            let panel = NSSavePanel(); panel.allowedContentTypes = item.filename.lowercased().hasSuffix(".gif") ? [.gif] : [.mpeg4Movie]; panel.nameFieldStringValue = "\(item.title).\(item.filename.lowercased().hasSuffix(".gif") ? "gif" : "mp4")"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let destination = panel.url {
                do { try Data(contentsOf: url(item)).write(to: destination, options: .atomic); toast("Recording saved") }
                catch { toast(error.localizedDescription) }
            }
        } else if let image = ImageRenderer.load(url(item)) { export(image, title: item.title) }
    }
    func export(_ image: CGImage, title: String = "Still capture") {
        let format = Preferences.shared.exportFormat
        let type: UTType = format == "jpg" ? .jpeg : format == "heic" ? .heic : format == "tiff" ? .tiff : .png
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(title).\(format)"
        if !exportFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: exportFolder) }
        else { try? FileManager.default.createDirectory(at: Self.defaultExportFolder, withIntermediateDirectories: true); panel.directoryURL = Self.defaultExportFolder }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let destination = panel.url {
            do { try ImageRenderer.data(image, format: format).write(to: destination, options: .atomic); toast("Saved to \(destination.lastPathComponent)") }
            catch { toast("Couldn’t save: \(error.localizedDescription)") }
        }
    }
    func captureName(width: Int, height: Int, isVideo: Bool = false) -> String {
        let today = items.filter { Calendar.current.isDateInToday($0.date) }.count
        return CaptureNaming.name(pattern: Preferences.shared.filenamePattern, isVideo: isVideo, width: width, height: height, number: today + 1)
    }
    /// Where saves go unless you choose a folder: Documents/Still, created when first needed.
    static var defaultExportFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Still", isDirectory: true) }
    func quickSave(_ item: CaptureItem) {
        let folder = exportFolder.isEmpty ? Self.defaultExportFolder : URL(fileURLWithPath: exportFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = item.isVideo ? URL(fileURLWithPath: item.filename).pathExtension : Preferences.shared.exportFormat
        let cleaned = item.title.components(separatedBy: CharacterSet(charactersIn: "/:\0\n\r")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Capture" : String(cleaned.prefix(180))
        var destination = folder.appendingPathComponent("\(name).\(format)")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) { destination = folder.appendingPathComponent("\(name) (\(index)).\(format)"); index += 1 }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if item.isVideo { try FileManager.default.copyItem(at: url(item), to: destination) }
            else if let image = ImageRenderer.load(url(item)) { try ImageRenderer.data(image, format: format).write(to: destination, options: .atomic) }
            toast("Saved \(destination.lastPathComponent)")
        } catch { toast("Couldn’t save: \(error.localizedDescription)") }
    }
    func updateText(_ item: CaptureItem, text: String) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].recognizedText = text; do { try persist() } catch { toast(error.localizedDescription) } }
    }
    func recordingMetadata(_ item: CaptureItem) -> RecordingMetadata {
        guard let saved = items.first(where: { $0.id == item.id }), let name = saved.metadataFilename, !name.contains("/"), let data = try? Data(contentsOf: root.appendingPathComponent(name)), let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else { return RecordingMetadata() }
        return metadata
    }
    func saveRecordingMetadata(_ item: CaptureItem, metadata: RecordingMetadata, camera: URL?) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var metadata = metadata
        if let camera {
            let name = "\(item.id).camera.mp4"
            try FileManager.default.copyItem(at: camera, to: root.appendingPathComponent(name)); metadata.cameraFilename = name
        }
        let name = "\(item.id).recording.json"
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent(name), options: .atomic)
        items[index].metadataFilename = name; try persist()
    }
    func attachVideoSource(_ item: CaptureItem, source: URL) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let name = "\(item.id).source.mp4"
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
        items[index].sourceVideoFilename = name; try persist()
    }
    func videoSource(_ item: CaptureItem) -> URL {
        if let saved = items.first(where: { $0.id == item.id }), let name = saved.sourceVideoFilename, !name.contains("/") { return root.appendingPathComponent(name) }
        return url(item)
    }
    func replaceVideo(_ item: CaptureItem, file: URL) throws {
        try Data(contentsOf: file).write(to: url(item), options: .atomic); forgetThumbnail(item.id); objectWillChange.send()
    }
    /// The most recent link an upload produced, for showing it again as a QR code.
    var lastLink: String? {
        get { UserDefaults.standard.string(forKey: "lastShareLink") }
        set { UserDefaults.standard.set(newValue, forKey: "lastShareLink") }
    }
    func setCloudURL(_ item: CaptureItem, url: URL) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].cloudURL = url.absoluteString; do { try persist() } catch { toast(error.localizedDescription) } }
    }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }
}
