import AppKit
import SwiftUI
import StillCore
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Whether the newest write of history's index failed; only read and set on Library's index queue.
private final class IndexWriteState: @unchecked Sendable { var failed = false }

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
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.defaultsChanged() } }
        // Captures that went past Keep history while Still was closed go now, not only at the next capture.
        pruneHistory()
    }
    /// Settings change in bursts (a slider, a resized window, the magnifier's zoom), and every change used to redraw
    /// every view watching this. Gather a burst into one update.
    private var defaultsPending = false
    private func defaultsChanged() {
        guard !defaultsPending else { return }
        defaultsPending = true
        // A shorter Keep history in Settings applies straight away, too.
        DispatchQueue.main.asyncAfter(deadline: .now()+0.15) { [weak self] in MainActor.assumeIsolated { self?.defaultsPending = false; self?.objectWillChange.send(); self?.pruneHistory() } }
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
    /// History's index is written on its own queue, in order, so a capture, a rename or a star never waits for the
    /// disk. The newest write always lands last.
    private static let indexQueue = DispatchQueue(label: "Still history index", qos: .utility)
    /// Copying, saving and trashing capture files, one at a time and off the main thread.
    private static let fileQueue = DispatchQueue(label: "Still capture files", qos: .userInitiated)
    /// Whether the newest write of the index failed, so quitting tries it once more. Only read and set on indexQueue.
    private static let indexWrite = IndexWriteState()
    /// Throws only when the history can't be encoded. Writing it happens later; if that fails, the next change or
    /// quitting writes the whole history again, so a capture already on disk isn't left out of it.
    func persist() throws {
        let data = try JSONEncoder().encode(items), file = root.appendingPathComponent("index.json"), state = Self.indexWrite
        Self.indexQueue.async { [weak self] in
            do { try data.write(to: file, options: .atomic); state.failed = false }
            catch {
                state.failed = true
                let text = error.localizedDescription
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.toast("Couldn’t save capture history: \(text)") } }
            }
        }
    }
    /// Waits for saves, Save As copies, edited pictures and history's index to reach the disk, for quitting, so a file
    /// still being written isn't lost. None of that work waits on the main thread, so this can't stall forever.
    func finishWriting() {
        Self.fileQueue.sync {}; Self.updateQueue.sync {}
        let state = Self.indexWrite
        guard Self.indexQueue.sync(execute: { state.failed }), let data = try? JSONEncoder().encode(items) else { return }
        // The last write of the index failed: one more try with the history as it is now.
        let file = root.appendingPathComponent("index.json")
        Self.indexQueue.sync { if (try? data.write(to: file, options: .atomic)) != nil { state.failed = false } }
    }
    /// Adds a picture or recording file to history. Copying, decoding and encoding happen off the main thread, so
    /// opening a big image or finishing a long recording never stalls Still.
    @discardableResult
    func add(file: URL, title: String, video: Bool = false) async throws -> CaptureItem {
        pruneHistory()
        let name = "\(UUID().uuidString).\(video ? (file.pathExtension.lowercased() == "gif" ? "gif" : "mp4") : "png")"
        let destination = root.appendingPathComponent(name)
        let size = try await Task.detached(priority: .userInitiated) { () throws -> (width: Int, height: Int) in
            try Library.store(file, at: destination, video: video)
        }.value
        let item = CaptureItem(filename: name, title: title, isVideo: video, width: size.width, height: size.height)
        items.insert(item, at: 0)
        do { try persist() } catch { items.removeAll { $0.id == item.id }; try? FileManager.default.removeItem(at: destination); throw error }
        return item
    }
    /// Copies a file into history's folder and returns the picture's size (zero for a recording). A PNG is copied as it
    /// is: decoding it and encoding it again only cost time. Other formats are stored as PNG.
    nonisolated private static func store(_ file: URL, at destination: URL, video: Bool) throws -> (width: Int, height: Int) {
        if video { try FileManager.default.copyItem(at: file, to: destination); return (0, 0) }
        let data = try Data(contentsOf: file)
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { try data.write(to: destination, options: .atomic) }
        else {
            // Read from the file, which turns a sideways phone photo the right way up.
            guard let image = ImageRenderer.load(file) else { throw RenderError.encoding }
            try ImageRenderer.data(image).write(to: destination, options: .atomic)
        }
        // Reading the size only looks at the file's header; the pixels aren't decoded.
        guard let stored = ImageRenderer.load(destination) else { try? FileManager.default.removeItem(at: destination); throw RenderError.encoding }
        return (stored.width, stored.height)
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
    /// Edited pictures and their projects are written here, one at a time, so when two saves of the same capture
    /// overlap (a background save, then saving as the window closes) the newer one always lands last.
    private static let updateQueue = DispatchQueue(label: "Still capture updates", qos: .userInitiated)
    /// The newest save of each capture, so an older one finishing late doesn't put back its picture's size.
    private var updateTokens: [UUID: UUID] = [:]
    func update(_ item: CaptureItem, image: CGImage, document: ProjectDocument? = nil) throws {
        updateTokens[item.id] = UUID()
        let png = try ImageRenderer.data(image), file = url(item)
        try Self.updateQueue.sync { try png.write(to: file, options: .atomic) }
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx].width = image.width; items[idx].height = image.height }
        if let document, let idx = items.firstIndex(where: { $0.id == item.id }) {
            let name = "\(item.id.uuidString).stillshot", projectURL = root.appendingPathComponent(name)
            try Self.updateQueue.sync { try document.write(projectURL) }; items[idx].projectFilename = name
        }
        forgetThumbnail(item.id)
        try persist()
        objectWillChange.send()
    }
    /// Like update(_:image:document:), with the picture already encoded; the files are written off the main thread.
    func update(_ item: CaptureItem, png: Data, width: Int, height: Int, document: ProjectDocument?) async throws {
        let file = url(item), projectName = "\(item.id.uuidString).stillshot", projectURL = root.appendingPathComponent(projectName)
        let token = UUID(); updateTokens[item.id] = token
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            Self.updateQueue.async {
                let result: Result<Void, Error> = Result {
                    try png.write(to: file, options: .atomic)
                    if let document { try document.write(projectURL) }
                }
                done.resume(with: result)
            }
        }
        // A newer save of this capture came in meanwhile and has already recorded its own picture.
        guard updateTokens[item.id] == token else { return }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].width = width; items[idx].height = height
            if document != nil { items[idx].projectFilename = projectName }
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
        guard let file = projectURL(item) else { return nil }
        return try? ProjectDocument.read(file)
    }
    /// Where a capture's editable project is kept, if it has one.
    func projectURL(_ item: CaptureItem) -> URL? {
        guard let saved = items.first(where: { $0.id == item.id }), let name = saved.projectFilename, !name.contains("/") else { return nil }
        return root.appendingPathComponent(name)
    }
    private var pruning = false
    /// Moves captures older than Settings keeps to the Trash. It runs at launch, when Keep history changes and before
    /// each new capture is stored; the files go to the Trash off the main thread and the index is saved once for all
    /// of them, not once per capture. Starred captures are always kept.
    func pruneHistory() {
        let days = Preferences.shared.retentionDays
        guard !pruning, days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let expired = items.filter { $0.date < cutoff && !$0.isStarred }
        guard !expired.isEmpty else { return }
        pruning = true
        let folder = root
        let jobs = expired.map { item in
            (id: item.id, file: url(item), metadata: recordingMetadataURL(item),
             sidecars: [item.projectFilename, item.metadataFilename, item.sourceVideoFilename, "\(item.id).videoedit.json"].compactMap { $0 })
        }
        Self.fileQueue.async { [weak self] in
            var trashed: [UUID] = []
            for job in jobs {
                // Only a capture whose own file went to the Trash (or was already gone) leaves the history, as when
                // deleting one by hand.
                if FileManager.default.fileExists(atPath: job.file.path) {
                    guard (try? FileManager.default.trashItem(at: job.file, resultingItemURL: nil)) != nil else { continue }
                }
                trashed.append(job.id)
                let camera = job.metadata == nil ? nil : Library.readRecordingMetadata(job.metadata).cameraFilename
                for name in Set(job.sidecars + [camera].compactMap { $0 }) where !name.contains("/") && name != "." && name != ".." {
                    let file = folder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                }
            }
            let gone = Set(trashed)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                self.pruning = false
                guard !gone.isEmpty else { return }
                self.items.removeAll { gone.contains($0.id) }
                for id in gone { self.forgetThumbnail(id) }
                do { try self.persist() } catch { self.toast("Couldn’t save capture history: \(error.localizedDescription)") }
            } }
        }
    }
    func delete(_ item: CaptureItem) {
        do {
            // A capture whose file was already removed by hand still leaves the history, with its other files.
            let file = url(item)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
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
    /// Encodes the picture off the main thread, then puts it on the clipboard.
    func copy(_ image: CGImage) {
        Task {
            do {
                let png = try await Task.detached(priority: .userInitiated) { try ImageRenderer.data(image) }.value
                copy(png: png)
            } catch { toast(error.localizedDescription) }
        }
    }
    /// Puts PNG bytes that are already encoded on the clipboard.
    func copy(png: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        toast("Copied image")
    }
    func copy(_ item: CaptureItem) {
        if item.isVideo { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url(item) as NSURL]); toast("Copied recording file") }
        else if let png = pngData(item) { copy(png: png) }
    }
    /// A screenshot's PNG as it is on disk. Captures are stored as PNG already, so the file's own bytes go to the
    /// clipboard; decoding and encoding it again took a noticeable moment on a big screenshot.
    func pngData(_ item: CaptureItem) -> Data? {
        let file = url(item)
        if file.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: file), data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let image = ImageRenderer.load(file) else { return nil }
        return try? ImageRenderer.data(image)
    }
    /// Fingerprints already worked out, with the file's modification date, so a second Find Similar is instant.
    private var fingerprints: [UUID: (Date, UInt64)] = [:]
    /// Find Similar: the other screenshots that look like this one, closest first.
    func similar(to item: CaptureItem) async -> [UUID] {
        let files = items.filter { !$0.isVideo }.map { ($0.id, url($0)) }, known = fingerprints
        let computed: [(UUID, Date, UInt64)] = await Task.detached(priority: .userInitiated) {
            files.compactMap { id, file in
                let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let saved = known[id], saved.0 == stamp { return (id, stamp, saved.1) }
                return ImageFingerprint.fingerprint(of: file).map { (id, stamp, $0) }
            }
        }.value
        for (id, stamp, print) in computed { fingerprints[id] = (stamp, print) }
        guard let target = computed.first(where: { $0.0 == item.id })?.2 else { return [] }
        return ImageFingerprint.rank(target, computed.filter { $0.0 != item.id }.map { ($0.0, $0.2) }, limit: 60).map(\.0)
    }
    /// Find Similar in a Folder: the pictures in `folder` (and the folders inside it) that look like this capture,
    /// closest first. At most 5,000 pictures are checked; hidden folders and very large files are passed over.
    struct FolderMatch: Identifiable { let id = UUID(); let url: URL; let distance: Int }
    func similar(to item: CaptureItem, inFolder folder: URL) async -> (matches: [FolderMatch], scanned: Int, capped: Bool) {
        let file = url(item)
        return await Task.detached(priority: .userInitiated) {
            guard let target = ImageFingerprint.fingerprint(of: file) else { return ([], 0, false) }
            let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]
            var files: [URL] = []
            let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let next = walk?.nextObject() as? URL, files.count < 5000 {
                guard kinds.contains(next.pathExtension.lowercased()), next.standardizedFileURL != file.standardizedFileURL else { continue }
                let size = (try? next.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size < 40_000_000 { files.append(next) }
            }
            let prints = files.compactMap { f in ImageFingerprint.fingerprint(of: f).map { (f, $0) } }
            let ranked = ImageFingerprint.rank(target, prints, limit: 60).map { FolderMatch(url: $0.0, distance: $0.1) }
            return (ranked, files.count, files.count >= 5000)
        }.value
    }
    /// Describe Image: Gemini writes a short description (with the user's own key), kept with the capture for search
    /// and copied to the clipboard.
    @MainActor func describe(_ item: CaptureItem) {
        guard GeminiKey.value != nil else { toast("Add a key in Settings → AI first"); AppController.shared.showMain(); page = "AI"; return }
        toast("Describing…")
        Task { @MainActor in
            do {
                let text = try await describedText(item)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                toast("\(text.components(separatedBy: "\n").first ?? text) (copied)")
            } catch { toast(error.localizedDescription) }
        }
    }
    /// Describes a screenshot with the service Settings picked and keeps the description with it.
    @MainActor func describedText(_ item: CaptureItem) async throws -> String {
        guard let key = GeminiKey.value else { throw ImageDescriber.Failure(message: "Add a key in Still’s Settings → AI first.") }
        guard !item.isVideo else { throw ImageDescriber.Failure(message: "Only screenshots can be described.") }
        // A big screenshot is scaled down first: smaller to send, and plenty for a description. Reading, scaling and
        // encoding it happen off the main thread.
        let file = url(item)
        let prepared = await Task.detached(priority: .userInitiated) { () -> (loaded: Bool, data: Data?) in
            guard let image = ImageRenderer.load(file) else { return (false, nil) }
            return (true, try? ImageRenderer.data(Library.scaledDown(image, maxSide: 1600)))
        }.value
        guard prepared.loaded else { throw ImageDescriber.Failure(message: "Only screenshots can be described.") }
        guard let data = prepared.data else { throw ImageDescriber.Failure(message: "Couldn’t read this screenshot.") }
        let text = Preferences.shared.describeProvider == "claude"
            ? try await ImageDescriber.describeWithClaude(key: key, mime: "image/png", data: data)
            : try await ImageDescriber.describe(key: key, mime: "image/png", data: data)
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].imageDescription = text; try? persist() }
        return text
    }
    nonisolated static func scaledDown(_ image: CGImage, maxSide: Int) -> CGImage {
        let side = max(image.width, image.height)
        guard side > maxSide else { return image }
        let k = Double(maxSide)/Double(side), w = max(1, Int(Double(image.width)*k)), h = max(1, Int(Double(image.height)*k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high; ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
    /// Send to Claude: copies the screenshot and opens Claude (the desktop app when it's installed, otherwise
    /// claude.ai), ready to paste into a chat. Nothing is sent until it's pasted there.
    @MainActor func sendToClaude(_ item: CaptureItem) {
        guard let data = pngData(item) else { toast("Couldn’t read this screenshot"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            toast("Image copied. Paste it into Claude (⌘V).")
        } else {
            if let page = URL(string: "https://claude.ai/new") { NSWorkspace.shared.open(page) }
            toast("Image copied. Paste it into the new Claude chat (⌘V).")
        }
    }
    /// Search the Web for This Image: copies the picture and opens an image search page, where pasting it starts the
    /// search. Nothing is uploaded until it's pasted there.
    func searchWeb(_ item: CaptureItem) {
        guard let data = pngData(item) else { toast("Couldn’t read this screenshot"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
        if let page = URL(string: "https://images.google.com/") { NSWorkspace.shared.open(page) }
        toast("Image copied. Paste it on the search page (⌘V) to search.")
    }
    func export(_ item: CaptureItem) {
        if item.isVideo {
            let panel = NSSavePanel(); panel.allowedContentTypes = item.filename.lowercased().hasSuffix(".gif") ? [.gif] : [.mpeg4Movie]; panel.nameFieldStringValue = "\(item.title).\(item.filename.lowercased().hasSuffix(".gif") ? "gif" : "mp4")"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let destination = panel.url {
                // A long recording is hundreds of megabytes: it's copied off the main thread.
                let source = url(item)
                Self.fileQueue.async { [weak self] in
                    let result: Result<Void, Error> = Result { try Data(contentsOf: source).write(to: destination, options: .atomic) }
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        switch result {
                        case .success: self?.toast("Recording saved")
                        case .failure(let error): self?.toast(error.localizedDescription)
                        }
                    } }
                }
            }
        } else {
            let file = url(item)
            export(title: item.title) {
                guard let image = ImageRenderer.load(file) else { throw RenderError.encoding }
                return image
            }
        }
    }
    func export(_ image: CGImage, title: String = "Still capture") { export(title: title) { image } }
    /// Save As for a picture: the Save panel, set up with the format and folder from Settings, then `make` draws the
    /// picture and it's encoded and written off the main thread, so a big one never stalls Still after the panel closes.
    func export(title: String, image make: @escaping @Sendable () throws -> CGImage) {
        let format = Preferences.shared.exportFormat
        let type: UTType = format == "jpg" ? .jpeg : format == "heic" ? .heic : format == "tiff" ? .tiff : .png
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(title).\(format)"
        if !exportFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: exportFolder) }
        else { try? FileManager.default.createDirectory(at: Self.defaultExportFolder, withIntermediateDirectories: true); panel.directoryURL = Self.defaultExportFolder }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Self.fileQueue.async { [weak self] in
            let result: Result<Void, Error> = Result { try ImageRenderer.data(make(), format: format).write(to: destination, options: .atomic) }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                switch result {
                case .success: self?.toast("Saved to \(destination.lastPathComponent)")
                case .failure(let error): self?.toast("Couldn’t save: \(error.localizedDescription)")
                }
            } }
        }
    }
    func captureName(width: Int, height: Int, isVideo: Bool = false) -> String {
        let today = items.filter { Calendar.current.isDateInToday($0.date) }.count
        return CaptureNaming.name(pattern: Preferences.shared.filenamePattern, isVideo: isVideo, width: width, height: height, number: today + 1)
    }
    /// Where saves go unless you choose a folder: Documents/Still, created when first needed.
    static var defaultExportFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Still", isDirectory: true) }
    /// Save (and Save after capture): runs off the main thread, one save at a time so two never pick the same name.
    /// A PNG save copies the stored file, which is a PNG already; other formats are encoded there too.
    func quickSave(_ item: CaptureItem) {
        let folder = exportFolder.isEmpty ? Self.defaultExportFolder : URL(fileURLWithPath: exportFolder)
        let format = item.isVideo ? URL(fileURLWithPath: item.filename).pathExtension : Preferences.shared.exportFormat
        let cleaned = item.title.components(separatedBy: CharacterSet(charactersIn: "/:\0\n\r")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Capture" : String(cleaned.prefix(180))
        let source = url(item), copyAsIs = item.isVideo || (format.lowercased() == "png" && source.pathExtension.lowercased() == "png")
        Self.fileQueue.async { [weak self] in
            let result: Result<String, Error> = Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var destination = folder.appendingPathComponent("\(name).\(format)")
                var index = 2
                while FileManager.default.fileExists(atPath: destination.path) { destination = folder.appendingPathComponent("\(name) (\(index)).\(format)"); index += 1 }
                if copyAsIs { try FileManager.default.copyItem(at: source, to: destination) }
                else {
                    guard let image = ImageRenderer.load(source) else { throw RenderError.encoding }
                    try ImageRenderer.data(image, format: format).write(to: destination, options: .atomic)
                }
                return destination.lastPathComponent
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                switch result {
                case .success(let saved): self?.toast("Saved \(saved)")
                case .failure(let error): self?.toast("Couldn’t save: \(error.localizedDescription)")
                }
            } }
        }
    }
    func updateText(_ item: CaptureItem, text: String) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].recognizedText = text; do { try persist() } catch { toast(error.localizedDescription) } }
    }
    func recordingMetadata(_ item: CaptureItem) -> RecordingMetadata { Self.readRecordingMetadata(recordingMetadataURL(item)) }
    /// Where a recording's details are kept, if it has any.
    func recordingMetadataURL(_ item: CaptureItem) -> URL? {
        guard let saved = items.first(where: { $0.id == item.id }), let name = saved.metadataFilename, !name.contains("/") else { return nil }
        return root.appendingPathComponent(name)
    }
    /// Reads a recording's details. A long recording's pointer track is megabytes of JSON, so the video editor calls
    /// this off the main thread.
    nonisolated static func readRecordingMetadata(_ url: URL?) -> RecordingMetadata {
        guard let url, let data = try? Data(contentsOf: url), let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else { return RecordingMetadata() }
        return metadata
    }
    /// Saves a recording's details (a new transcript, say), encoding and writing them off the main thread.
    func saveRecordingMetadata(_ item: CaptureItem, metadata: RecordingMetadata) async throws {
        guard items.contains(where: { $0.id == item.id }) else { return }
        let name = "\(item.id).recording.json", file = root.appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) { try JSONEncoder().encode(metadata).write(to: file, options: .atomic) }.value
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].metadataFilename = name; try persist() }
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
    func setStarred(_ item: CaptureItem, _ starred: Bool) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].starred = starred ? true : nil; do { try persist() } catch { toast(error.localizedDescription) } }
    }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }
}
