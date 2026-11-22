//! Report a Problem: a small log of what went wrong, kept on this computer, and a plain-text report built from it.
//!
//! When something fails on someone else's machine, the notice they saw is usually all anyone has to go on. The log
//! keeps those notices and the errors behind them, with when they happened, so a report can show what led up to a
//! problem. It never holds pictures, clipboard text, file contents, keys or anything typed: only Still's own
//! messages. Nothing leaves the computer unless the user attaches the report themselves.

use serde_json::{Map, Value};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use tauri::{AppHandle, Manager};

/// Past this the log moves to still.log.1 (replacing the older one), so two files at most, about 2 MB together.
const MAX_BYTES: u64 = 1024 * 1024;
/// How much of the log goes into a report: enough to see what led up to a problem without burying it.
const REPORT_LINES: usize = 400;
/// Where the issue form is. A report never goes there by itself: the user attaches it.
const ISSUES: &str = "https://github.com/ImSammyTTV/Still/issues/new";

static LOG_DIR: OnceLock<PathBuf> = OnceLock::new();
/// One line at a time, so lines from different threads never interleave or race a rotation.
static WRITING: Mutex<()> = Mutex::new(());

/// Starts the log in `dir` (app data/logs). Lines logged before this are dropped.
pub fn init(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    let _ = LOG_DIR.set(dir);
}

/// Adds a line to the log, e.g. log("error", "Recording couldn’t be saved: …"). Never fails or blocks the caller for long.
pub fn log(level: &str, message: &str) { write(level, message, true); }

/// A notice Still showed. Most say what went wrong, which is what a report needs. "Text copied" carries the text
/// that was recognised, which is the user's own, so only its title is kept.
pub fn notice(title: &str, body: &str) { log("notice", &notice_text(title, body)); }

fn notice_text(title: &str, body: &str) -> String {
    if title == "Text copied" || body.trim().is_empty() { title.to_string() } else { format!("{title}: {body}") }
}

fn write(level: &str, message: &str, wait: bool) {
    let Some(dir) = LOG_DIR.get() else { return };
    // A panic while a line is being written must not wait on itself; a poisoned lock is still a good lock here.
    let _guard = if wait { WRITING.lock().unwrap_or_else(|e| e.into_inner()) } else {
        match WRITING.try_lock() { Ok(g) => g, Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(), Err(_) => return }
    };
    let file = dir.join("still.log");
    if std::fs::metadata(&file).map(|m| m.len() > MAX_BYTES).unwrap_or(false) {
        let older = dir.join("still.log.1");
        let _ = std::fs::remove_file(&older);
        let _ = std::fs::rename(&file, &older);
    }
    let stamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f").to_string();
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&file) { let _ = f.write_all(line(&stamp, level, message).as_bytes()); }
}

/// One log line: time, level and the message on a single line, cut short if a message runs on.
fn line(stamp: &str, level: &str, message: &str) -> String {
    let flat: String = message.split_whitespace().collect::<Vec<_>>().join(" ");
    let flat: String = if flat.chars().count() > 2000 { flat.chars().take(2000).chain("…".chars()).collect() } else { flat };
    format!("{stamp} [{level}] {flat}\n")
}

/// A crash still leaves a line saying where it happened, so the next report shows it.
pub fn install_panic_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let payload = info.payload();
        let message = payload.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| payload.downcast_ref::<String>().cloned()).unwrap_or_else(|| "unknown problem".into());
        let place = info.location().map(|l| format!(" at {}:{}", l.file(), l.line())).unwrap_or_default();
        write("panic", &format!("{message}{place}"), false);
        previous(info);
    }));
}

