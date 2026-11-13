import Foundation

/// Describe Image: a short description of a screenshot, from Google's Gemini API with the user's own free key (from
/// Google AI Studio), or from Claude with the user's own Anthropic API key. Only the picture asked about is sent, and only then. Follows Desktop/src-tauri/src/describe.rs
/// and shares its test cases.
public enum ImageDescriber {
    static let base = "https://generativelanguage.googleapis.com/v1beta"
    /// Google keeps this name pointing at its current Flash model, which the free tier includes.
    public static let model = "gemini-flash-latest"
    public static let prompt = "Describe this screenshot in one or two plain sentences for someone who can't see it, as alt text: say what app or page it shows and what matters on it. Then, on a new line starting with \"Text: \", quote any short heading or button text that stands out. No preamble."

    public struct Failure: LocalizedError { public let message: String; public init(message: String) { self.message = message }; public var errorDescription: String? { message } }

    /// The request body for one picture (PNG or JPEG data).
    public static func body(mime: String, data: Data) -> [String: Any] {
        ["contents": [["parts": [["text": prompt], ["inline_data": ["mime_type": mime, "data": data.base64EncodedString()]]]]],
         "generationConfig": ["temperature": 0.2, "maxOutputTokens": 300]]
    }
    /// The description in a response: its text parts joined and trimmed, or why there isn't one, in plain words.
    public static func text(of response: [String: Any]) -> Result<String, Failure> {
        if let error = response["error"] as? [String: Any] { return .failure(Failure(message: explain(error["code"] as? Int ?? 0, error["message"] as? String ?? ""))) }
        let candidate = (response["candidates"] as? [[String: Any]])?.first
        let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let why = ((response["promptFeedback"] as? [String: Any])?["blockReason"] as? String) ?? (candidate?["finishReason"] as? String) ?? "no text came back"
            return .failure(Failure(message: "Gemini didn’t describe this picture (\(why))."))
        }
        return .success(text)
    }
    public static func explain(_ code: Int, _ message: String) -> String {
        switch code {
        case 400 where message.lowercased().contains("api key"): return "That Gemini key isn’t valid. Copy it again from Google AI Studio."
        case 401, 403: return "Gemini refused the key. Check it in Google AI Studio, or make a new one."
        case 429: return "Gemini’s free limit is used up for now. Try again in a minute (or later today)."
        case 500, 502, 503, 504: return "Google’s servers are busy right now, so Gemini couldn’t describe this. Try again in a minute."
        default: return message.isEmpty ? "Gemini answered with an error (\(code))." : "Gemini: \(message)"
        }
    }
    /// A Flash model this key can use, from Google's list, for when the usual name isn't offered to it.
    public static func pickModel(_ list: [String: Any]) -> String? {
        let models = list["models"] as? [[String: Any]] ?? []
        return models.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { ($0["name"] as? String).map { $0.replacingOccurrences(of: "models/", with: "") } }
            .filter { $0.contains("flash") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("live") }.max()
    }

    private static func json(_ request: URLRequest) async throws -> (Int, [String: Any]) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
    private static func request(_ path: String, key: String, body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(base)/\(path)")!, timeoutInterval: 60)
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let body { r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    /// Google's lighter model, asked when the main one is busy.
    public static let liteModel = "gemini-flash-lite-latest"
    /// Answers that mean "busy right now", worth asking again (or asking another model) rather than giving up.
    public static func busy(_ status: Int) -> Bool { [429, 500, 502, 503, 504].contains(status) }
    /// Describes a picture with the user's key.
    public static func describe(key: String, mime: String, data: Data) async throws -> String {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure(message: "Add a Gemini key in Settings → AI first.") }
        let payload = body(mime: mime, data: data)
        do {
            var (status, response) = try await json(request("models/\(model):generateContent", key: key, body: payload))
            // Google turns requests away when its servers are busy ("high demand"), usually for moments: wait and ask
            // again, then ask its lighter model, which has its own capacity and free-tier limits.
            if busy(status) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                (status, response) = try await json(request("models/\(model):generateContent", key: key, body: payload))
            }
            if busy(status) {
                let (liteStatus, liteResponse) = try await json(request("models/\(liteModel):generateContent", key: key, body: payload))
                if liteStatus != 404 { (status, response) = (liteStatus, liteResponse) }
            }
            if status == 404 {
                let (_, list) = try await json(request("models?pageSize=200", key: key))
                guard let other = pickModel(list) else { throw Failure(message: "This Gemini key has no Flash model to describe pictures with.") }
                (status, response) = try await json(request("models/\(other):generateContent", key: key, body: payload))
            }
            return try text(of: response).get()
        } catch let failure as Failure { throw failure }
        catch { throw Failure(message: "Couldn’t reach Gemini: \(error.localizedDescription)") }
    }
    /// Checks a key by listing the models it can use, so Settings can say straight away whether it works.
    public static func check(key: String) async throws {
        let (status, response) = try await json(request("models?pageSize=1", key: key.trimmingCharacters(in: .whitespaces)))
        guard status == 200 else { throw Failure(message: explain(status, (response["error"] as? [String: Any])?["message"] as? String ?? "")) }
    }

    // ---- Claude ---------------------------------------------------------------------------------------
    static let claudeURL = "https://api.anthropic.com/v1"
    public static let claudeModel = "claude-opus-5-5"
    /// Lets the API hand a request it declines on safety grounds to another model in the same call.
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// The Messages API request for one picture: the image first, then the prompt. A short task, so low effort.
    public static func claudeBody(mime: String, data: Data) -> [String: Any] {
        ["model": claudeModel, "max_tokens": 2048, "output_config": ["effort": "low"], "fallbacks": "default",
         "messages": [["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]],
            ["type": "text", "text": prompt]]]]]
    }
    /// The description in a Messages API response: its text blocks joined, or why there isn't one.
    public static func claudeText(status: Int, _ response: [String: Any]) -> Result<String, Failure> {
        if response["type"] as? String == "error" || status >= 400 {
            let message = (response["error"] as? [String: Any])?["message"] as? String ?? ""
            switch status {
            case 401: return .failure(Failure(message: "That Anthropic API key isn’t valid. Copy it again from the Claude Console."))
            case 403: return .failure(Failure(message: "Claude refused the key (it may not have access to this model)."))
            case 429: return .failure(Failure(message: "Claude’s rate limit is reached for now. Try again in a minute."))
            case 529: return .failure(Failure(message: "Claude is busy right now. Try again in a minute."))
            default: return .failure(Failure(message: message.isEmpty ? "Claude answered with an error (\(status))." : "Claude: \(message)"))
            }
        }
        if response["stop_reason"] as? String == "refusal" { return .failure(Failure(message: "Claude declined to describe this picture.")) }
        let blocks = response["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failure(Failure(message: "Claude didn’t describe this picture.")) : .success(text)
    }
    private static func claudeRequest(_ path: String, key: String, body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(claudeURL)/\(path)")!, timeoutInterval: 60)
        r.setValue(key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if let body {
            r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }
    public static func describeWithClaude(key: String, mime: String, data: Data) async throws -> String {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure(message: "Add an Anthropic API key in Settings → AI first.") }
        do {
            let (status, response) = try await json(claudeRequest("messages", key: key, body: claudeBody(mime: mime, data: data)))
            return try claudeText(status: status, response).get()
        } catch let failure as Failure { throw failure }
        catch { throw Failure(message: "Couldn’t reach Claude: \(error.localizedDescription)") }
    }
    /// Checks an Anthropic key by listing one model, so Settings can say straight away whether it works.
    public static func checkClaude(key: String) async throws {
        let (status, response) = try await json(claudeRequest("models?limit=1", key: key))
        guard status == 200 else { _ = try claudeText(status: status, response).get(); return }
    }
}
