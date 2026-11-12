import SwiftUI
import StillCore

/// Describe Image keys, kept in Keychain: Gemini's and Claude's (an Anthropic API key).
@MainActor enum GeminiKey {
    static let gemini = "local.sam.Still.gemini", claude = "local.sam.Still.anthropic"
    /// The key for the service Settings picked.
    static var service: String { Preferences.shared.describeProvider == "claude" ? claude : gemini }
    private static var query: [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "default"] }
    static var value: String? {
        var q = query; q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound { var entry = query; entry[kSecValueData] = data; status = SecItemAdd(entry as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeyError(message: "The key could not be saved in Keychain (\(status)).") }
    }
    struct KeyError: LocalizedError { let message: String; var errorDescription: String? { message } }
}

/// Settings → AI: Describe Image, with the user's own Gemini or Anthropic key.
struct AISettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var geminiKey = ""
    @State private var geminiSaved = GeminiKey.value != nil
    @State private var geminiStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("Describe Image") {
                HStack { Text("Describe with"); Spacer(); Picker("Describe with", selection: $prefs.describeProvider) { Text("Google Gemini (free key)").tag("gemini"); Text("Claude (Anthropic API key)").tag("claude") }.labelsHidden().fixedSize() }
                    .onChange(of: prefs.describeProvider) { _, _ in geminiSaved = GeminiKey.value != nil; geminiKey = ""; geminiStatus = "" }
                let claude = prefs.describeProvider == "claude"
                SecureField(claude ? "Anthropic API Key" : "Gemini API Key", text: $geminiKey, prompt: Text(geminiSaved ? "Saved in Keychain — paste a new one to replace it" : claude ? "Anthropic API key" : "Gemini API key")).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { saveGemini() }.disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if geminiSaved { Button("Remove") { GeminiKey.remove(); geminiSaved = false; geminiStatus = "Key removed" } }
                    Spacer(); Button(claude ? "Get an API Key" : "Get a Free Key") { if let url = URL(string: claude ? "https://console.anthropic.com/settings/keys" : "https://aistudio.google.com/apikey") { NSWorkspace.shared.open(url) } }
                }
                if !geminiStatus.isEmpty { Text(geminiStatus).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("Right-click a screenshot in History and choose Describe Image to get a short description of it, which History’s search then finds. Only the picture you describe is sent, and only then. " + (claude
                    ? "Claude uses your own Anthropic API key and is billed to that account: about a cent per picture."
                    : "Gemini uses your own key, free from Google AI Studio. On Google’s free tier, Google may use what you send to improve its products, so don’t describe anything private.")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(PreferenceToggleStyle()).controlSize(.small)
    }
    private func saveGemini() {
        let key = geminiKey.trimmingCharacters(in: .whitespaces); geminiStatus = "Checking…"
        Task {
            do {
                if prefs.describeProvider == "claude" { try await ImageDescriber.checkClaude(key: key) } else { try await ImageDescriber.check(key: key) }
                try GeminiKey.save(key); geminiSaved = true; geminiKey = ""; geminiStatus = "Key saved"
            }
            catch { geminiStatus = error.localizedDescription }
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11, weight: .semibold)); VStack(alignment: .leading, spacing: 13, content: content).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)) } }
}