/// The last `n` lines of the log, the older file first.
fn recent_log(n: usize) -> String {
    let Some(dir) = LOG_DIR.get() else { return String::new() };
    let mut text = std::fs::read_to_string(dir.join("still.log.1")).unwrap_or_default();
    text.push_str(&std::fs::read_to_string(dir.join("still.log")).unwrap_or_default());
    last_lines(&text, n)
}
fn last_lines(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

// ---- What goes in a report ----------------------------------------------------------------------

/// Whether a setting's name says it holds something private: an API key, a token, a password.
fn is_secret(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    ["key", "token", "secret", "password"].iter().any(|word| name.contains(word))
}
/// Settings that hold the user's own words or folders: the report says only whether they're set.
const PERSONAL: [&str; 3] = ["exportFolder", "watermark.text", "watermark.image"];

/// The settings as a report shows them: anything secret left out, personal text and folders shown only as set or not.
fn report_settings(values: &Value) -> Value { redact(values, "") }
fn redact(value: &Value, path: &str) -> Value {
    if PERSONAL.contains(&path) {
        let set = match value { Value::String(s) => !s.trim().is_empty(), Value::Null => false, _ => true };
        return Value::String(if set { "(set)".into() } else { "(not set)".into() });
    }
    match value {
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                // The AI settings only ever say which service is used: anything else under them is left out.
                if is_secret(k) || (path == "ai" && k != "provider") { continue; }
                let child = if path.is_empty() { k.clone() } else { format!("{path}.{k}") };
                out.insert(k.clone(), redact(v, &child));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

/// Encodes text for a web address: letters, digits and - _ . ~ stay as they are, everything else becomes %XX.
fn encode(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { out.push(b as char); } else { out.push_str(&format!("%{b:02X}")); }
    }
    out
}

/// The page that starts a new issue, with a title to finish and the questions that make a report useful. The log
/// stays out of the address: it goes in the report file the user looks over and attaches.
fn issue_url(version: &str, system: &str) -> String {
    let body = format!("**What happened**\n\n\n**What you expected**\n\n\n**Steps to make it happen**\n1. \n2. \n3. \n\n**System**\nStill {version} on {system}\n\nThe problem report Still saved on your computer (Still problem report … .txt) has more detail: look it over, then drag it here to attach it.\n");
    format!("{ISSUES}?title={}&body={}", encode("Problem: "), encode(&body))
}

/// The distribution's own name for itself, from /etc/os-release, e.g. "Ubuntu 24.04.1 LTS".
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn pretty_name(os_release: &str) -> Option<String> {
    os_release.lines().find_map(|l| l.strip_prefix("PRETTY_NAME=")).map(|v| v.trim().trim_matches('"').to_string()).filter(|v| !v.is_empty())
}

/// The system's name and version and the processor type, e.g. "Windows 11 Pro 23H2 (build 22631), x86_64".
pub fn system() -> String {
    format!("{}, {}", os_name(), std::env::consts::ARCH)
}
fn os_name() -> String {
    #[cfg(windows)] {
        use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
        let wide = |s: &str| s.encode_utf16().chain(std::iter::once(0)).collect::<Vec<u16>>();
        let key = wide(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
        let read = |name: &str| -> String {
            let name = wide(name);
            let mut data = [0u16; 256];
            let mut size = (data.len() * 2) as u32;
            let status = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), data.as_mut_ptr().cast(), &mut size) };
            if status != 0 { return String::new(); }
            let len = data.iter().position(|c| *c == 0).unwrap_or(data.len());
            String::from_utf16_lossy(&data[..len]).trim().to_string()
        };
        let (product, release, build) = (read("ProductName"), read("DisplayVersion"), read("CurrentBuildNumber"));
        // Windows 11 still names itself Windows 10 here; its build numbers start at 22000.
        let product = if build.parse::<u32>().map(|b| b >= 22000).unwrap_or(false) { product.replace("Windows 10", "Windows 11") } else { product };
        let product = if product.is_empty() { "Windows".to_string() } else { product };
        let release = if release.is_empty() { String::new() } else { format!(" {release}") };
        let build = if build.is_empty() { String::new() } else { format!(" (build {build})") };
        return format!("{product}{release}{build}");
    }
    #[cfg(target_os = "linux")] {
        let name = std::fs::read_to_string("/etc/os-release").ok().and_then(|t| pretty_name(&t)).unwrap_or_else(|| "Linux".into());
        let kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease").map(|k| k.trim().to_string()).unwrap_or_default();
        return if kernel.is_empty() { name } else { format!("{name} (kernel {kernel})") };
    }
    #[allow(unreachable_code)]
    std::env::consts::OS.to_string()
}

