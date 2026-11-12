import Foundation

/// "Add to Claude": Still for Claude as a Claude Desktop extension (an .mcpb file), so it installs with one click
/// instead of copying settings by hand. The bundle holds a manifest, Still's icon and a small launcher; Claude runs the
/// Still app already on this Mac with `--mcp`. Follows Desktop/src-tauri/src/mcpb.rs.
public enum ClaudeExtension {
    public static let launcherPath = "server/still-mcp"

    /// The bundle's manifest (MCP Bundle format 0.3). `executable` is Still's own path on this Mac.
    public static func manifest(version: String, executable: String) -> [String: Any] {
        [
            "manifest_version": "0.3",
            "name": "still",
            "display_name": "Still",
            "version": version,
            "description": "Screenshots and Capture History from the Still app on this computer.",
            "long_description": "Lets Claude take a screenshot of your screen with Still, search your Capture History by what was on screen, read a capture's text and picture, describe it and open it in Still. Still must be running, with Settings → Claude → Let Claude use Still turned on.",
            "author": ["name": "Still"],
            "icon": "icon.png",
            "server": ["type": "binary", "entry_point": launcherPath, "mcp_config": ["command": executable, "args": ["--mcp"]]],
            "tools": StillConnector.tools.map { ["name": $0["name"] ?? "", "description": $0["description"] ?? ""] },
            "compatibility": ["platforms": ["darwin"]],
        ]
    }

    /// A launcher that does what the manifest's command does, for anyone opening the bundle by hand.
    public static func launcher(executable: String) -> String {
        "#!/bin/sh\nexec \"\(executable.replacingOccurrences(of: "\"", with: "\\\""))\" --mcp \"$@\"\n"
    }

    /// Writes the bundle's files into `folder` (manifest.json, icon.png, the launcher), ready to be zipped as an .mcpb.
    public static func write(into folder: URL, version: String, executable: String, iconPNG: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("server"), withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: manifest(version: version, executable: executable), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: folder.appendingPathComponent("manifest.json"))
        try iconPNG.write(to: folder.appendingPathComponent("icon.png"))
        let script = folder.appendingPathComponent(launcherPath)
        try Data(launcher(executable: executable).utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
}
