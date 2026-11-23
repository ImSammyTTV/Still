import SwiftUI
import StillCore

/// Describe Image keys, kept in Keychain: Gemini's, Claude's (an Anthropic API key) and ChatGPT's (an OpenAI API key).
@MainActor enum GeminiKey {
    static let gemini = "local.sam.Still.gemini", claude = "local.sam.Still.anthropic", openai = "local.sam.Still.openai"
    /// The key for the service Settings picked.
    static var service: String { keychainService(for: Preferences.shared.describeProvider) }
    /// Each service keeps its own key, so switching the picker back and forth doesn't lose one.
    static func keychainService(for provider: String) -> String { provider == "claude" ? claude : provider == "openai" ? openai : gemini }
    private static var query: [CFString: Any] { keychainQuery(service) }
    private static func keychainQuery(_ service: String) -> [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "default"] }
    static var value: String? {
        var q = query; q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
    static func save(_ key: String) throws { try save(key, service: service) }
    /// Saves a key for one service in particular, whichever one Settings shows by the time it's saved.
    static func save(_ key: String, service: String) throws {
        let data = Data(key.utf8), query = keychainQuery(service)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound { var entry = query; entry[kSecValueData] = data; status = SecItemAdd(entry as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeyError(message: "The key could not be saved in Keychain (\(status)).") }
    }
    struct KeyError: LocalizedError { let message: String; var errorDescription: String? { message } }
}

/// Settings → AI: Describe Image, with the user's own Gemini, Anthropic or OpenAI key.
struct AISettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var geminiKey = ""
    /// Read from Keychain when the page opens: as a starting value it was read again on every redraw of Settings.
    @State private var geminiSaved = false
    @State private var geminiStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("Describe Image") {
                HStack { Text("Describe with"); Spacer(); Picker("Describe with", selection: $prefs.describeProvider) { Text("Google Gemini (free key)").tag("gemini"); Text("Claude (Anthropic API key)").tag("claude"); Text("ChatGPT (OpenAI key)").tag("openai") }.labelsHidden().fixedSize() }
                    .onChange(of: prefs.describeProvider) { _, _ in geminiSaved = GeminiKey.value != nil; geminiKey = ""; geminiStatus = "" }
                // People who already pay for Claude can describe and search captures through it, with no key to set up.
                Text("Have Claude Pro or Max? Turn on [Settings → Claude](still-settings://claude) and ask Claude to describe or search your captures — it uses your own Claude plan, no key needed.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "still-settings" else { return .systemAction }
                        MainActor.assumeIsolated { AppController.shared.library.page = "Claude" }
                        return .handled
                    })
                let info = keyInfo(prefs.describeProvider)
                SecureField("\(info.name) API Key", text: $geminiKey, prompt: Text(geminiSaved ? "Saved in Keychain — paste a new one to replace it" : "\(info.name) API key")).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { saveGemini() }.disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if geminiSaved { Button("Remove") { GeminiKey.remove(); geminiSaved = false; geminiStatus = "Key removed" } }
                    Spacer(); Button(info.button) { if let url = URL(string: info.url) { NSWorkspace.shared.open(url) } }
                }
                if !geminiStatus.isEmpty { Text(geminiStatus).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("Right-click a screenshot in History and choose Describe Image to get a short description of it, which History’s search then finds. Only the picture you describe is sent, and only then. " + info.note)
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(PreferenceToggleStyle()).controlSize(.small)
        .onAppear { geminiSaved = GeminiKey.value != nil }
    }
    /// What the key row says for each service: whose key it is, where to get one, and what using it costs.
    private func keyInfo(_ provider: String) -> (name: String, button: String, url: String, note: String) {
        switch provider {
        case "claude": return ("Anthropic", "Get an API Key", "https://console.anthropic.com/settings/keys",
                               "Claude uses your own Anthropic API key and is billed to that account: about a cent per picture.")
        case "openai": return ("OpenAI", "Get an API Key", "https://platform.openai.com/api-keys",
                               "ChatGPT uses your own OpenAI API key: get one at platform.openai.com (API keys). It’s billed per use to your OpenAI account, separately from a ChatGPT Plus subscription.")
        default: return ("Gemini", "Get a Free Key", "https://aistudio.google.com/apikey",
                         "Gemini uses your own key, free from Google AI Studio. On Google’s free tier, Google may use what you send to improve its products, so don’t describe anything private.")
        }
    }
    private func saveGemini() {
        // The service is fixed when Save is pressed: switching the picker during the check must not store this key
        // as the other service's, nor show its result under the other one.
        let key = geminiKey.trimmingCharacters(in: .whitespaces), provider = prefs.describeProvider; geminiStatus = "Checking…"
        Task {
            do {
                switch provider {
                case "claude": try await ImageDescriber.checkClaude(key: key)
                case "openai": try await ImageDescriber.checkOpenAI(key: key)
                default: try await ImageDescriber.check(key: key)
                }
                try GeminiKey.save(key, service: GeminiKey.keychainService(for: provider))
                guard prefs.describeProvider == provider else { return }
                geminiSaved = true; geminiKey = ""; geminiStatus = "Key saved"
            }
            catch { if prefs.describeProvider == provider { geminiStatus = error.localizedDescription } }
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11, weight: .semibold)); VStack(alignment: .leading, spacing: 13, content: content).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)) } }
}
