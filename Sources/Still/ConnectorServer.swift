import AppKit
import Network
import StillCore

/// The running app's end of Still for Claude (see StillConnector): while Settings → Claude → "Let Claude use Still"
/// is on, it listens on 127.0.0.1 for one JSON line per request, checks the secret token, runs the tool and answers.
@MainActor final class ConnectorServer {
    static let shared = ConnectorServer()
    private var listener: NWListener?
    private var token = ""
    private let queue = DispatchQueue(label: "local.sam.Still.connector")

    /// Starts or stops listening to match the setting.
    func apply() {
        if !Preferences.shared.claudeConnector { stop(); return }
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let made = try? NWListener(using: parameters) else { return }
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secret = token
        made.stateUpdateHandler = { [weak made] state in
            guard case .ready = state, let port = made?.port?.rawValue else { return }
            Task { @MainActor in ConnectorServer.writeLink(port: port, token: secret) }
        }
        made.newConnectionHandler = { [weak self] connection in self?.receive(connection, token: secret) }
        made.start(queue: queue); listener = made
    }
    func stop() { listener?.cancel(); listener = nil; try? FileManager.default.removeItem(at: StillConnector.linkFile) }

    private static func writeLink(port: UInt16, token: String) {
        let file = StillConnector.linkFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier]) else { return }
        // Only your account can read it.
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    nonisolated private func receive(_ connection: NWConnection, token: String) {
        connection.start(queue: queue)
        var buffer = Data()
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { buffer.append(data) }
                if buffer.count > 1_048_576 || error != nil { connection.cancel(); return }
                guard let end = buffer.firstIndex(of: 10) else { if done { connection.cancel() } else { next() }; return }
                let request = (try? JSONSerialization.jsonObject(with: buffer[..<end])) as? [String: Any] ?? [:]
                Task { @MainActor in
                    let reply: [String: Any] = StillConnector.sameSecret(request["token"] as? String ?? "", token)
                        ? await ConnectorServer.call(request["name"] as? String ?? "", request["arguments"] as? [String: Any] ?? [:])
                        : StillConnector.textResult("Still refused this connection.", error: true)
                    var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(); out.append(10)
                    connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        next()
    }

    // ---- The tools ------------------------------------------------------------------------------------

    private static var library: Library { AppController.shared.library }
    /// A picture for Claude: at most 1568 pixels on its longest side, as JPEG.
    private static func picture(_ image: CGImage) -> [String: Any]? {
        guard let data = try? ImageRenderer.data(Library.scaledDown(image, maxSide: 1568), jpeg: true) else { return nil }
        return ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]
    }
    private static func summary(_ item: CaptureItem, full: Bool) -> [String: Any] {
        func cut(_ t: String, _ n: Int) -> String { t.count > n ? String(t.prefix(n)) + "…" : t }
        var v: [String: Any] = ["id": item.id.uuidString, "title": item.title, "kind": item.isVideo ? "recording" : "screenshot",
                                "created": ISO8601DateFormatter().string(from: item.date), "width": item.width, "height": item.height, "starred": item.isStarred]
        if let d = item.imageDescription { v["description"] = d }
        if let t = item.recognizedText, !t.isEmpty { v["text"] = cut(t, full ? 6000 : 200) }
        if full { v["file"] = library.url(item).path; if let link = item.cloudURL { v["link"] = link } }
        return v
    }
    private static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    static func call(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        let item = (args["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { id in library.items.first { $0.id == id } }
        switch name {
        case "still_capture_screen":
            let screens = NSScreen.screens
            guard !screens.isEmpty else { return StillConnector.textResult("No display to capture.", error: true) }
            let n = min(max(1, (args["display"] as? NSNumber)?.intValue ?? 1), screens.count)
            do {
                let image = try await ScreenCaptureAPI.image(screen: screens[n-1])
                let title = "Screenshot \(Date().formatted(date: .abbreviated, time: .standard))".replacingOccurrences(of: ":", with: ".")
                let saved = try library.add(image: image, title: title)
                var content: [[String: Any]] = [["type": "text", "text": "Screenshot saved in Still as “\(saved.title)” (id \(saved.id.uuidString)), \(image.width) × \(image.height), display \(n) of \(screens.count)."]]
                if let p = picture(image) { content.append(p) }
                return ["content": content, "isError": false]
            } catch { return StillConnector.textResult("Still couldn’t capture the screen: \(error.localizedDescription). Check Still has Screen Recording permission.", error: true) }
        case "still_list_captures":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces), kind = args["kind"] as? String ?? "all"
            let limit = min(50, max(1, (args["limit"] as? NSNumber)?.intValue ?? 20))
            let found = library.items.filter { i in
                (kind == "all" || (kind == "screenshot" && !i.isVideo) || (kind == "recording" && i.isVideo) || (kind == "starred" && i.isStarred))
                    && (query.isEmpty || i.title.localizedCaseInsensitiveContains(query) || (i.recognizedText?.localizedCaseInsensitiveContains(query) ?? false) || (i.imageDescription?.localizedCaseInsensitiveContains(query) ?? false) || (i.tags?.contains { $0.localizedCaseInsensitiveContains(query) } ?? false))
            }.prefix(limit).map { summary($0, full: false) }
            return StillConnector.textResult(json(Array(found)))
        case "still_get_capture":
            guard let item else { return StillConnector.textResult("No capture with that id. Use still_list_captures to find one.", error: true) }
            var content: [[String: Any]] = [["type": "text", "text": json(summary(item, full: true))]]
            if !item.isVideo, let image = ImageRenderer.load(library.url(item)), let p = picture(image) { content.append(p) }
            return ["content": content, "isError": false]
        case "still_describe_capture":
            guard let item else { return StillConnector.textResult("No capture with that id.", error: true) }
            do { return StillConnector.textResult(try await library.describedText(item)) } catch { return StillConnector.textResult(error.localizedDescription, error: true) }
        case "still_share_capture":
            guard let item else { return StillConnector.textResult("No capture with that id.", error: true) }
            do { return StillConnector.textResult(try await share(item)) } catch { return StillConnector.textResult(error.localizedDescription, error: true) }
        case "still_open_capture":
            guard let item else { return StillConnector.textResult("No capture with that id.", error: true) }
            AppController.shared.openItem(item)
            return StillConnector.textResult("Opened “\(item.title)” in Still.")
        default: return StillConnector.textResult("Still has no tool called \(name).", error: true)
        }
    }
    /// Uploads with Still's cloud settings, as the Upload button does without its options, and returns the link.
    private static func share(_ item: CaptureItem) async throws -> String {
        let prefs = Preferences.shared, file = library.url(item)
        switch prefs.cloudProvider {
        case "drive":
            guard GoogleDrive.refreshToken != nil else { throw CloudError.response("Connect Google Drive in Still’s Settings → Cloud first.") }
            let result = try await GoogleDrive.upload(file, title: item.title, public: prefs.driveAccess == "link", folder: prefs.driveFolder, progress: { _ in })
            prefs.driveFolder = result.folder; library.setCloudURL(item, url: result.link); library.lastLink = result.link.absoluteString
            return result.link.absoluteString
        case "icloud": throw CloudError.response("Still is set to save to iCloud Drive, which makes no share link. Choose Still Cloud or Google Drive in Settings → Cloud.")
        default:
            guard !prefs.cloudEndpoint.isEmpty else { throw CloudError.response("Connect a Cloud server in Still’s Settings → Cloud first.") }
            var options = CloudOptions(title: item.title); options.expiryDays = prefs.cloudExpiry
            let link = try await CloudClient(endpoint: prefs.cloudEndpoint).upload(file, options: options, progress: { _ in })
            library.setCloudURL(item, url: link); library.lastLink = link.absoluteString
            return link.absoluteString
        }
    }
}
