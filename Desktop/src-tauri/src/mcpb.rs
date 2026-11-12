//! "Add to Claude": Still for Claude as a Claude Desktop extension (an .mcpb file), so it installs with one click
//! instead of copying settings by hand. The bundle holds a manifest, Still's icon and a small launcher; Claude runs
//! the Still app already on this computer with `--mcp` (see mcp.rs), so the bundle carries no copy of Still.
use serde_json::{json, Value};
use std::io::Write;

/// The bundle's manifest (MCP Bundle format 0.3). `exe` is Still's own path on this computer.
pub fn manifest(version: &str, exe: &str, platform: &str) -> Value {
    let tools: Vec<Value> = crate::mcp::tools().as_array().cloned().unwrap_or_default().into_iter()
        .map(|t| json!({ "name": t["name"], "description": t["description"] })).collect();
    json!({
        "manifest_version": "0.3",
        "name": "still",
        "display_name": "Still",
        "version": version,
        "description": "Screenshots and Capture History from the Still app on this computer.",
        "long_description": "Lets Claude take a screenshot of your screen with Still, search your Capture History by what was on screen, read a capture's text and picture, describe it and open it in Still. Still must be running, with Settings → Claude → Let Claude use Still turned on.",
        "author": { "name": "Still" },
        "icon": "icon.png",
        "server": {
            "type": "binary",
            "entry_point": launcher_name(platform),
            "mcp_config": { "command": exe, "args": ["--mcp"] }
        },
        "tools": tools,
        "compatibility": { "platforms": [platform] }
    })
}

fn launcher_name(platform: &str) -> &'static str { if platform == "win32" { "server/still-mcp.cmd" } else { "server/still-mcp" } }

/// A launcher that does what the manifest's command does, for anyone opening the bundle by hand.
fn launcher(exe: &str, platform: &str) -> String {
    if platform == "win32" { format!("@echo off\r\n\"{exe}\" --mcp %*\r\n") }
    else { format!("#!/bin/sh\nexec \"{}\" --mcp \"$@\"\n", exe.replace('"', "\\\"")) }
}

/// The .mcpb file itself: a zip of the manifest, the icon and the launcher.
pub fn bundle(version: &str, exe: &str, platform: &str, icon_png: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let stored = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    let manifest = serde_json::to_string_pretty(&manifest(version, exe, platform)).map_err(|e| e.to_string())?;
    let script = launcher(exe, platform);
    let files: [(&str, &[u8], u32); 3] = [
        ("manifest.json", manifest.as_bytes(), 0o644),
        ("icon.png", icon_png, 0o644),
        (launcher_name(platform), script.as_bytes(), 0o755),
    ];
    for (name, data, mode) in files {
        out.start_file(name, stored.unix_permissions(mode)).map_err(|e| e.to_string())?;
        out.write_all(data).map_err(|e| e.to_string())?;
    }
    Ok(out.finish().map_err(|e| e.to_string())?.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manifest_runs_this_still_with_mcp_and_lists_every_tool() {
        let m = manifest("1.2.48", "C:\\Program Files\\Still\\Still.exe", "win32");
        assert_eq!(m["manifest_version"], "0.3");
        assert_eq!(m["server"]["mcp_config"]["command"], "C:\\Program Files\\Still\\Still.exe");
        assert_eq!(m["server"]["mcp_config"]["args"], json!(["--mcp"]));
        assert_eq!(m["server"]["entry_point"], "server/still-mcp.cmd");
        assert_eq!(m["tools"].as_array().unwrap().len(), crate::mcp::tools().as_array().unwrap().len());
        assert!(m["tools"][0].get("inputSchema").is_none(), "the manifest lists names and descriptions only");
        assert_eq!(m["compatibility"]["platforms"], json!(["win32"]));
    }
    #[test]
    fn bundle_is_a_zip_with_the_manifest_icon_and_launcher() {
        let bytes = bundle("1.2.48", "/opt/Still/still", "linux", b"\x89PNG").unwrap();
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
        let names: Vec<String> = (0..zip.len()).map(|i| zip.by_index(i).unwrap().name().to_string()).collect();
        assert_eq!(names, ["manifest.json", "icon.png", "server/still-mcp"]);
        let mut text = String::new();
        std::io::Read::read_to_string(&mut zip.by_name("manifest.json").unwrap(), &mut text).unwrap();
        let m: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(m["name"], "still");
        let mut script = String::new();
        std::io::Read::read_to_string(&mut zip.by_name("server/still-mcp").unwrap(), &mut script).unwrap();
        assert!(script.contains("exec \"/opt/Still/still\" --mcp"));
    }
}
