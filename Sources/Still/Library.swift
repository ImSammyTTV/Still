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
    var thumbnails: [UUID: NSImage] = [:]
    private var loadingThumbnails = Set<UUID>()
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ImageRenderer.data(image).write(to: temp)
        return try add(file: temp, title: title)
    }
    func update(_ item: CaptureItem, image: CGImage, document: ProjectDocument? = nil) throws {
        try ImageRenderer.data(image).write(to: url(item), options: .atomic)
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx].width = image.width; items[idx].height = image.height }
        if let document, let idx = items.firstIndex(where: { $0.id == item.id }) {
            let name = "\(item.id.uuidString).stillshot"
            try document.write(root.appendingPathComponent(name)); items[idx].projectFilename = name
        }
        thumbnails[item.id] = nil
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
            items.removeAll { $0.id == item.id }; thumbnails[item.id] = nil
            try persist(); toast("Moved to Trash")
        } catch { toast("Couldn’t remove capture: \(error.localizedDescription)") }
    }
    func thumbnail(_ item: CaptureItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        let image: NSImage?
        if item.isVideo && !item.filename.hasSuffix("gif") {
            guard !loadingThumbnails.contains(item.id) else { return nil }
            loadingThumbnails.insert(item.id)
            Task {
                defer { loadingThumbnails.remove(item.id) }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url(item)))
                generator.maximumSize = CGSize(width: 560, height: 360)
                generator.appliesPreferredTrackTransform = true
                if let result = try? await generator.image(at: .zero) {
                    thumbnails[item.id] = NSImage(cgImage: result.image, size: .zero)
                    objectWillChange.send()
                }
            }
            return nil
        } else if let source = CGImageSourceCreateWithURL(url(item) as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 560] as CFDictionary) {
            image = NSImage(cgImage: cg, size: .zero)
        } else { image = nil }
        if let image { thumbnails[item.id] = image }
        return image
    }
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
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let destination = panel.url {
            do { try ImageRenderer.data(image, format: format).write(to: destination, options: .atomic); toast("Saved to \(destination.lastPathComponent)") }
            catch { toast("Couldn’t save: \(error.localizedDescription)") }
        }
    }
    func captureName(width: Int, height: Int) -> String {
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH.mm.ss"
        let now = Date()
        let name = Preferences.shared.filenamePattern.replacingOccurrences(of: "{date}", with: date.string(from: now)).replacingOccurrences(of: "{time}", with: time.string(from: now)).replacingOccurrences(of: "{width}", with: String(width)).replacingOccurrences(of: "{height}", with: String(height))
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\0\n")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Screenshot \(date.string(from: now)) \(time.string(from: now))" : String(cleaned.prefix(180))
    }
    func quickSave(_ item: CaptureItem) {
        let folder = exportFolder.isEmpty ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] : URL(fileURLWithPath: exportFolder)
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
        try Data(contentsOf: file).write(to: url(item), options: .atomic); thumbnails[item.id] = nil; loadingThumbnails.remove(item.id); objectWillChange.send()
    }
    func setCloudURL(_ item: CaptureItem, url: URL) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].cloudURL = url.absoluteString; do { try persist() } catch { toast(error.localizedDescription) } }
    }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }
}
