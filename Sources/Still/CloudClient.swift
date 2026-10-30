import Foundation
import Security
import UniformTypeIdentifiers
import AppKit
import StillCore

struct CloudOptions {
    var title: String
    var tags: [String] = []
    var expiryDays = 7
    var password = ""
    var visibility = "link"
    var maxViews = 0
    var ocr = ""
    var transcript = ""
    var captions = ""
}
struct CloudUserResponse: Decodable { struct User: Decodable { let name: String; let role: String }; let user: User }
struct CloudTicket: Decodable { let id: String; let url: URL }
enum CloudError: LocalizedError {
    case connection, token, response(String)
    var errorDescription: String? { switch self { case .connection: return "Enter an HTTPS server URL, or use http://127.0.0.1 for your local server."; case .token: return "Save a personal access token in Cloud settings."; case .response(let message): return message } }
}
enum CloudKeychain {
    private static let service = "local.sam.Still.cloud"
    static func token(for endpoint: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(endpoint: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint] as CFDictionary)
    }
    static func save(_ token: String, endpoint: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint]
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound { var entry = query; entry[kSecValueData] = data; status = SecItemAdd(entry as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CloudError.response("The access token could not be saved in Keychain (\(status)).") }
    }
}
final class CloudProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let callback: @Sendable (Double) -> Void
    init(_ callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { if task.originalRequest?.httpMethod == "PUT", totalBytesExpectedToSend > 0 { callback(Double(totalBytesSent)/Double(totalBytesExpectedToSend)) } }
}
struct CloudClient {
    let endpoint: URL
    let token: String
    init(endpoint: String, token: String? = nil) throws {
        let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: text), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")) else { throw CloudError.connection }
        self.endpoint = url
        guard let secret = token ?? CloudKeychain.token(for: text), !secret.isEmpty else { throw CloudError.token }
        self.token = secret
    }
    func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.timeoutInterval = 120
        return request
    }
    func checked(_ data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CloudError.response(error ?? "The cloud server did not accept the request.")
        }
    }
    func test() async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request("api/me")); try checked(data, response: response)
        return try JSONDecoder().decode(CloudUserResponse.self, from: data).user.name
    }
    func upload(_ file: URL, options: CloudOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "image/png"
        let payload: [String: Any] = ["title": options.title, "mime": mime, "size": size, "tags": options.tags, "expiryDays": options.expiryDays, "password": options.password, "visibility": options.visibility, "maxViews": options.maxViews, "ocr": options.ocr, "transcript": options.transcript, "captions": options.captions]
        var create = request("api/uploads", method: "POST"); create.setValue("application/json", forHTTPHeaderField: "Content-Type"); create.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForResource = 7200; configuration.httpShouldSetCookies = false
        let delegate = CloudProgress(progress), session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: create); try checked(data, response: response)
        let ticket = try JSONDecoder().decode(CloudTicket.self, from: data)
        guard ticket.id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw CloudError.response("The server returned an invalid upload identifier.") }
        var send = request("api/uploads/\(ticket.id)/content", method: "PUT"); send.setValue(mime, forHTTPHeaderField: "Content-Type")
        do {
            let (result, response) = try await session.upload(for: send, fromFile: file); try checked(result, response: response); progress(1); return ticket.url
        } catch {
            let cleanup = request("api/uploads/\(ticket.id)", method: "DELETE")
            Task.detached { _ = try? await URLSession.shared.data(for: cleanup) }
            throw error
        }
    }
}

@MainActor final class LocalCloudServer: ObservableObject {
    static let shared = LocalCloudServer()
    @Published var running = false
    @Published var starting = false
    @Published var message: String?
    private var process: Process?
    func start() {
        guard !running, !starting else { return }; starting = true
        Task {
            do {
                guard let script = Bundle.main.resourceURL?.appendingPathComponent("Cloud/server.py"), FileManager.default.fileExists(atPath: script.path) else { throw CloudError.response("The bundled cloud server is missing. Rebuild Still with scripts/build.sh.") }
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/Cloud")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                let ready = folder.appendingPathComponent("ready.json"); try? FileManager.default.removeItem(at: ready)
                let log = folder.appendingPathComponent("server.log"); if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); defer { try? handle.close() }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path, "--data", folder.path, "--port", "7843", "--ready-file", ready.path]
                process.standardOutput = handle; process.standardError = handle; self.process = process
                try process.run()
                var readyForConnection = false
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard process.isRunning else { throw CloudError.response("The local server couldn’t start. Port 7843 may already be in use. See the server log in Still’s storage folder.") }
                    if let data = try? Data(contentsOf: ready), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (info["pid"] as? NSNumber)?.int32Value == process.processIdentifier { readyForConnection = true; break }
                }
                guard readyForConnection else { process.terminate(); throw CloudError.response("The local server did not become ready. Check that Python 3 is installed.") }
                let endpoint = "http://127.0.0.1:7843", secret = try String(contentsOf: folder.appendingPathComponent("admin-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                try CloudKeychain.save(secret, endpoint: endpoint); Preferences.shared.cloudEndpoint = endpoint
                let name = try await CloudClient(endpoint: endpoint, token: secret).test()
                running = true; message = "Connected as \(name). Local links work on this Mac while Still is running."
            } catch { message = error.localizedDescription; process?.terminate(); process = nil }
            starting = false
        }
    }
    func stop() { process?.terminate(); process = nil; running = false; message = "Local server stopped." }
}
