import CryptoKit
import Foundation

/// The pure parts of Google's desktop sign-in, kept here so they can be tested.
public enum GoogleAuth {
    public enum CallbackError: Error, Equatable { case stateMismatch, denied, failed(String), missingCode }

    /// PKCE: the S256 challenge for a verifier (RFC 7636).
    public static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Pulls the code out of the browser's redirect. Returns nil for other requests, such as /favicon.ico.
    public static func code(requestLine: String, state: String) throws -> String? {
        let parts = requestLine.split(separator: " ")
        guard parts.count > 1, let url = URLComponents(string: "http://127.0.0.1\(parts[1])"), url.path == "/" || url.path.isEmpty else { return nil }
        let value = { (key: String) in url.queryItems?.first(where: { $0.name == key })?.value }
        guard value("state") == state else { throw CallbackError.stateMismatch }
        if let error = value("error") { throw error == "access_denied" ? CallbackError.denied : CallbackError.failed(error) }
        guard let code = value("code") else { throw CallbackError.missingCode }
        return code
    }
}
