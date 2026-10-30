import AppKit
import Network
import StillCore
import UniformTypeIdentifiers

/// Google Drive sharing. Still signs in through the browser (OAuth for desktop apps, with PKCE) and asks only for
/// drive.file, so it can see the files it creates and nothing else in the user's Drive.
enum GoogleDrive {
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let keychainAccount = "google-drive"
    private static func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }
    private static var clientID: String { info("StillGoogleClientID") }
    // Google's desktop flow requires this value but doesn't treat it as a secret.
    private static var clientSecret: String { info("StillGoogleClientSecret") }
    static var available: Bool { !clientID.isEmpty }
    static var refreshToken: String? { CloudKeychain.token(for: keychainAccount) }

    private static func problem(_ text: String) -> CloudError { .response(text) }
    private static func form(_ pairs: [(String, String)]) -> Data {
        var components = URLComponents(); components.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(query.utf8)
    }
    private static func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    private static func checked(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        let body = json(data), status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = body["error"] as? [String: Any]
            if let reason = (error?["errors"] as? [[String: Any]])?.first?["reason"] as? String, reason == "storageQuotaExceeded" { throw problem("Your Google Drive is full.") }
            throw problem(error?["message"] as? String ?? "Google Drive didn’t accept the request.")
        }
        return body
    }
    private static func token(_ pairs: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = form(pairs)
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = json(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if body["error"] as? String == "invalid_grant" { throw problem("Google Drive needs reconnecting. Open Settings → Cloud and connect again.") }
            throw problem(body["error_description"] as? String ?? "Google didn’t accept the sign-in.")
        }
        return body
    }
    private static func authorized(_ url: String, access: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    /// Runs the browser sign-in, keeps the lasting token in Keychain and returns the account's email.
    static func connect() async throws -> String {
        guard available else { throw problem("This build of Still isn’t set up for Google Drive.") }
        let state = UUID().uuidString, verifier = UUID().uuidString + UUID().uuidString
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(port)"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [("client_id", clientID), ("redirect_uri", redirect), ("response_type", "code"), ("scope", scope), ("state", state), ("code_challenge", GoogleAuth.challenge(verifier)), ("code_challenge_method", "S256"), ("access_type", "offline"), ("prompt", "consent")].map { URLQueryItem(name: $0.0, value: $0.1) }
        await MainActor.run { _ = NSWorkspace.shared.open(url.url!) }
        let code = try await listener.waitForCode(state: state)
        let tokens = try await token([("client_id", clientID), ("client_secret", clientSecret), ("code", code), ("code_verifier", verifier), ("redirect_uri", redirect), ("grant_type", "authorization_code")])
        guard let refresh = tokens["refresh_token"] as? String, let access = tokens["access_token"] as? String else { throw problem("Google didn’t return a lasting sign-in. Try connecting again.") }
        try CloudKeychain.save(refresh, endpoint: keychainAccount)
        let (data, response) = try await URLSession.shared.data(for: authorized("https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)", access: access))
        return (try checked(data, response)["user"] as? [String: Any])?["emailAddress"] as? String ?? "your account"
    }

    /// Forgets the sign-in here and at Google. Failing to reach Google doesn't stop the local disconnect.
    static func disconnect() async {
        guard let refresh = refreshToken else { return }
        CloudKeychain.remove(endpoint: keychainAccount)
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = form([("token", refresh)])
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func makeFolder(access: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: authorized("https://www.googleapis.com/drive/v3/files?fields=id", access: access, method: "POST", body: ["name": "Still", "mimeType": "application/vnd.google-apps.folder"]))
        guard let id = try checked(data, response)["id"] as? String else { throw problem("Google Drive didn’t create the Still folder.") }
        return id
    }

    /// Puts the file in the Still folder in the user's Drive and returns its link. `folder` is the remembered
    /// folder id; a new one is made if it's empty or was deleted.
    static func upload(_ file: URL, title: String, public isPublic: Bool, folder: String, progress: @escaping @Sendable (Double) -> Void) async throws -> (link: URL, folder: String) {
        guard let refresh = refreshToken else { throw problem("Connect Google Drive in Settings → Cloud first.") }
        guard let access = try await token([("client_id", clientID), ("client_secret", clientSecret), ("refresh_token", refresh), ("grant_type", "refresh_token")])["access_token"] as? String else { throw problem("Google didn’t return an access token.") }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "image/png", size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        func session(_ parent: String) async throws -> (Data, URLResponse) {
            var request = authorized("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink", access: access, method: "POST", body: ["name": "\(title).\(file.pathExtension)", "parents": [parent]])
            request.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type"); request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            return try await URLSession.shared.data(for: request)
        }
        var parent = folder.isEmpty ? try await makeFolder(access: access) : folder
        var (data, response) = try await session(parent)
        if (response as? HTTPURLResponse)?.statusCode == 404 { parent = try await makeFolder(access: access); (data, response) = try await session(parent) }
        _ = try checked(data, response)
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else { throw problem("Google Drive didn’t start the upload.") }
        var put = URLRequest(url: target); put.httpMethod = "PUT"; put.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (sent, sentResponse) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: CloudProgress(progress))
        let created = try checked(sent, sentResponse)
        guard let id = created["id"] as? String, let link = (created["webViewLink"] as? String).flatMap(URL.init(string:)) else { throw problem("Google Drive didn’t return the file.") }
        if isPublic {
            let (shared, sharedResponse) = try await URLSession.shared.data(for: authorized("https://www.googleapis.com/drive/v3/files/\(id)/permissions", access: access, method: "POST", body: ["role": "reader", "type": "anyone"]))
            _ = try checked(shared, sharedResponse)
        }
        return (link, parent)
    }
}

/// A one-shot web server on this Mac for the browser to come back to after signing in.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.sam.Still.google-signin")
    private var waiter: CheckedContinuation<String, Error>?
    private var state = ""
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var started = false
            listener.stateUpdateHandler = { [listener] update in
                guard !started else { return }
                switch update {
                case .ready: started = true; continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): started = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    func waitForCode(state: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.state = state; waiter = continuation
                queue.asyncAfter(deadline: .now()+300) { [weak self] in self?.finish(.failure(CloudError.response("Google sign-in timed out. Try connecting again."))) }
            }
        }
    }
    private func finish(_ result: Result<String, Error>) { waiter?.resume(with: result); waiter = nil }
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            var message = "Still is connected to Google Drive. You can close this tab."
            var result: Result<String, Error>?
            do { if let code = try GoogleAuth.code(requestLine: line, state: self.state) { result = .success(code) } else { message = "" } }
            catch { message = error as? GoogleAuth.CallbackError == .denied ? "Google Drive access wasn’t allowed." : "The sign-in didn’t work. Try connecting again from Still."; result = .failure(CloudError.response(message)) }
            let page = "<!doctype html><meta charset=utf-8><title>Still</title><body style=\"font:16px system-ui;text-align:center;padding-top:20vh\">\(message)</body>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let result { self.finish(result) }
        }
    }
}