/// How Still's windows reach the screen on Linux, where Wayland and X11 behave very differently.
fn session() -> Option<String> {
    if !cfg!(target_os = "linux") { return None; }
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").ok().filter(|d| !d.is_empty()).map(|d| format!(", {d}")).unwrap_or_default();
    Some(match (crate::is_wayland(), crate::wayland_windows()) {
        (true, true) => format!("Wayland{desktop}"),
        (true, false) => format!("Wayland, Still's windows on X11{desktop}"),
        _ => format!("X11{desktop}"),
    })
}

/// Each display: its size in pixels, its scale and where it sits, e.g. "2560×1440 at 150%, at 0,0 (main)".
fn displays(app: &AppHandle) -> Vec<String> {
    let primary = app.primary_monitor().ok().flatten().map(|m| (*m.position(), *m.size()));
    app.available_monitors().unwrap_or_default().iter().map(|m| {
        let (size, scale) = (m.size(), m.scale_factor());
        let main = if primary == Some((*m.position(), *size)) { " (main)" } else { "" };
        format!("{}×{} at {}%, at {},{}{main}", size.width, size.height, (scale * 100.0).round(), m.position().x, m.position().y)
    }).collect()
}

/// The line logged as Still starts: which version, on what, with which displays.
pub fn log_start(app: &AppHandle) {
    let shown = displays(app);
    let session = session().map(|s| format!("; {s}")).unwrap_or_default();
    log("info", &format!("Still {} started on {}{session}; {} display(s): {}", app.package_info().version, system(), shown.len(), shown.join("; ")));
}

fn report_text(app: &AppHandle) -> String {
    let version = app.package_info().version.to_string();
    let shown = displays(app);
    let (screenshots, recordings) = { let lib = crate::st(app).library.lock().unwrap(); let r = lib.items.iter().filter(|i| i.kind == "recording").count(); (lib.items.len() - r, r) };
    let settings = report_settings(&crate::st(app).settings.lock().unwrap().values);
    let recorder = match crate::record::available() { Ok(()) => "Still's own recorder".to_string(), Err(reason) => format!("the system web engine ({reason})") };
    let mut out = String::new();
    out.push_str("Still problem report\n");
    out.push_str(&format!("Made {}\n\n", chrono::Local::now().format("%Y-%m-%d %H:%M:%S (UTC%:z)")));
    out.push_str("Still hasn't sent this anywhere. Look it over, then attach it to your report if you're happy with what's in it.\n");
    out.push_str("It has no screenshots, recordings, clipboard text or API keys in it.\n\n");
    out.push_str(&format!("Still: {version}\nSystem: {}\n", system()));
    if let Some(s) = session() { out.push_str(&format!("Session: {s}\n")); }
    out.push_str(&format!("Displays: {}\n", shown.len()));
    for (i, d) in shown.iter().enumerate() { out.push_str(&format!("  {}. {d}\n", i + 1)); }
    out.push_str(&format!("Records with: {recorder}\nClicks and keys can be shown: {}\n", if crate::marks::available() { "yes" } else { "no" }));
    out.push_str(&format!("Capture History: {screenshots} screenshot(s), {recordings} recording(s)\n\n"));
    out.push_str("Settings (API keys, folders and your own text left out):\n");
    out.push_str(&serde_json::to_string_pretty(&settings).unwrap_or_default());
    out.push_str(&format!("\n\nRecent log (last {REPORT_LINES} lines):\n"));
    let log = recent_log(REPORT_LINES);
    out.push_str(if log.is_empty() { "(nothing logged yet)" } else { &log });
    out.push('\n');
    out
}

