// Hide the console window on Windows release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // `Still --mcp` is Claude's connection to Still (see mcp.rs): no window, just MCP on stdin/stdout.
    if std::env::args().any(|a| a == "--mcp") { return still_lib::mcp_bridge(); }
    still_lib::run()
}
