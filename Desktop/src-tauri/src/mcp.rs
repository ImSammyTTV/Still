//! Still for Claude: an MCP server, so Claude (the desktop app, Claude Code and other MCP clients) can take a
//! screenshot, look through Capture History, read a capture's text and picture and describe it.
//!
//! Two halves. The running app listens on 127.0.0.1 (a random port) for one JSON line per request, carrying a secret
//! token; the port and token are in a private file in Still's settings folder, written only while Settings → Claude →
//! "Let Claude use Still" is on. `Still --mcp` is what Claude starts: it speaks MCP (JSON-RPC over stdin/stdout) and
//! passes each tool call to the running app. The Mac app's StillConnector follows the same protocol and tools.
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;

pub const FILE: &str = "mcp.json";
const VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

/// The tools Claude sees, with what each takes.
pub fn tools() -> Value {
    let id = json!({ "type": "object", "properties": { "id": { "type": "string", "description": "The capture's id, from still_list_captures or still_capture_screen." } }, "required": ["id"] });
    json!([
        { "name": "still_capture_screen", "description": "Take a screenshot of the whole screen with Still. It is saved in Still's Capture History and returned as an image, so you can see what is on the user's screen. Use it when the user asks you to look at their screen.",
          "inputSchema": { "type": "object", "properties": { "display": { "type": "integer", "minimum": 1, "description": "Which display, counting from 1 (the main one). Leave out for the main display." } } } },
        { "name": "still_list_captures", "description": "List the user's screenshots and recordings in Still's Capture History, newest first. A query searches titles, the text Still recognized in screenshots, and their descriptions.",
          "inputSchema": { "type": "object", "properties": {
              "query": { "type": "string", "description": "Words to search for. Leave out to list the latest captures." },
              "kind": { "type": "string", "enum": ["all", "screenshot", "recording", "starred"], "description": "Which captures. Default all." },
              "limit": { "type": "integer", "minimum": 1, "maximum": 50, "description": "How many, at most. Default 20." } } } },
        { "name": "still_get_capture", "description": "Get one capture from Still: its title, date, size, file path, any recognized text and description, and for a screenshot the picture itself.", "inputSchema": id },
        { "name": "still_describe_capture", "description": "Have Still describe a screenshot in words (with the service chosen in Still's settings) and keep the description with it for search.", "inputSchema": id },
        { "name": "still_open_capture", "description": "Open a capture in Still on the user's screen: a screenshot in the editor, a recording in the video editor.", "inputSchema": id },
    ])
}

/// Still's settings folder, worked out without the running app (the same place Tauri uses).
pub fn config_dir() -> Option<PathBuf> {
    let base = if cfg!(windows) { std::env::var_os("APPDATA").map(PathBuf::from) }
        else if cfg!(target_os = "macos") { std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support")) }
        else { std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config"))) };
    base.map(|b| b.join("app.still.desktop"))
}

/// The answer to one JSON-RPC message, or None for a notification.
pub fn answer(message: &Value, call: &mut dyn FnMut(&str, &Value) -> Value) -> Option<Value> {
    let id = message.get("id").cloned()?;
    let method = message["method"].as_str().unwrap_or("");
    let ok = |result: Value| json!({ "jsonrpc": "2.0", "id": id, "result": result });
    Some(match method {
        "initialize" => {
            let asked = message["params"]["protocolVersion"].as_str().unwrap_or("");
            let version = if VERSIONS.contains(&asked) { asked } else { VERSIONS[0] };
            ok(json!({ "protocolVersion": version, "capabilities": { "tools": {} },
                "serverInfo": { "name": "still", "title": "Still", "version": env!("CARGO_PKG_VERSION") },
                "instructions": "Still is the user's screenshot and screen recording app. Use still_capture_screen to see their screen, and still_list_captures to find earlier screenshots by what was on them." }))
        }
        "ping" => ok(json!({})),
        "tools/list" => ok(json!({ "tools": tools() })),
        "tools/call" => ok(call(message["params"]["name"].as_str().unwrap_or(""), &message["params"]["arguments"])),
        _ => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": format!("Unknown method {method}") } }),
    })
}

/// A tool result that is only words, marked as an error or not.
pub fn text_result(text: &str, error: bool) -> Value { json!({ "content": [{ "type": "text", "text": text }], "isError": error }) }

/// Passes one tool call to the running app and returns its result (an MCP CallToolResult).
fn forward(name: &str, arguments: &Value) -> Value {
    let off = "Still isn’t letting Claude in right now. Open Still, then in Settings → Claude turn on “Let Claude use Still”.";
    let Some(file) = config_dir().map(|d| d.join(FILE)) else { return text_result(off, true) };
    let Some(link) = std::fs::read_to_string(&file).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return text_result(off, true) };
    let port = link["port"].as_u64().unwrap_or(0) as u16;
    let Ok(mut stream) = std::net::TcpStream::connect(("127.0.0.1", port)) else { return text_result("Still isn’t running. Open Still and try again.", true) };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(180)));
    let request = json!({ "token": link["token"], "name": name, "arguments": arguments });
    if writeln!(stream, "{request}").is_err() { return text_result("Couldn’t reach Still.", true); }
    let mut line = String::new();
    match BufReader::new(stream).read_line(&mut line) {
        Ok(n) if n > 0 => serde_json::from_str(&line).unwrap_or_else(|_| text_result("Still sent an answer that couldn’t be read.", true)),
        _ => text_result("Still didn’t answer in time.", true),
    }
}