/// Saves the report to the Desktop (or the export folder when there's no Desktop to save to), shows it in the file
/// manager and opens the page to describe the problem. Returns where the report went.
pub fn report(app: &AppHandle) -> Result<PathBuf, String> {
    let text = report_text(app);
    let name = crate::library::capture_name("Still problem report");
    let desktop = app.path().desktop_dir().ok().filter(|d| d.is_dir());
    let mut saved = Err("No folder to save the report in.".to_string());
    for folder in desktop.into_iter().chain(std::iter::once_with(|| crate::export_folder(app))) {
        let file = crate::unique_path(&folder, &name, "txt");
        saved = std::fs::write(&file, &text).map(|_| file).map_err(|e| format!("Couldn’t save the problem report: {e}"));
        if saved.is_ok() { break; }
    }
    let file = saved?;
    log("info", "Problem report saved");
    crate::reveal(&file);
    crate::open_url(&issue_url(&app.package_info().version.to_string(), &system()));
    Ok(file)
}

/// Settings → About → Report a Problem…: returns the report's file name for the page to show.
#[tauri::command]
pub async fn report_problem(app: AppHandle) -> Result<String, String> {
    let file = crate::blocking(move || report(&app)).await?;
    Ok(file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default())
}

/// For the tray item, which has no page to show a result in.
pub fn report_from_menu(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || { if let Err(e) = report(&app) { crate::notify(&app, "Couldn’t make a problem report", &e); } });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn secrets_and_personal_text_stay_out_of_reports() {
        let settings = json!({
            "theme": "dark", "apiKey": "sk-123", "ai": { "provider": "claude", "key": "abc", "model": "x" }, "authToken": "t", "Password": "p", "clientSecret": "s",
            "exportFolder": "/home/sam/Pictures", "watermark": { "kind": "text", "text": "© Sam", "image": "", "opacity": 0.7 },
            "recording": { "fps": 30, "keys": true }, "shortcuts": { "area": "CommandOrControl+Shift+4" }
        });
        let shown = report_settings(&settings);
        assert_eq!(shown["theme"], "dark");
        for gone in ["apiKey", "authToken", "Password", "clientSecret"] { assert!(shown.get(gone).is_none(), "{gone}"); }
        assert_eq!(shown["ai"], json!({ "provider": "claude" }));
        assert_eq!(shown["exportFolder"], "(set)");
        assert_eq!(shown["watermark"]["text"], "(set)");
        assert_eq!(shown["watermark"]["image"], "(not set)");
        assert_eq!(shown["watermark"]["opacity"], 0.7);
        assert_eq!(shown["recording"], json!({ "fps": 30 }));
        assert_eq!(shown["shortcuts"]["area"], "CommandOrControl+Shift+4");
        assert!(!serde_json::to_string(&shown).unwrap().contains("Sam"));
    }

    #[test]
    fn the_issue_address_is_fully_encoded() {
        let url = issue_url("1.2.60", "Windows 11 Pro (build 22631), x86_64");
        assert!(url.starts_with("https://github.com/ImSammyTTV/Still/issues/new?title=Problem%3A%20&body="));
        let body = url.split("&body=").nth(1).unwrap();
        assert!(body.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.~%".contains(&b)), "{body}");
        assert!(body.contains("Still%201.2.60%20on%20Windows%2011%20Pro%20%28build%2022631%29%2C%20x86_64"));
        assert!(body.contains("%2A%2AWhat%20happened%2A%2A%0A"));
        assert_eq!(encode("a&b=c/d é"), "a%26b%3Dc%2Fd%20%C3%A9");
    }

    #[test]
    fn log_lines_are_single_lines_and_recognised_text_is_not_kept() {
        assert_eq!(line("2026-11-22 10:00:00.000", "error", "Couldn’t save\n  the file"), "2026-11-22 10:00:00.000 [error] Couldn’t save the file\n");
        assert!(line("t", "info", &"x".repeat(5000)).chars().count() < 2100);
        assert_eq!(notice_text("Text copied", "My bank PIN is 1234"), "Text copied");
        assert_eq!(notice_text("Capture failed", "The capture overlay couldn’t be opened."), "Capture failed: The capture overlay couldn’t be opened.");
        assert_eq!(last_lines("a\nb\nc\n", 2), "b\nc");
        assert_eq!(last_lines("a", 5), "a");
        assert_eq!(pretty_name("NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n").as_deref(), Some("Ubuntu 24.04.1 LTS"));
        assert_eq!(pretty_name("NAME=Arch"), None);
    }
}
