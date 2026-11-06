import SwiftUI
import StillCore

/// Settings → Claude: Still for Claude, so Claude (the desktop app or Claude Code) can take screenshots and look
/// through History, with the exact lines to paste into Claude.
struct ClaudeSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var copied = ""
    private var executable: String { Bundle.main.executableURL?.path ?? "/Applications/Still.app/Contents/MacOS/Still" }
    private var desktopConfig: String {
        let config: [String: Any] = ["mcpServers": ["still": ["command": executable, "args": ["--mcp"]]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private var codeCommand: String { "claude mcp add --scope user still -- \"\(executable)\" --mcp" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("Still for Claude") {
                Toggle("Let Claude use Still", isOn: $prefs.claudeConnector).onChange(of: prefs.claudeConnector) { _, _ in ConnectorServer.shared.apply() }
                note("With this on, Claude can take a screenshot of your screen, look through and search Capture History, read a capture’s text and picture, describe it, open it, and share it when you ask. Claude only reaches Still from this Mac, and only while Still is running. Turn it off to stop it at once.")
            }
            if prefs.claudeConnector {
                card("Claude Desktop") {
                    HStack { Text("Add to Claude’s settings"); Spacer(); Button(copied == "desktop" ? "Copied" : "Copy") { copy(desktopConfig, "desktop") } }
                    code(desktopConfig)
                    note("In Claude Desktop, open Settings → Developer → Edit Config, paste this into claude_desktop_config.json (merge it with any “mcpServers” already there), save, and restart Claude. Then ask Claude to “take a screenshot with Still”. The first screenshot may ask for Screen Recording permission for Still.")
                }
                card("Claude Code") {
                    HStack { Text("Add with one command"); Spacer(); Button(copied == "code" ? "Copied" : "Copy") { copy(codeCommand, "code") } }
                    code(codeCommand)
                    note("Run this in Terminal once. Claude Code can then use Still in any project.")
                }
            }
        }.toggleStyle(PreferenceToggleStyle()).controlSize(.small)
    }
    private func copy(_ text: String, _ what: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = what }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 13, weight: .semibold)); content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.card))
    }
}