/// `Still --mcp`: an MCP server on stdin/stdout, one JSON message per line, until stdin closes.
pub fn run_bridge() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() { continue; }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(message) => answer(&message, &mut forward),
            Err(_) => Some(json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": "Parse error" } })),
        };
        if let Some(reply) = reply { let _ = writeln!(out, "{reply}"); let _ = out.flush(); }
    }
}

/// Reads one request line from a connection to the running app (at most 1 MB).
pub fn read_request(stream: &mut std::net::TcpStream) -> Option<Value> {
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let mut line = String::new();
    BufReader::new(stream.take(1_048_576)).read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// Compares two secrets without stopping at the first difference.
pub fn same_secret(a: &str, b: &str) -> bool { a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0 }

#[cfg(test)]
mod tests {
    use super::*;
    // The same cases are in the Mac app's StillConnectorTests.
    #[test]
    fn it_introduces_itself_and_lists_its_tools() {
        let mut never = |_: &str, _: &Value| -> Value { panic!("no tool call expected") };
        let hello = answer(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2025-03-26" } }), &mut never).unwrap();
        assert_eq!(hello["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(hello["result"]["serverInfo"]["name"], "still");
        let newer = answer(&json!({ "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": { "protocolVersion": "2099-01-01" } }), &mut never).unwrap();
        assert_eq!(newer["result"]["protocolVersion"], VERSIONS[0]);
        assert!(answer(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }), &mut never).is_none());
        let list = answer(&json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/list" }), &mut never).unwrap();
        let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["still_capture_screen", "still_list_captures", "still_get_capture", "still_describe_capture", "still_open_capture"]);
        let unknown = answer(&json!({ "jsonrpc": "2.0", "id": 4, "method": "resources/list" }), &mut never).unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
    }
    #[test]
    fn tool_calls_go_to_the_app_with_their_arguments() {
        let mut seen = Vec::new();
        let mut call = |name: &str, args: &Value| { seen.push((name.to_string(), args.clone())); text_result("ok", false) };
        let r = answer(&json!({ "jsonrpc": "2.0", "id": "a", "method": "tools/call", "params": { "name": "still_get_capture", "arguments": { "id": "x1" } } }), &mut call).unwrap();
        assert_eq!(r["id"], "a");
        assert_eq!(r["result"]["content"][0]["text"], "ok");
        assert_eq!(seen, vec![("still_get_capture".to_string(), json!({ "id": "x1" }))]);
        assert!(same_secret("abc", "abc") && !same_secret("abc", "abd") && !same_secret("abc", "ab"));
    }
}
