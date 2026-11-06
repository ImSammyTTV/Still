import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Still for Claude: an MCP server, so Claude (the desktop app, Claude Code and other MCP clients) can take a screenshot,
/// look through Capture History, read a capture's text and picture, describe it and share it.
///
/// The running app listens on 127.0.0.1 (a random port) for one JSON line per request carrying a secret token; the port
/// and token are in a private file, written only while Settings → Claude → "Let Claude use Still" is on.
/// `Still --mcp` is what Claude starts: MCP (JSON-RPC over stdin/stdout) that passes each tool call to the running app.
/// Follows Desktop/src-tauri/src/mcp.rs and shares its test cases.
public enum StillConnector {
    public static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Where the running app writes its port and token.
    public static var linkFile: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/mcp.json") }

    public static var tools: [[String: Any]] {
        let id: [String: Any] = ["type": "object", "properties": ["id": ["type": "string", "description": "The capture's id, from still_list_captures or still_capture_screen."]], "required": ["id"]]
        return [
            ["name": "still_capture_screen", "description": "Take a screenshot of the whole screen with Still. It is saved in Still's Capture History and returned as an image, so you can see what is on the user's screen. Use it when the user asks you to look at their screen.",
             "inputSchema": ["type": "object", "properties": ["display": ["type": "integer", "minimum": 1, "description": "Which display, counting from 1 (the main one). Leave out for the main display."]]]],
            ["name": "still_list_captures", "description": "List the user's screenshots and recordings in Still's Capture History, newest first. A query searches titles, the text Still recognized in screenshots, and their descriptions.",
             "inputSchema": ["type": "object", "properties": [
                "query": ["type": "string", "description": "Words to search for. Leave out to list the latest captures."],
                "kind": ["type": "string", "enum": ["all", "screenshot", "recording", "starred"], "description": "Which captures. Default all."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many, at most. Default 20."]]]],
            ["name": "still_get_capture", "description": "Get one capture from Still: its title, date, size, file path, any recognized text and description, and for a screenshot the picture itself.", "inputSchema": id],
            ["name": "still_describe_capture", "description": "Have Still describe a screenshot in words (with the service chosen in Still's settings) and keep the description with it for search.", "inputSchema": id],
            ["name": "still_share_capture", "description": "Upload a capture with Still's cloud settings and return its share link. Ask the user before sharing anything.", "inputSchema": id],
            ["name": "still_open_capture", "description": "Open a capture in Still on the user's screen: a screenshot in the editor, a recording in the video editor.", "inputSchema": id],
        ]
    }

    public static func textResult(_ text: String, error: Bool = false) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": error] }

    /// The answer to one JSON-RPC message, or nil for a notification.
    public static func answer(_ message: [String: Any], version: String, call: (String, [String: Any]) -> [String: Any]) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let ok = { (result: Any) -> [String: Any] in ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            let asked = (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? ""
            return ok(["protocolVersion": versions.contains(asked) ? asked : versions[0], "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": "still", "title": "Still", "version": version],
                       "instructions": "Still is the user's screenshot and screen recording app. Use still_capture_screen to see their screen, and still_list_captures to find earlier screenshots by what was on them."])
        case "ping": return ok([String: Any]())
        case "tools/list": return ok(["tools": tools])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            return ok(call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
        default: return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    /// Compares two secrets without stopping at the first difference.
    public static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        return x.count == y.count && zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // ---- `Still --mcp` ------------------------------------------------------------------------------

    /// Passes one tool call to the running app over 127.0.0.1 and returns its result.
    static func forward(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let off = "Still isn’t letting Claude in right now. Open Still, then in Settings → Claude turn on “Let Claude use Still”."
        guard let data = try? Data(contentsOf: linkFile), let link = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = (link["port"] as? NSNumber)?.uint16Value, let token = link["token"] as? String else { return textResult(off, error: true) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return textResult("Couldn’t reach Still.", error: true) }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return textResult("Still isn’t running. Open Still and try again.", error: true) }
        var timeout = timeval(tv_sec: 180, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard var request = try? JSONSerialization.data(withJSONObject: ["token": token, "name": name, "arguments": arguments]) else { return textResult("Couldn’t send the request.", error: true) }
        request.append(10)
        let sent = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return textResult("Couldn’t reach Still.", error: true) }
        var reply = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(10) {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            reply.append(contentsOf: buffer[0..<n])
        }
        guard let line = reply.split(separator: 10).first, let result = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return textResult("Still didn’t answer in time.", error: true) }
        return result
    }

    /// `Still --mcp`: an MCP server on stdin/stdout, one JSON message per line, until stdin closes.
    public static func runBridge(version: String) {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply: [String: Any]?
            if let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { reply = answer(message, version: version, call: forward) }
            else { reply = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]] }
            if let reply, let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            }
        }
    }
}
