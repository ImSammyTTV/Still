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

    @State private var adding = false
    @State private var addStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("Add to Claude") {
                HStack { Text("Add Still to Claude Desktop in one step"); Spacer(); Button(adding ? "Opening…" : "Add to Claude") { addToClaude() }.buttonStyle(.borderedProminent).disabled(adding) }
                if !addStatus.isEmpty { Text(addStatus).font(.system(size: 11)).foregroundStyle(Studio.accent).fixedSize(horizontal: false, vertical: true) }
                note("Opens Claude Desktop with Still ready to install: choose Install, and Claude can use Still. This also turns on “Let Claude use Still” below.")
            }
            card("Still for Claude") {
                Toggle("Let Claude use Still", isOn: $prefs.claudeConnector).onChange(of: prefs.claudeConnector) { _, _ in ConnectorServer.shared.apply() }
                note("With this on, Claude can take a screenshot of your screen, look through and search Capture History, read a capture’s text and picture, describe it, open it, and share it when you ask. Claude only reaches Still from this Mac, and only while Still is running. Turn it off to stop it at once.")
            }
            if prefs.claudeConnector {
                card("Claude Desktop, by hand") {
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
    /// Turns the connector on, writes Still as a Claude Desktop extension (an .mcpb zip) and opens it in Claude Desktop,
    /// which shows its install prompt.
    private func addToClaude() {
        guard let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            addStatus = "Claude Desktop isn’t installed. Get it from claude.ai/download, then try again."; return
        }
        prefs.claudeConnector = true; ConnectorServer.shared.apply()
        adding = true; addStatus = ""
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let executable = executable, icon = Self.iconPNG()
        Task { @MainActor in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in Result {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("Still-mcpb-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: work) }
                try ClaudeExtension.write(into: work, version: version, executable: executable, iconPNG: icon)
                let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let bundle = folder.appendingPathComponent("Still.mcpb")
                try? fm.removeItem(at: bundle)
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = work
                zip.arguments = ["-q", "-r", "-X", bundle.path, "manifest.json", "icon.png", "server"]
                try zip.run(); zip.waitUntilExit()
                guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                return bundle
            } }.value
            adding = false
            switch result {
            case .success(let bundle):
                NSWorkspace.shared.open([bundle], withApplicationAt: claude, configuration: NSWorkspace.OpenConfiguration())
                addStatus = "Claude Desktop is opening. Choose Install to add Still."
            case .failure(let error):
                addStatus = "Couldn’t add Still to Claude: \(error.localizedDescription)"
            }
        }
    }
    private static func iconPNG() -> Data {
        let size = NSSize(width: 512, height: 512)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
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
