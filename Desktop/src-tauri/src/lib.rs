mod capture;
mod cloud;
mod combine;
mod desktop;
mod drive;
mod library;
mod marks;
mod previous;
mod qr;
mod record;
mod scroll;
mod settings;
mod video;

use capture::Grab;
use image::RgbaImage;
use library::{Item, Library};
use serde_json::{json, Value};
use settings::Settings;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::menu::{IconMenuItem, IconMenuItemBuilder, Menu, MenuBuilder, SubmenuBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::webview::{PermissionKind, PermissionResponse};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_notification::NotificationExt;

// ---- State ------------------------------------------------------------------------------------

/// Where the running recording is on the desktop, for the windows that float over it.
#[derive(Clone, Copy)]
struct Recorded { area: marks::Area, display: marks::Area, scale: f64 }

#[derive(Default)]
struct Session {
    busy: bool,
    purpose: String,
    grabs: Vec<Grab>,
    overlays: Vec<String>,
    /// Hidden overlay pages that have loaded and are waiting for a capture.
    warm: Vec<String>,
    /// The pre-warmed page that has just been given a screen and hasn't answered yet.
    handing: Option<String>,
    from_shortcut: bool,
    previews: Vec<(String, String)>,
    recording: Option<Value>,
    recorded: Option<Recorded>,
    /// The container of the recording being written chunk by chunk, and when it started, so that a recording whose
    /// controls stop answering can still be saved with a sensible name and duration.
    recording_ext: String,
    recording_began: Option<std::time::Instant>,
    /// Still's own recorder, when it is the one recording (Windows). Held outside any work done under this lock:
    /// stopping it waits for the video file to be finished.
    recorder: Option<Arc<record::Handle>>,
    marks: Option<marks::Options>,
    listener: Option<marks::Listener>,
    /// The pointer's path and clicks for the video editor's zooms, kept with the recording when it's saved.
    trail: Option<marks::Trail>,
    /// The last share link made, offered as a QR code from the tray.
    last_link: Option<String>,
    /// Still's own recorder is leaving the pointer out, for the video editor to draw from the trail.
    cursor_separate: bool,
    failed_shortcuts: Vec<String>,
    update: Value,
    pending_update: Option<Arc<tauri_plugin_updater::Update>>,
    selftest: Option<PathBuf>,
    stop_item: Option<IconMenuItem<tauri::Wry>>,
    export_targets: HashMap<String, PathBuf>,
    scroll: Option<Arc<scroll::Control>>,
    /// Keeps the desktop icons hidden for as long as a recording runs.
    icons: Option<desktop::Hidden>,
    /// QR scans waiting for the text from their OCR page, by page.
    qr: std::collections::HashMap<String, std::sync::mpsc::Receiver<Vec<String>>>,
}

fn occupied(s: &Session) -> bool { s.busy || s.recording.is_some() || s.scroll.is_some() }

struct State { settings: Mutex<Settings>, library: Mutex<Library>, session: Mutex<Session> }

fn st(app: &AppHandle) -> &State { app.state::<State>().inner() }

/// Still's own temporary folder: screen grabs, OCR input and drag files go here rather than the shared
/// system temp folder, readable only by this account (0700 on Linux), and emptied at start and exit.
static PRIVATE_TEMP: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
fn private_temp() -> PathBuf { PRIVATE_TEMP.get().cloned().unwrap_or_else(std::env::temp_dir) }
fn init_private_temp(cache: PathBuf) {
    let dir = cache.join("still-tmp");
    let _ = std::fs::create_dir_all(&dir);
    #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)); }
    let _ = PRIVATE_TEMP.set(dir);
}
fn clear_private_temp() {
    if let Ok(entries) = std::fs::read_dir(private_temp()) { for e in entries.flatten() { let _ = std::fs::remove_file(e.path()); } }
}

fn setting(app: &AppHandle, path: &str) -> Value { st(app).settings.lock().unwrap().get(path).clone() }
fn notify(app: &AppHandle, title: &str, body: &str) { let _ = app.notification().builder().title(title).body(body).show(); }
fn broadcast(app: &AppHandle, event: &str, payload: Value) { let _ = app.emit(event, payload); }
fn platform() -> &'static str { if cfg!(windows) { "win32" } else if cfg!(target_os = "macos") { "darwin" } else { "linux" } }
fn is_wayland() -> bool { cfg!(target_os = "linux") && std::env::var("XDG_SESSION_TYPE").map(|v| v == "wayland").unwrap_or(false) && std::env::var("DISPLAY").is_err() }

// ---- Windows ----------------------------------------------------------------------------------

fn builder<'a>(app: &'a AppHandle, label: &str, page: &str, params: Value) -> WebviewWindowBuilder<'a, tauri::Wry, AppHandle> {
    let script = format!("window.__STILL_PARAMS__ = {}; window.__STILL_PLATFORM__ = {:?};", params, platform());
    WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into())).initialization_script(script).visible(false)
}

/// Settings, History and the editor use Windows' Acrylic glass (see-through and blurred) behind a translucent page. Elsewhere the
/// window stays solid (Linux has no system glass; on Windows 10 Mica is ignored and the page background shows).
fn glass<'a>(builder: WebviewWindowBuilder<'a, tauri::Wry, AppHandle>) -> WebviewWindowBuilder<'a, tauri::Wry, AppHandle> {
    #[cfg(windows)] { return builder.transparent(true).effects(tauri::window::EffectsBuilder::new().effect(tauri::window::Effect::Acrylic).build()); }
    #[allow(unreachable_code)] builder
}

/// Brings a capture overlay to the front with keyboard focus. Windows refuses focus to a process that didn't receive
/// the last input, and a global shortcut counts as input for the app that was in front, so without this the overlay
/// appears but Escape, Enter and the arrows keep going to that app. A synthetic tap of Alt earns the right to focus.
fn take_focus(win: &WebviewWindow) {
    #[cfg(windows)] {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{keybd_event, KEYEVENTF_KEYUP, VK_MENU};
        unsafe { keybd_event(VK_MENU as u8, 0, 0, 0); keybd_event(VK_MENU as u8, 0, KEYEVENTF_KEYUP, 0); }
    }
    let _ = win.set_focus();
}

/// While an overlay is open, Escape cancels the capture even if the overlay never got keyboard focus.
/// The shortcut lives only as long as the selection: end_selection removes it.
fn watch_escape(app: &AppHandle) {
    let _ = app.global_shortcut().on_shortcut("Escape", |app, _shortcut, event| {
        if event.state != ShortcutState::Pressed { return; }
        let app = app.clone();
        // Off the handler's thread, so removing the shortcut inside end_selection never waits on the handler itself.
        std::thread::spawn(move || {
            if st(&app).session.lock().unwrap().busy { end_selection(&app); } else { let _ = app.global_shortcut().unregister("Escape"); }
        });
    });
}

fn focus_or<F: FnOnce() -> Option<WebviewWindow>>(app: &AppHandle, label: &str, make: F) -> Option<WebviewWindow> {
    if let Some(w) = app.get_webview_window(label) { let _ = w.show(); let _ = w.unminimize(); let _ = w.set_focus(); return Some(w); }
    let w = make()?;
    let _ = w.show(); let _ = w.set_focus();
    Some(w)
}

fn open_settings(app: &AppHandle, page: Option<&str>) {
    let params = json!({ "page": page.unwrap_or("") });
    if let Some(w) = focus_or(app, "settings", || glass(builder(app, "settings", "settings.html", params)).title("Still Settings").inner_size(760.0, 600.0).min_inner_size(700.0, 540.0).decorations(false).build().ok()) {
        if let Some(p) = page { let _ = w.emit("settings:page", p); }
    }
}
/// A share link as a QR code, to open on a phone by pointing its camera at the screen.
fn show_qr(app: &AppHandle, link: &str) {
    if let Some(w) = app.get_webview_window("qr") { let _ = w.destroy(); }
    let _ = glass(builder(app, "qr", "qr.html", json!({ "link": link }))).title("Open on Phone").inner_size(340.0, 440.0).resizable(false).decorations(false).always_on_top(true).build();
}
#[tauri::command]
async fn qr_svg(link: String) -> Result<String, String> { qr::svg(&link) }
/// History's "Upload and Show QR Code": the share link, and then its code.
#[tauri::command]
async fn library_qr(app: AppHandle, id: String) -> Result<(), String> {
    let link = upload_item(&app, &id).await?;
    if !link.starts_with("http") { return Err("This destination has no share link to show.".into()); }
    let a = app.clone();
    let _ = app.run_on_main_thread(move || show_qr(&a, &link));
    Ok(())
}
fn open_history(app: &AppHandle) {
    focus_or(app, "history", || glass(builder(app, "history", "history.html", json!({}))).title("Capture History").inner_size(980.0, 660.0).min_inner_size(640.0, 420.0).decorations(false).build().ok());
}
fn open_editor(app: &AppHandle, id: Option<&str>, recognize: bool) {
    let label = format!("editor-{}", id.unwrap_or("demo"));
    let title = id.and_then(|i| st(app).library.lock().unwrap().get(i)).map(|i| i.title).unwrap_or_else(|| "Still — Annotate".into());
    close_preview(app, id.unwrap_or(""));
    // Fit the editor inside the work area of the screen the pointer is on.
    let (w, h) = app.cursor_position().ok().and_then(|p| app.monitor_from_point(p.x, p.y).ok().flatten()).or_else(|| app.primary_monitor().ok().flatten())
        .map(|m| { let a = m.work_area(); let s = m.scale_factor(); ((a.size.width as f64 / s - 40.0).min(1180.0), (a.size.height as f64 / s - 40.0).min(800.0)) })
        .unwrap_or((1180.0, 800.0));
    focus_or(app, &label, || glass(builder(app, &label, "editor.html", json!({ "id": id.unwrap_or(""), "demo": if id.is_none() { "1" } else { "0" }, "recognize": if recognize { "1" } else { "0" } })))
        .title(title).inner_size(w, h).min_inner_size(w.min(900.0), h.min(520.0)).decorations(false).center().build().ok());
}

/// Recordings open here rather than in the image editor.
fn open_video(app: &AppHandle, id: &str) {
    let label = format!("video-{id}");
    let title = st(app).library.lock().unwrap().get(id).map(|i| i.title).unwrap_or_else(|| "Still — Trim Video".into());
    close_preview(app, id);
    focus_or(app, &label, || glass(builder(app, &label, "video.html", json!({ "id": id }))).title(title).inner_size(960.0, 700.0).min_inner_size(720.0, 560.0).decorations(false).center().build().ok());
}

// ---- Floating Preview -------------------------------------------------------------------------------

fn preview_size(app: &AppHandle) -> (f64, f64) {
    match setting(app, "quickAccess.size").as_str() { Some("small") => (250.0, 160.0), Some("large") => (340.0, 236.0), _ => (290.0, 196.0) }
}

fn layout_previews(app: &AppHandle) {
    let Ok(pos) = app.cursor_position() else { return };
    let Some(monitor) = app.monitor_from_point(pos.x, pos.y).ok().flatten().or_else(|| app.primary_monitor().ok().flatten()) else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let (w, h) = preview_size(app);
    let (pw, ph) = ((w * scale) as i32, (h * scale) as i32);
    let left = setting(app, "quickAccess.side").as_str() != Some("right");
    let mut y = area.position.y + area.size.height as i32 - ph - (16.0 * scale) as i32;
    let previews = st(app).session.lock().unwrap().previews.clone();
    for (label, _) in previews {
        if let Some(win) = app.get_webview_window(&label) {
            let x = if left { area.position.x + (16.0 * scale) as i32 } else { area.position.x + area.size.width as i32 - pw - (16.0 * scale) as i32 };
            let _ = win.set_size(PhysicalSize::new(pw as u32, ph as u32));
            let _ = win.set_position(PhysicalPosition::new(x, y));
            y -= ph + (12.0 * scale) as i32;
        }
    }
}

fn show_preview(app: &AppHandle, item: &Item, sound: bool) {
    let label = format!("quick-{}", uuid::Uuid::new_v4().simple());
    let (w, h) = preview_size(app);
    let sound = sound && setting(app, "playSounds").as_bool().unwrap_or(true);
    let built = builder(app, &label, "quick.html", json!({ "id": item.id, "sound": if sound { "1" } else { "0" } }))
        .title("Floating Preview").inner_size(w, h).decorations(false).transparent(true).shadow(false).resizable(false)
        .always_on_top(true).skip_taskbar(true).focusable(false).focused(false).visible_on_all_workspaces(true).build();
    let Ok(win) = built else { return };
    {
        let mut s = st(app).session.lock().unwrap();
        s.previews.insert(0, (label.clone(), item.id.clone()));
        while s.previews.len() > 5 { if let Some((old, _)) = s.previews.pop() { if let Some(w) = app.get_webview_window(&old) { let _ = w.close(); } } }
    }
    layout_previews(app);
    let _ = win.show();
    let handle = app.clone();
    win.on_window_event(move |e| if let tauri::WindowEvent::Destroyed = e {
        handle.state::<State>().session.lock().unwrap().previews.retain(|(l, _)| l != &label);
        layout_previews(&handle);
    });
}

fn close_preview(app: &AppHandle, id: &str) {
    let labels: Vec<String> = st(app).session.lock().unwrap().previews.iter().filter(|(_, i)| i == id).map(|(l, _)| l.clone()).collect();
    for l in labels { if let Some(w) = app.get_webview_window(&l) { let _ = w.close(); } }
}

/// Returns whether there was anything to hide or show.
fn hide_floating(app: &AppHandle, hidden: bool) -> bool {
    let mut any = false;
    for (label, win) in app.webview_windows() {
        if label.starts_with("quick-") || label.starts_with("pin-") { let _ = if hidden { win.hide() } else { win.show() }; any = true; }
    }
    any
}

// ---- Capture ------------------------------------------------------------------------------------

fn overlay_window<'a>(app: &'a AppHandle, label: &str, params: Value) -> WebviewWindowBuilder<'a, tauri::Wry, AppHandle> {
    builder(app, label, "overlay.html", params).title("Capture Selection").decorations(false).resizable(false)
        .always_on_top(true).skip_taskbar(true).shadow(false).visible_on_all_workspaces(true)
}
fn place_overlay(win: &WebviewWindow, g: &Grab) {
    let (w, h) = g.image.dimensions();
    let _ = win.set_position(PhysicalPosition::new(g.x, g.y));
    let _ = win.set_size(PhysicalSize::new(w, h));
}

/// Starting a webview is the slowest part of opening the overlay, so one page per display is loaded ahead of time and
/// waits hidden. Each is used once, for one capture, then replaced.
static WARMING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
fn warm_overlays(app: &AppHandle) {
    use std::sync::atomic::Ordering::Relaxed;
    if WARMING.swap(true, Relaxed) { return; }
    let app = app.clone();
    std::thread::spawn(move || {
        // Let the windows of the capture that just ended go first, and stay out of the way of saving it.
        std::thread::sleep(Duration::from_millis(500));
        let waiting = { let s = st(&app).session.lock().unwrap(); app.webview_windows().keys().filter(|l| l.starts_with("overlay-warm-") && !s.overlays.contains(l)).count() };
        for m in app.available_monitors().unwrap_or_default().iter().skip(waiting) {
            if st(&app).session.lock().unwrap().busy { break; }
            let label = format!("overlay-warm-{}", uuid::Uuid::new_v4().simple());
            if let Ok(win) = overlay_window(&app, &label, json!({})).build() {
                let _ = win.set_position(*m.position());
                let _ = win.set_size(*m.size());
            }
        }
        WARMING.store(false, Relaxed);
    });
}

/// Gives a waiting page this display. A page can't be trusted just because it loaded earlier, so it has to answer;
/// if it doesn't, the capture goes on with a fresh page rather than leaving a blank window over the screen.
fn warm_overlay(app: &AppHandle, g: &Grab, init: &Value) -> Option<(String, WebviewWindow)> {
    let label = { let mut s = st(app).session.lock().unwrap(); let label = s.warm.pop()?; s.handing = Some(label.clone()); label };
    let win = app.get_webview_window(&label);
    if let Some(win) = &win {
        place_overlay(win, g);
        let mut init = init.clone();
        init["warm"] = json!(true);
        let _ = app.emit_to(label.as_str(), "overlay:init", init);
        for _ in 0..150 {
            if st(app).session.lock().unwrap().handing.is_none() { return Some((label, win.clone())); }
            std::thread::sleep(Duration::from_millis(2));
        }
        // On the main thread, and finished before going on: a webview destroyed from here while another is being built can leave both stuck.
        let doomed = win.clone();
        let _ = app.run_on_main_thread(move || { let _ = doomed.destroy(); });
        for _ in 0..50 { if app.get_webview_window(&label).is_none() { break; } std::thread::sleep(Duration::from_millis(2)); }
    }
    st(app).session.lock().unwrap().handing = None;
    None
}

fn start_selection(app: &AppHandle, purpose: &str, delay: u64, window_mode: bool) {
    let from_shortcut = {
        let mut s = st(app).session.lock().unwrap();
        if occupied(&s) { drop(s); notify(app, "Still", "Finish the current capture or recording first."); return; }
        s.busy = true; s.purpose = purpose.to_string();
        s.from_shortcut
    };
    let app = app.clone();
    let purpose = purpose.to_string();
    std::thread::spawn(move || {
        if delay > 0 && !countdown(&app, delay) { end_selection(&app); return; }
        let floating = hide_floating(&app, true);
        // The overlay shows a frozen picture, so the icons only need to be gone for the grab itself.
        let _icons = desktop::hide(&app);
        // Floating windows take a moment to leave the screen, and so does a tray menu or the desktop icons. A shortcut with nothing to clear has nothing to wait for.
        if floating || !from_shortcut || _icons.is_some() { std::thread::sleep(Duration::from_millis(80)); }
        let grabs = match capture::grab_all() { Ok(g) => g, Err(e) => { end_selection(&app); notify(&app, "Capture failed", &e); return; } };
        let factor = grabs.first().map(|g| g.factor).unwrap_or(1.0);
        let windows = if purpose == "screenshot" || purpose == "record" { capture::list_windows(factor) } else { vec![] };
        let cursor = app.cursor_position().unwrap_or(PhysicalPosition::new(0.0, 0.0));
        let last = setting(&app, "lastSelection");
        let remember = setting(&app, "rememberSelection").as_bool().unwrap_or(false);
        let temp = private_temp();
        // All at once, so a second display doesn't add to the wait.
        let pictures: Vec<Vec<u8>> = std::thread::scope(|scope| {
            let jobs: Vec<_> = grabs.iter().map(|g| scope.spawn(|| capture::jpeg(&g.image, 90))).collect();
            jobs.into_iter().map(|job| job.join().unwrap_or_default()).collect()
        });
        let mut labels = Vec::new();
        let mut focused: Option<WebviewWindow> = None;
        for (i, g) in grabs.iter().enumerate() {
            let file = temp.join(format!("still-overlay-{}-{}.jpg", std::process::id(), i));
            let _ = std::fs::write(&file, &pictures[i]);
            let (w, h) = g.image.dimensions();
            let mine: Vec<Value> = windows.iter().filter(|r| r.x < (g.x + w as i32) as f64 && r.y < (g.y + h as i32) as f64 && r.x + r.w > g.x as f64 && r.y + r.h > g.y as f64)
                .map(|r| json!({ "id": r.id, "x": r.x - g.x as f64, "y": r.y - g.y as f64, "w": r.w, "h": r.h })).collect();
            let under_cursor = cursor.x >= g.x as f64 && cursor.x < (g.x + w as i32) as f64 && cursor.y >= g.y as f64 && cursor.y < (g.y + h as i32) as f64;
            let init = json!({
                "displayId": g.id, "purpose": purpose, "windowMode": window_mode && !mine.is_empty(), "canSelectWindows": !mine.is_empty(), "wayland": is_wayland(), "canScroll": scroll::supported(),
                "imagePath": file, "imageWidth": w, "imageHeight": h, "windows": mine,
                "crosshair": setting(&app, "crosshair"), "magnifier": setting(&app, "magnifier"),
                "last": if remember && last["displayId"] == json!(g.id) { last["rect"].clone() } else { Value::Null },
                "primary": under_cursor || (i == 0 && !grabs.iter().any(|o| { let (ow, oh) = o.image.dimensions(); cursor.x >= o.x as f64 && cursor.x < (o.x + ow as i32) as f64 && cursor.y >= o.y as f64 && cursor.y < (o.y + oh as i32) as f64 }))
            });
            let (label, built) = match warm_overlay(&app, g, &init) {
                Some((label, win)) => (label, Ok(win)),
                None => {
                    let label = format!("overlay-{i}");
                    if let Some(old) = app.get_webview_window(&label) { let _ = old.destroy(); }
                    let built = overlay_window(&app, &label, json!({ "init": init })).build();
                    if let Ok(win) = &built { place_overlay(win, g); }
                    (label, built)
                }
            };
            if let Ok(win) = built {
                let _ = win.show();
                if under_cursor { take_focus(&win); focused = Some(win.clone()); }
                labels.push(label);
            }
        }
        // The page may not be ready for keys on the first try; a second attempt a moment later is cheap.
        if let Some(win) = focused { std::thread::sleep(Duration::from_millis(60)); let _ = win.set_focus(); }
        watch_escape(&app);
        let mut s = st(&app).session.lock().unwrap();
        s.grabs = grabs; s.overlays = labels;
    });
}

/// Set by a click on the countdown, which calls the timed capture off.
static COUNTDOWN_CANCELLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The countdown before a timed capture: a large number in the middle of the screen the pointer is on, so it's clear
/// the capture is coming and when. Runs on the capture's own thread and answers whether it ran to the end. The window
/// is gone before the screen is grabbed, so it is never in the picture.
fn countdown(app: &AppHandle, seconds: u64) -> bool {
    use std::sync::atomic::Ordering;
    COUNTDOWN_CANCELLED.store(false, Ordering::SeqCst);
    let a = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = a.get_webview_window("countdown") { let _ = w.destroy(); }
        let Ok(win) = builder(&a, "countdown", "countdown.html", json!({ "seconds": seconds })).title("Capture Countdown").inner_size(180.0, 180.0)
            .decorations(false).transparent(true).shadow(false).resizable(false).always_on_top(true).skip_taskbar(true).focused(false).visible_on_all_workspaces(true).build() else { return };
        let monitor = a.cursor_position().ok().and_then(|p| a.monitor_from_point(p.x, p.y).ok().flatten()).or_else(|| a.primary_monitor().ok().flatten());
        if let Some(m) = monitor {
            let side = (180.0 * m.scale_factor()) as i32;
            let _ = win.set_position(PhysicalPosition::new(m.position().x + (m.size().width as i32 - side) / 2, m.position().y + (m.size().height as i32 - side) / 2));
        }
        let _ = win.show();
    });
    for _ in 0..seconds * 10 {
        if COUNTDOWN_CANCELLED.load(Ordering::SeqCst) { break; }
        std::thread::sleep(Duration::from_millis(100));
    }
    let a = app.clone();
    let _ = app.run_on_main_thread(move || { if let Some(w) = a.get_webview_window("countdown") { let _ = w.destroy(); } });
    if COUNTDOWN_CANCELLED.load(Ordering::SeqCst) { return false; }
    // A moment for the window to leave the screen before it's grabbed.
    std::thread::sleep(Duration::from_millis(150));
    true
}
#[tauri::command]
async fn countdown_cancel() { COUNTDOWN_CANCELLED.store(true, std::sync::atomic::Ordering::SeqCst); }

fn end_selection(app: &AppHandle) {
    let _ = app.global_shortcut().unregister("Escape");
    let labels = { let mut s = st(app).session.lock().unwrap(); s.busy = false; s.grabs.clear(); std::mem::take(&mut s.overlays) };
    // The overlay's frozen pictures of every screen aren't needed once the selection is over.
    for i in 0..16 { let _ = std::fs::remove_file(private_temp().join(format!("still-overlay-{}-{}.jpg", std::process::id(), i))); }
    for l in labels { if let Some(w) = app.get_webview_window(&l) { let _ = w.destroy(); } }
    hide_floating(app, false);
    warm_overlays(app);
}

fn finish_selection(app: &AppHandle, payload: Value) {
    let display = payload["displayId"].as_u64().unwrap_or(0) as u32;
    let purpose = payload["purpose"].as_str().unwrap_or("screenshot").to_string();
    let px = &payload["px"];
    let (x, y, w, h) = (px["x"].as_f64().unwrap_or(0.0), px["y"].as_f64().unwrap_or(0.0), px["w"].as_f64().unwrap_or(0.0), px["h"].as_f64().unwrap_or(0.0));
    let grab = {
        let mut s = st(app).session.lock().unwrap();
        let grabs = std::mem::take(&mut s.grabs);
        grabs.into_iter().find(|g| g.id == display)
    };
    end_selection(app);
    let Some(grab) = grab else { return };
    if w < 2.0 || h < 2.0 { return; }
    if setting(app, "rememberSelection").as_bool().unwrap_or(false) && payload["windowId"].is_null() {
        st(app).settings.lock().unwrap().update(&json!({ "lastSelection": { "displayId": display, "rect": payload["rect"] } }));
    }
    previous::remember(app, &payload, &grab);
    if purpose == "record" { start_recording(app, &grab, x, y, w, h, !payload["windowId"].is_null()); return; }
    if purpose == "scroll" { scroll::start(app, &grab, x, y, w, h); return; }
    let image = capture::crop(&grab.image, x, y, w, h);
    complete_image(app, image, purpose == "text");
}

fn capture_fullscreen(app: &AppHandle) {
    {
        let mut s = st(app).session.lock().unwrap();
        if occupied(&s) { return; }
        s.busy = true;
    }
    hide_floating(app, true);
    let icons = desktop::hide(app);
    std::thread::sleep(Duration::from_millis(120));
    let result = capture::grab_all();
    drop(icons);
    { st(app).session.lock().unwrap().busy = false; }
    hide_floating(app, false);
    match result {
        Ok(grabs) => {
            let cursor = app.cursor_position().unwrap_or(PhysicalPosition::new(0.0, 0.0));
            let mut chosen = None;
            for g in grabs { let (w, h) = g.image.dimensions(); let hit = cursor.x >= g.x as f64 && cursor.x < (g.x + w as i32) as f64 && cursor.y >= g.y as f64 && cursor.y < (g.y + h as i32) as f64; if hit || chosen.is_none() { chosen = Some(g.image); if hit { break; } } }
            if let Some(image) = chosen { complete_image(app, image, false); }
        }
        Err(e) => notify(app, "Capture failed", &e),
    }
}

fn encode(app: &AppHandle, image: &RgbaImage) -> (Vec<u8>, &'static str) {
    if setting(app, "imageFormat").as_str() == Some("jpg") { (capture::jpeg(image, setting(app, "jpegQuality").as_u64().unwrap_or(90) as u8), "jpg") } else { (capture::png(image), "png") }
}

fn copy_image(app: &AppHandle, image: &RgbaImage) -> Result<(), String> {
    let (w, h) = image.dimensions();
    app.clipboard().write_image(&tauri::image::Image::new_owned(image.as_raw().clone(), w, h)).map_err(|e| e.to_string())
}

fn complete_image(app: &AppHandle, image: RgbaImage, text: bool) {
    if text { recognize_file(app, &image); return; }
    let (w, h) = image.dimensions();
    // None of these depend on each other, so the Floating Preview waits only for the slowest.
    let ((bytes, ext), copied, thumb) = std::thread::scope(|scope| {
        let copied = scope.spawn(|| if setting(app, "afterCapture.copy").as_bool().unwrap_or(true) { copy_image(app, &image) } else { Ok(()) });
        let thumb = scope.spawn(|| if w.max(h) > capture::THUMB_MAX { Some(capture::thumbnail(&image)) } else { None });
        (encode(app, &image), copied.join().unwrap_or(Ok(())), thumb.join().unwrap_or(None))
    });
    if let Err(e) = copied { notify(app, "Couldn’t copy the screenshot", &e); }
    let item = {
        let mut lib = st(app).library.lock().unwrap();
        match lib.add(&bytes, "screenshot", ext, None, w, h) {
            Ok(item) => { if let Some((small, kind)) = thumb { lib.store_thumb(&item, &small, kind); } item }
            Err(e) => { drop(lib); notify(app, "Couldn’t save the screenshot", &e); return; }
        }
    };
    if setting(app, "afterCapture.save").as_bool().unwrap_or(false) { if let Err(e) = export_item(app, &item.id, None) { notify(app, "Couldn’t save to your folder", &e); } }
    if setting(app, "cloud.autoUpload").as_bool().unwrap_or(false) { let (a, id) = (app.clone(), item.id.clone()); tauri::async_runtime::spawn(async move { let _ = upload_item(&a, &id).await; }); }
    if setting(app, "afterCapture.annotate").as_bool().unwrap_or(false) { open_editor(app, Some(&item.id), false); }
    else if setting(app, "afterCapture.quickAccess").as_bool().unwrap_or(true) { show_preview(app, &item, true); }
    broadcast(app, "library:changed", Value::Null);
}

/// OCR runs in a hidden page (the engine is WebAssembly); it reports back through `ocr_result`.
fn recognize_file(app: &AppHandle, image: &RgbaImage) {
    let file = private_temp().join(format!("still-ocr-{}.png", uuid::Uuid::new_v4().simple()));
    let _ = std::fs::write(&file, capture::png(image));
    let label = format!("ocr-{}", uuid::Uuid::new_v4().simple());
    let (found, scan) = std::sync::mpsc::channel();
    let picture = image.clone();
    std::thread::spawn(move || { let _ = found.send(qr::read(&picture)); });
    st(app).session.lock().unwrap().qr.insert(label.clone(), scan);
    let _ = builder(app, &label, "ocr.html", json!({ "file": file })).title("Still OCR").inner_size(200.0, 100.0).skip_taskbar(true).build();
}

fn export_folder(app: &AppHandle) -> PathBuf {
    let custom = st(app).settings.lock().unwrap().str("exportFolder");
    // Unless a folder was chosen in Settings, saves go to Documents/Still.
    let folder = if custom.is_empty() { app.path().document_dir().or_else(|_| app.path().home_dir()).map(|d| d.join("Still")).unwrap_or_else(|_| std::env::temp_dir()) } else { PathBuf::from(custom) };
    let _ = std::fs::create_dir_all(&folder);
    folder
}
fn unique_path(folder: &Path, name: &str, ext: &str) -> PathBuf {
    let clean: String = name.chars().map(|c| if "\\/:*?\"<>|".contains(c) { '-' } else { c }).collect();
    let mut file = folder.join(format!("{clean}.{ext}"));
    let mut n = 2;
    while file.exists() { file = folder.join(format!("{clean} ({n}).{ext}")); n += 1; }
    file
}
fn export_item(app: &AppHandle, id: &str, target: Option<PathBuf>) -> Result<PathBuf, String> {
    let lib = st(app).library.lock().unwrap();
    let item = lib.get(id).ok_or("That capture no longer exists.")?;
    let src = lib.file(&item);
    let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("png").to_string();
    drop(lib);
    let file = target.unwrap_or_else(|| unique_path(&export_folder(app), &item.title, &ext));
    std::fs::copy(src, &file).map_err(|e| format!("Couldn’t save to {}: {e}", file.display()))?;
    Ok(file)
}

// ---- Recording ----------------------------------------------------------------------------------

/// The HUD records with the system web engine's screen capture, crops to the selection and sends the file back.
fn start_recording(app: &AppHandle, grab: &Grab, x: f64, y: f64, w: f64, h: f64, selected_window: bool) {
    let (iw, ih) = grab.image.dimensions();
    let rec = setting(app, "recording");
    let native = native_engine(&rec);
    let params = json!({ "rect": { "x": x, "y": y, "w": w, "h": h }, "imageWidth": iw, "imageHeight": ih, "selectedWindow": selected_window, "options": rec,
        "stopShortcut": setting(app, "shortcuts")["record"], "native": native.is_ok(), "nativeWhy": native.err() });
    let scale = app.monitor_from_point(grab.x as f64 + 1.0, grab.y as f64 + 1.0).ok().flatten().map(|m| m.scale_factor()).unwrap_or(1.0);
    {
        let mut s = st(app).session.lock().unwrap();
        s.recording = Some(params.clone());
        s.recorded = Some(Recorded { area: marks::Area { x: grab.x as f64 + x, y: grab.y as f64 + y, w, h }, display: marks::Area { x: grab.x as f64, y: grab.y as f64, w: iw as f64, h: ih as f64 }, scale });
    }
    let _ = std::fs::remove_file(recording_part(app)); // Never let a previous recording's leftovers lead this one.
    let built = builder(app, "hud", "hud.html", params).title("Recording").inner_size(300.0, 52.0).decorations(false).transparent(true).shadow(false)
        .always_on_top(true).skip_taskbar(true).resizable(false).content_protected(true).on_permission_request(hud_access).build();
    if let Ok(hud) = built {
        media_on(&hud);
        let icons = desktop::hide(app);
        st(app).session.lock().unwrap().icons = icons;
        let _ = hud.set_position(PhysicalPosition::new(grab.x + (iw as f64 / 2.0 - 150.0 * scale) as i32, grab.y + ih as i32 - (90.0 * scale) as i32));
        let _ = hud.show(); let _ = hud.set_focus();
    }
    build_tray_menu(app);
}

/// Windows can close without going through their normal IPC (Alt+F4, a crashed page). Put the app back in
/// a working state when that happens instead of leaving capture or shortcuts stuck.
fn window_gone(app: &AppHandle, label: &str) {
    match label {
        // Closing Settings while recording a shortcut would otherwise leave every shortcut unregistered.
        "settings" => register_shortcuts(app),
        "hud" => {
            end_recording_extras(app);
            // The controls went away mid-recording (Alt+F4, a crashed page): keep what was recorded up to then.
            if st(app).session.lock().unwrap().recorder.is_some() { let a = app.clone(); std::thread::spawn(move || { let _ = finish_native(&a); }); }
            else if st(app).session.lock().unwrap().recording.is_some() { salvage_recording(app); }
        }
        // Never keep watching the keyboard with nothing on screen to show for it.
        "marks" => { let listener = { let mut s = st(app).session.lock().unwrap(); s.marks = None; s.listener.take() }; drop(listener); }
        _ if label.starts_with("video-") => { st(app).session.lock().unwrap().export_targets.remove(label); }
        "scroll" => scroll::stop(app, false),
        // A page that was only waiting, or that never answered, isn't part of the selection on screen.
        _ if label.starts_with("overlay-warm-") && !st(app).session.lock().unwrap().overlays.iter().any(|l| l == label) => {}
        _ if label.starts_with("overlay-") => {
            let still_open = st(app).session.lock().unwrap().overlays.iter().any(|l| l != label && app.get_webview_window(l).is_some());
            if !still_open && st(app).session.lock().unwrap().busy { end_selection(app); }
        }
        _ => {}
    }
}
/// Whether Still records by itself rather than through the web engine: on Windows, when the computer supports it,
/// the user hasn't chosen the web engine, and no audio is wanted (Still's recorder doesn't record sound yet).
/// Whether Still's own recorder makes this recording, and if not, why: the reason goes into any error the web
/// engine reports, so a failed recording says which recorder failed.
fn native_engine(rec: &Value) -> Result<(), String> {
    if !cfg!(windows) { return Err("Still’s own recorder is Windows-only.".into()) }
    if rec["engine"].as_str() == Some("webview") { return Err("Settings → Recording → Record with is set to the system recorder.".into()) }
    record::available()
}

fn stop_recording_state(app: &AppHandle) {
    end_recording_extras(app);
    let (recorder, trail) = { let mut s = st(app).session.lock().unwrap(); s.recording = None; s.icons = None; s.cursor_separate = false; (s.recorder.take(), s.trail.take()) };
    drop(trail);
    if let Some(recorder) = recorder { recorder.cancel(); } // Only reached by a recording that ended without being saved.
    if let Some(h) = app.get_webview_window("hud") { let _ = h.close(); }
    build_tray_menu(app);
}

// ---- Camera bubble, clicks and keys -------------------------------------------------------------
//
// These are ordinary windows floating over the screen, so the screen capture records them where they overlap
// the selection. The HUD is the only window kept out of the video (content_protected), so neither of these
// may be protected, and the keys only ever exist on screen and in that video.

/// WebKitGTK has no permission prompt of its own: it says no to everything Still doesn't answer, and it ships
/// with media capture switched off (see `media_on`). The user asked for the recording, so say yes here.
/// WebView2 keeps its own prompts for the HUD.
fn hud_access(_: tauri::Webview, kind: PermissionKind) -> PermissionResponse {
    if cfg!(target_os = "linux") && matches!(kind, PermissionKind::DisplayCapture | PermissionKind::Microphone) { PermissionResponse::Allow } else { PermissionResponse::Default }
}
/// Turning the bubble on in Settings is the consent. A prompt would have to appear inside a small round window
/// that can't take focus, mid-recording; the operating system's own camera privacy switch still applies.
fn camera_access(_: tauri::Webview, kind: PermissionKind) -> PermissionResponse {
    if matches!(kind, PermissionKind::Camera) { PermissionResponse::Allow } else { PermissionResponse::Deny }
}
fn media_on(window: &WebviewWindow) {
    #[cfg(target_os = "linux")] {
        let _ = window.with_webview(|view| {
            use webkit2gtk::{SettingsExt, WebViewExt};
            if let Some(settings) = WebViewExt::settings(&view.inner()) { settings.set_enable_media_stream(true); }
        });
    }
    #[cfg(not(target_os = "linux"))] let _ = window;
}

fn open_camera(app: &AppHandle, place: Recorded) {
    let size = marks::bubble_size(setting(app, "recording.cameraSize").as_f64());
    let shape = if setting(app, "recording.cameraShape").as_str() == Some("rounded") { "rounded" } else { "circle" };
    let built = builder(app, "camera", "camera.html", json!({ "shape": shape })).title("Camera").inner_size(size, size).decorations(false).transparent(true).shadow(false).resizable(false)
        .always_on_top(true).skip_taskbar(true).focusable(false).focused(false).visible_on_all_workspaces(true).on_permission_request(camera_access).build();
    let Ok(win) = built else { notify(app, "Camera bubble is off", "Still couldn’t open the camera window. The recording continues without it."); return };
    media_on(&win);
    let (x, y) = marks::bubble_origin(place.area, place.display, size * place.scale, 24.0 * place.scale);
    let _ = win.set_position(PhysicalPosition::new(x, y));
    let _ = win.show();
}

/// One click-through window over the recorded area, for both the ripples and the keys.
fn open_marks(app: &AppHandle, place: Recorded) {
    let options = marks::Options { area: place.area, clicks: setting(app, "recording.clicks").as_bool().unwrap_or(false), keys: setting(app, "recording.keys").as_bool().unwrap_or(false),
        shortcuts_only: setting(app, "recording.keysShortcutsOnly").as_bool().unwrap_or(true) };
    if !options.clicks && !options.keys { return; }
    if !marks::available() { notify(app, "Clicks and keys are off", "Wayland doesn’t let apps see clicks or keys in other windows. Sign in to an X11 session to show them."); return; }
    let (w, h) = (place.area.w, place.area.h);
    let built = builder(app, "marks", "marks.html", json!({})).title("Clicks and Keys").inner_size(w / place.scale, h / place.scale).decorations(false).transparent(true).shadow(false).resizable(false)
        .always_on_top(true).skip_taskbar(true).focusable(false).focused(false).visible_on_all_workspaces(true).build();
    let Ok(win) = built else { notify(app, "Clicks and keys are off", "Still couldn’t open the overlay window. The recording continues without it."); return };
    let _ = win.set_position(PhysicalPosition::new(place.area.x as i32, place.area.y as i32));
    let _ = win.set_size(PhysicalSize::new(w as u32, h as u32));
    let _ = win.show();
    let _ = win.set_ignore_cursor_events(true); // GTK needs the window on screen for this.
    st(app).session.lock().unwrap().marks = Some(options);
}

/// Only runs while the recording does: the page starts it after the countdown and stops it on pause and stop.
fn start_listening(app: &AppHandle) {
    let options = {
        let s = st(app).session.lock().unwrap();
        if s.recording.is_none() || s.listener.is_some() { return; }
        let Some(options) = s.marks else { return };
        options
    };
    let a = app.clone();
    let started = marks::listen(options, move |mark| {
        let _ = match mark {
            marks::Mark::Click { x, y } => a.emit_to("marks", "marks:click", json!({ "x": x, "y": y })),
            marks::Mark::Keys(text) => a.emit_to("marks", "marks:keys", text),
        };
    });
    match started {
        // If the recording ended while this started, dropping the listener here stops it.
        Ok(listener) => { let mut s = st(app).session.lock().unwrap(); if s.marks.is_some() { s.listener = Some(listener); } }
        Err(e) => {
            st(app).session.lock().unwrap().marks = None;
            if let Some(w) = app.get_webview_window("marks") { let _ = w.destroy(); }
            notify(app, "Clicks and keys are off", &format!("Still couldn’t watch for them ({e}). The recording continues without them."));
        }
    }
}

/// The one way out for all of it, whichever way the recording ended. Dropping the listener stops it.
fn end_recording_extras(app: &AppHandle) {
    let listener = { let mut s = st(app).session.lock().unwrap(); s.recorded = None; s.marks = None; s.listener.take() };
    drop(listener);
    for label in ["marks", "camera"] { if let Some(w) = app.get_webview_window(label) { let _ = w.destroy(); } }
}

// ---- Tray, shortcuts ----------------------------------------------------------------------------

const ACTIONS: [(&str, &str); 10] = [("allInOne", "Capture Bar"), ("area", "Capture Area"), ("window", "Capture Window"), ("fullscreen", "Capture Fullscreen"),
    ("previous", "Capture Previous Area"), ("scrolling", "Scrolling Capture"),
    ("text", "Capture Text (OCR)"), ("record", "Record Screen"), ("history", "Open Capture History"), ("restore", "Restore Last Capture")];

fn run_action(app: &AppHandle, action: &str) {
    match action {
        "area" | "allInOne" => start_selection(app, "screenshot", 0, false),
        "window" => start_selection(app, "screenshot", 0, true),
        "fullscreen" => { let a = app.clone(); std::thread::spawn(move || capture_fullscreen(&a)); }
        "previous" => { let a = app.clone(); std::thread::spawn(move || previous::capture_again(&a)); }
        "scrolling" => {
            if scroll::active(app) { scroll::stop(app, true); }
            else if scroll::supported() { start_selection(app, "scroll", 0, false); }
            else { notify(app, "Still", "Scrolling capture needs an X11 session."); }
        }
        "text" => start_selection(app, "text", 0, false),
        "record" => {
            if st(app).session.lock().unwrap().recording.is_some() { request_stop(app); }
            else { start_selection(app, "record", 0, false) }
        }
        "history" => open_history(app),
        "restore" => { let item = st(app).library.lock().unwrap().items.iter().find(|i| i.kind != "recording").cloned(); if let Some(i) = item { show_preview(app, &i, false); } }
        _ => {}
    }
}

fn register_shortcuts(app: &AppHandle) {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    let shortcuts = setting(app, "shortcuts");
    let mut failed = Vec::new();
    for (action, _) in ACTIONS {
        let Some(accel) = shortcuts[action].as_str().filter(|s| !s.is_empty()) else { continue };
        let action = action.to_string();
        let ok = gs.on_shortcut(accel, move |app, _shortcut, event| {
            if event.state == ShortcutState::Pressed {
                st(app).session.lock().unwrap().from_shortcut = true;
                run_action(app, &action);
                st(app).session.lock().unwrap().from_shortcut = false;
            }
        });
        if ok.is_err() { failed.push(action_key(accel, &shortcuts)); }
    }
    st(app).session.lock().unwrap().failed_shortcuts = failed.clone();
    broadcast(app, "shortcuts:status", json!(failed));
}
fn action_key(accel: &str, shortcuts: &Value) -> String {
    ACTIONS.iter().find(|(a, _)| shortcuts[*a].as_str() == Some(accel)).map(|(a, _)| a.to_string()).unwrap_or_default()
}

fn build_tray_menu(app: &AppHandle) {
    let Some(tray) = app.tray_by_id("still") else { return };
    if let Ok(menu) = tray_menu(app) { let _ = tray.set_menu(Some(menu)); }
    if st(app).session.lock().unwrap().recording.is_none() { let _ = tray.set_tooltip(Some("Still")); let _ = tray.set_title(None::<&str>); }
}

/// The running time, wherever the platform can show it: the tooltip on Windows, the title next to the icon on
/// Linux (where the panel supports it) and the Stop item on both.
fn show_recording_time(app: &AppHandle, seconds: u64, paused: bool) {
    let stop = { let s = st(app).session.lock().unwrap(); if s.recording.is_none() { return; } s.stop_item.clone() };
    let (menu, tooltip) = video::tray_status(seconds, paused);
    if let Some(tray) = app.tray_by_id("still") { let _ = tray.set_tooltip(Some(tooltip)); let _ = tray.set_title(Some(format!(" {}", video::clock(seconds)))); }
    if let Some(stop) = stop { let _ = stop.set_text(menu); }
}

/// The tray shows a plain ripple glyph, like other menu bar and tray icons: white on a dark taskbar or
/// panel, black on a light Windows taskbar.
fn tray_icon() -> tauri::image::Image<'static> {
    let light = cfg!(windows) && windows_light_taskbar();
    let bytes: &'static [u8] = if light { include_bytes!("../icons/tray-black.png") } else { include_bytes!("../icons/tray-white.png") };
    tauri::image::Image::from_bytes(bytes).expect("tray icon")
}
/// Windows stores the taskbar's theme in SystemUsesLightTheme (1 = light).
fn windows_light_taskbar() -> bool {
    #[cfg(windows)] {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        if let Ok(out) = std::process::Command::new("reg").args(["query", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "/v", "SystemUsesLightTheme"]).creation_flags(CREATE_NO_WINDOW).output() {
            return String::from_utf8_lossy(&out.stdout).contains("0x1");
        }
    }
    false
}
/// Small grey icons for the tray menu, drawn from the same Lucide set the windows use.
fn menu_icon(name: &str) -> Option<tauri::image::Image<'static>> {
    let bytes: &'static [u8] = match name {
        "allInOne" => include_bytes!("../icons/menu/allInOne.png"), "area" => include_bytes!("../icons/menu/area.png"),
        "window" => include_bytes!("../icons/menu/window.png"), "fullscreen" => include_bytes!("../icons/menu/fullscreen.png"),
        "timer" => include_bytes!("../icons/menu/timer.png"), "text" => include_bytes!("../icons/menu/text.png"),
        "previous" => include_bytes!("../icons/menu/previous.png"), "scrolling" => include_bytes!("../icons/menu/scrolling.png"),
        "record" => include_bytes!("../icons/menu/record.png"), "open" => include_bytes!("../icons/menu/open.png"),
        "history" => include_bytes!("../icons/menu/history.png"), "restore" => include_bytes!("../icons/menu/restore.png"),
        "unlock" => include_bytes!("../icons/menu/unlock.png"), "close" => include_bytes!("../icons/menu/close.png"),
        "update" => include_bytes!("../icons/menu/update.png"), "settings" => include_bytes!("../icons/menu/settings.png"),
        "quit" => include_bytes!("../icons/menu/quit.png"), "stop" => include_bytes!("../icons/menu/stop.png"), _ => return None,
    };
    tauri::image::Image::from_bytes(bytes).ok()
}

fn tray_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let s = setting(app, "shortcuts");
    let accel = |a: &str| s[a].as_str().filter(|x| !x.is_empty()).map(|x| x.to_string());
    let item = |id: &str, title: &str, icon: &str, shortcut: Option<String>, enabled: bool| {
        let mut b = IconMenuItemBuilder::with_id(id, title).enabled(enabled);
        if let Some(i) = menu_icon(icon) { b = b.icon(i); }
        if let Some(a) = shortcut { b = b.accelerator(a); }
        b.build(app)
    };
    let recording = st(app).session.lock().unwrap().recording.is_some();
    let last_link = st(app).session.lock().unwrap().last_link.is_some();
    let scrolling = scroll::active(app);
    let update = st(app).session.lock().unwrap().update.clone();
    let mut timers = SubmenuBuilder::new(app, "Timed Capture");
    if let Some(icon) = menu_icon("timer") { timers = timers.submenu_icon(icon); }
    let timers = timers
        .item(&item("timer-3", "Capture Area in 3 Seconds", "timer", None, true)?)
        .item(&item("timer-5", "Capture Area in 5 Seconds", "timer", None, true)?)
        .item(&item("timer-10", "Capture Area in 10 Seconds", "timer", None, true)?).build()?;
    let update_item = match update["state"].as_str() {
        Some("available") => item("update-install", &format!("Update to {}…", update["version"].as_str().unwrap_or("")), "update", None, true)?,
        Some("downloading") => item("update-busy", "Downloading Update…", "update", None, false)?,
        _ => item("update-check", "Check for Updates…", "update", None, true)?,
    };
    let stop = if recording { Some(item("record", "Stop Recording", "stop", accel("record"), true)?) } else { None };
    st(app).session.lock().unwrap().stop_item = stop.clone();
    let mut menu = MenuBuilder::new(app);
    if let Some(stop) = &stop { menu = menu.item(stop).separator(); }
    menu = menu
        .item(&item("allInOne", "Capture Bar", "allInOne", accel("allInOne"), true)?).separator()
        .item(&item("area", "Capture Area", "area", accel("area"), true)?)
        .item(&item("window", "Capture Window", "window", accel("window"), true)?)
        .item(&item("fullscreen", "Capture Fullscreen", "fullscreen", accel("fullscreen"), true)?)
        .item(&item("previous", "Capture Previous Area", "previous", accel("previous"), true)?)
        .item(&item("scrolling", if scrolling { "Finish Scrolling Capture" } else { "Scrolling Capture" }, "scrolling", accel("scrolling"), true)?)
        .item(&timers)
        .item(&item("text", "Capture Text (OCR)", "text", accel("text"), true)?);
    if !recording { menu = menu.item(&item("record", "Record Screen", "record", accel("record"), true)?); }
    menu.separator()
        .item(&item("open-image", "Open Image…", "open", None, true)?)
        .item(&item("last-link-qr", "Show Last Link as QR Code", "open", None, last_link)?)
        .item(&item("history", "Capture History", "history", accel("history"), true)?)
        .item(&item("restore", "Restore Last Capture", "restore", accel("restore"), true)?)
        .item(&item("unlock-pins", "Unlock Pinned Screenshots", "unlock", None, true)?)
        .item(&item("close-overlays", "Close All Overlays", "close", None, true)?)
        .separator().item(&update_item)
        .item(&item("settings", "Settings…", "settings", None, true)?)
        .item(&item("quit", "Quit Still", "quit", None, true)?)
        .build()
}

fn on_menu(app: &AppHandle, id: &str) {
    match id {
        "settings" => open_settings(app, None),
        "quit" => app.exit(0),
        "open-image" => import_image(app),
        "last-link-qr" => { let link = st(app).session.lock().unwrap().last_link.clone(); if let Some(link) = link { show_qr(app, &link); } }
        "unlock-pins" => for (l, w) in app.webview_windows() { if l.starts_with("pin-") { let _ = w.set_ignore_cursor_events(false); } },
        "close-overlays" => for (l, w) in app.webview_windows() { if l.starts_with("pin-") || l.starts_with("quick-") { let _ = w.close(); } },
        "update-check" => check_update(app, true),
        "update-install" => install_update(app),
        t if t.starts_with("timer-") => start_selection(app, "screenshot", t[6..].parse().unwrap_or(5), false),
        action => run_action(app, action),
    }
}

fn import_image(app: &AppHandle) {
    let app = app.clone();
    app.clone().dialog().file().add_filter("Images", &["png", "jpg", "jpeg"]).pick_file(move |file| {
        let Some(path) = file.and_then(|f| f.into_path().ok()) else { return };
        open_image_file(&app, &path, ImageUse::Edit);
    });
}

/// What to do with an image file from outside Still: the right-click menu on Windows, "Open With" on Linux,
/// `still --open=… / --text=… / --pin=…`, or Open Image… in the menu.
#[derive(Clone, Copy, PartialEq, Debug)]
enum ImageUse { Edit, Text, Pin }

/// The image file and what to do with it, if the arguments name one: `--open=`, `--text=` or `--pin=` with a path,
/// or a bare path to a PNG or JPEG, which is how "Open With" passes it. The first argument is the program itself.
fn image_argument(args: &[String]) -> Option<(PathBuf, ImageUse)> {
    for (flag, using) in [("--open=", ImageUse::Edit), ("--text=", ImageUse::Text), ("--pin=", ImageUse::Pin)] {
        if let Some(path) = args.iter().find_map(|a| a.strip_prefix(flag)) { return Some((PathBuf::from(path), using)); }
    }
    let image = |a: &&String| !a.starts_with('-') && ["png", "jpg", "jpeg"].iter().any(|ext| a.to_lowercase().ends_with(&format!(".{ext}")));
    args.iter().skip(1).find(image).map(|path| (PathBuf::from(path), ImageUse::Edit))
}

fn open_image_file(app: &AppHandle, path: &Path, using: ImageUse) {
    let Some(image) = std::fs::read(path).ok().and_then(|b| capture::decode(&b)) else { notify(app, "Still", &format!("{} could not be opened as an image.", path.display())); return };
    match using {
        ImageUse::Text => recognize_file(app, &image),
        ImageUse::Pin => pin_image(app, &image),
        ImageUse::Edit => {
            let (w, h) = image.dimensions();
            let title = path.file_stem().map(|s| s.to_string_lossy().to_string());
            let item = match st(app).library.lock().unwrap().add(&capture::png(&image), "screenshot", "png", title, w, h) {
                Ok(item) => item, Err(e) => { notify(app, "Couldn’t add the image", &e); return; }
            };
            open_editor(app, Some(&item.id), false);
            broadcast(app, "library:changed", Value::Null);
        }
    }
}

fn apply_login_item(app: &AppHandle) {
    use tauri_plugin_autostart::ManagerExt;
    let enabled = setting(app, "launchAtLogin").as_bool().unwrap_or(false);
    let _ = if enabled { app.autolaunch().enable() } else { app.autolaunch().disable() };
}

// ---- Updates ------------------------------------------------------------------------------------

fn set_update(app: &AppHandle, status: Value) {
    st(app).session.lock().unwrap().update = status.clone();
    broadcast(app, "update:status", status);
    build_tray_menu(app);
}

fn check_update(app: &AppHandle, manual: bool) {
    use tauri_plugin_updater::UpdaterExt;
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        set_update(&app, json!({ "state": "checking" }));
        let result = match app.updater() { Ok(u) => u.check().await.map_err(|e| e.to_string()), Err(e) => Err(e.to_string()) };
        match result {
            Ok(Some(update)) => {
                let version = update.version.clone();
                st(&app).session.lock().unwrap().pending_update = Some(Arc::new(update));
                set_update(&app, json!({ "state": "available", "version": version }));
                show_update_prompt(&app, &version);
            }
            Ok(None) => { set_update(&app, json!({ "state": "current" })); if manual { notify(&app, "Still", &format!("You’re up to date (version {}).", app.package_info().version)); } }
            Err(e) => { set_update(&app, json!({ "state": "error", "error": e })); if manual { notify(&app, "Couldn’t check for updates", &e); } }
        }
    });
}

/// A small card in the corner (Windows notifications can't report clicks back to the app).
fn show_update_prompt(app: &AppHandle, version: &str) {
    if app.get_webview_window("update").is_some() { return; }
    let (app, version) = (app.clone(), version.to_string());
    let a = app.clone();
    let _ = app.run_on_main_thread(move || {
        let Some(monitor) = a.primary_monitor().ok().flatten() else { return };
        let (scale, area) = (monitor.scale_factor(), *monitor.work_area());
        let (w, h) = (348.0, 132.0);
        let built = builder(&a, "update", "update.html", json!({ "version": version, "current": a.package_info().version.to_string() }))
            .title("Still update").inner_size(w, h).decorations(false).transparent(true).shadow(false).resizable(false)
            .always_on_top(true).skip_taskbar(true).focusable(false).focused(false).build();
        if let Ok(win) = built {
            let x = area.position.x + area.size.width as i32 - ((w + 16.0) * scale) as i32;
            let y = area.position.y + area.size.height as i32 - ((h + 16.0) * scale) as i32;
            let _ = win.set_position(PhysicalPosition::new(x, y));
            let _ = win.show();
        }
    });
}

fn install_update(app: &AppHandle) {
    let Some(update) = st(app).session.lock().unwrap().pending_update.clone() else { return };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        set_update(&app, json!({ "state": "downloading", "version": update.version }));
        let (progress_app, version) = (app.clone(), update.version.clone());
        let received = std::sync::atomic::AtomicU64::new(0);
        let last = std::sync::atomic::AtomicU64::new(0);
        let on_chunk = move |chunk: usize, total: Option<u64>| {
            let done = received.fetch_add(chunk as u64, std::sync::atomic::Ordering::Relaxed) + chunk as u64;
            if let Some(total) = total.filter(|t| *t > 0) {
                let percent = done * 100 / total;
                if percent != last.swap(percent, std::sync::atomic::Ordering::Relaxed) {
                    let status = json!({ "state": "downloading", "version": version, "progress": percent });
                    progress_app.state::<State>().session.lock().unwrap().update = status.clone();
                    let _ = progress_app.emit("update:status", status);
                }
            }
        };
        match update.download_and_install(on_chunk, || {}).await {
            Ok(()) => app.restart(),
            Err(e) => { set_update(&app, json!({ "state": "error", "error": e.to_string() })); notify(&app, "Update failed", &e.to_string()); }
        }
    });
}

// ---- Commands -----------------------------------------------------------------------------------

#[tauri::command]
async fn settings_get(app: AppHandle) -> Value {
    let mut v = st(&app).settings.lock().unwrap().values.clone();
    let s = st(&app).session.lock().unwrap();
    v["platform"] = json!(platform());
    v["version"] = json!(app.package_info().version.to_string());
    v["failedShortcuts"] = json!(s.failed_shortcuts);
    v["wayland"] = json!(is_wayland());
    v["globalInput"] = json!(marks::available());
    v
}
#[tauri::command]
async fn settings_set(app: AppHandle, patch: Value) -> Value {
    let values = st(&app).settings.lock().unwrap().update(&patch);
    after_settings(&app, &patch);
    values
}
#[tauri::command]
async fn settings_reset(app: AppHandle, key: String) -> Value {
    let values = st(&app).settings.lock().unwrap().reset(&key);
    after_settings(&app, &json!({ key: true }));
    values
}
/// Hands Settings → File names to the library, which names new captures.
fn apply_name_pattern(app: &AppHandle) {
    let pattern = setting(app, "fileName").as_str().filter(|p| !p.trim().is_empty()).unwrap_or(library::DEFAULT_NAME).to_string();
    st(app).library.lock().unwrap().name_pattern = pattern;
}
/// Settings → General → Keep history: applied now, and again after every new capture.
fn apply_history_days(app: &AppHandle) {
    let days = setting(app, "historyDays").as_u64().unwrap_or(0).min(3650) as u32;
    let removed = { let mut lib = st(app).library.lock().unwrap(); lib.keep_days = days; lib.prune(library::now_ms()) };
    for id in &removed { close_preview(app, id); }
    if !removed.is_empty() { broadcast(app, "library:changed", Value::Null); }
}
fn after_settings(app: &AppHandle, patch: &Value) {
    if patch.get("fileName").is_some() { apply_name_pattern(app); }
    if patch.get("historyDays").is_some() { apply_history_days(app); }
    if patch.get("shortcuts").is_some() { register_shortcuts(app); }
    if patch.get("launchAtLogin").is_some() { apply_login_item(app); }
    if patch.get("quickAccess").is_some() { layout_previews(app); }
    build_tray_menu(app);
    let values = st(app).settings.lock().unwrap().values.clone();
    broadcast(app, "settings:changed", values);
}
#[tauri::command]
async fn settings_choose_folder(app: AppHandle) -> Option<String> {
    let folder = app.dialog().file().blocking_pick_folder()?.into_path().ok()?;
    let path = folder.to_string_lossy().to_string();
    settings_set(app, json!({ "exportFolder": path })).await;
    Some(path)
}
#[tauri::command]
async fn shortcuts_pause(app: AppHandle, paused: bool) { if paused { let _ = app.global_shortcut().unregister_all(); } else { register_shortcuts(&app); } }

#[tauri::command]
async fn overlay_done(app: AppHandle, payload: Value) { let a = app.clone(); std::thread::spawn(move || finish_selection(&a, payload)); }
#[tauri::command]
async fn overlay_cancel(app: AppHandle) { end_selection(&app); }
#[tauri::command]
async fn overlay_fullscreen(app: AppHandle, display_id: u32) {
    let grab = { let mut s = st(&app).session.lock().unwrap(); std::mem::take(&mut s.grabs).into_iter().find(|g| g.id == display_id) };
    end_selection(&app);
    if let Some(g) = grab { complete_image(&app, g.image, false); }
}
#[tauri::command]
async fn overlay_timer(app: AppHandle, delay: u64) {
    let purpose = st(&app).session.lock().unwrap().purpose.clone();
    end_selection(&app);
    start_selection(&app, &purpose, delay, false);
}
#[tauri::command]
async fn overlay_purpose(app: AppHandle, purpose: String) {
    st(&app).session.lock().unwrap().purpose = purpose.clone();
    broadcast(&app, "overlay:purpose", json!(purpose));
}
#[tauri::command]
async fn overlay_window_mode(app: AppHandle, on: bool) { broadcast(&app, "overlay:windowMode", json!(on)); }
/// A waiting page reports in twice: once when it has loaded, and again when it has been given a screen.
#[tauri::command]
async fn overlay_ready(app: AppHandle, window: tauri::Window) {
    let mut s = st(&app).session.lock().unwrap();
    let label = window.label().to_string();
    if s.handing.as_deref() == Some(label.as_str()) { s.handing = None; } else { s.warm.push(label); }
}
/// A colour picked in the capture overlay: copied as #RRGGBB and kept at the front of the recent colours that the
/// editor offers.
#[tauri::command]
async fn overlay_color(app: AppHandle, hex: String) -> Result<(), String> {
    let valid = hex.len() == 7 && hex.starts_with('#') && hex[1..].chars().all(|c| c.is_ascii_hexdigit());
    if !valid { return Err("That isn’t a colour.".into()); }
    let hex = hex.to_uppercase();
    let _ = app.clipboard().write_text(hex.clone());
    let recent: Vec<Value> = setting(&app, "recentColors").as_array().cloned().unwrap_or_default();
    let mut list = vec![json!(hex)];
    list.extend(recent.into_iter().filter(|c| c.as_str().map(|s| !s.eq_ignore_ascii_case(&hex)).unwrap_or(false)).take(9));
    st(&app).settings.lock().unwrap().update(&json!({ "recentColors": list }));
    Ok(())
}
#[tauri::command]
async fn overlay_pointer(app: AppHandle, window: tauri::Window) {
    for l in st(&app).session.lock().unwrap().overlays.iter() { if l != window.label() { let _ = app.emit_to(l.as_str(), "overlay:clear", ()); } }
}

fn item_json(lib: &Library, item: &Item) -> Value {
    let mut v = serde_json::to_value(item).unwrap_or(Value::Null);
    v["path"] = json!(lib.file(item));
    v["original"] = json!(lib.original(item));
    v["thumb"] = json!(lib.thumb(item));
    v
}

/// Makes one capture's thumbnail and hands it to History if it's open.
fn make_thumb(app: &AppHandle, item: &Item) {
    let file = st(app).library.lock().unwrap().file(item);
    let Some(image) = std::fs::read(file).ok().and_then(|b| capture::decode(&b)) else { return };
    let (bytes, ext) = capture::thumbnail(&image);
    let stored = st(app).library.lock().unwrap().store_thumb(item, &bytes, ext);
    if let Some(thumb) = stored { let _ = app.emit_to("history", "library:thumb", json!({ "id": item.id, "thumb": thumb })); }
}
/// Fills in thumbnails for captures from before they existed, one at a time and away from any window. History shows
/// the full picture for these until theirs arrives.
static BACKFILLING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
fn backfill_thumbs(app: &AppHandle) {
    use std::sync::atomic::Ordering::Relaxed;
    if BACKFILLING.swap(true, Relaxed) { return; }
    let app = app.clone();
    std::thread::spawn(move || {
        let items = st(&app).library.lock().unwrap().missing_thumbs();
        for item in &items { make_thumb(&app, item); }
        BACKFILLING.store(false, Relaxed);
    });
}
#[tauri::command]
async fn library_list(app: AppHandle, query: Value) -> Vec<Value> {
    let list = { let lib = st(&app).library.lock().unwrap(); lib.search(query["query"].as_str().unwrap_or(""), query["kind"].as_str().unwrap_or("all")).iter().map(|i| item_json(&lib, i)).collect() };
    backfill_thumbs(&app);
    list
}
#[tauri::command]
async fn library_get(app: AppHandle, id: String) -> Value {
    let lib = st(&app).library.lock().unwrap();
    match lib.get(&id) { Some(item) => { let mut v = item_json(&lib, &item); v["project"] = lib.project(&id).unwrap_or(Value::Null); v } None => Value::Null }
}
#[tauri::command]
async fn library_rename(app: AppHandle, id: String, title: String) { st(&app).library.lock().unwrap().update(&id, |i| i.title = title); broadcast(&app, "library:changed", Value::Null); }
/// Stars a capture in History, or takes the star off.
#[tauri::command]
async fn library_star(app: AppHandle, id: String, starred: bool) { st(&app).library.lock().unwrap().update(&id, |i| i.starred = starred); broadcast(&app, "library:changed", Value::Null); }
#[tauri::command]
async fn library_delete(app: AppHandle, id: String) { close_preview(&app, &id); st(&app).library.lock().unwrap().remove(&id); broadcast(&app, "library:changed", Value::Null); }
#[tauri::command]
async fn library_copy(app: AppHandle, id: String) -> Result<(), String> {
    let (file, kind) = { let lib = st(&app).library.lock().unwrap(); let item = lib.get(&id).ok_or("Missing capture")?; (lib.file(&item), item.kind) };
    if kind == "recording" { return app.clipboard().write_text(file.to_string_lossy().to_string()).map_err(|e| e.to_string()); }
    let image = std::fs::read(&file).ok().and_then(|b| capture::decode(&b)).ok_or("Couldn’t read the capture")?;
    copy_image(&app, &image)
}
#[tauri::command]
async fn library_save(app: AppHandle, id: String) -> Result<String, String> { export_item(&app, &id, None).map(|p| p.to_string_lossy().to_string()) }
#[tauri::command]
async fn library_save_as(app: AppHandle, id: String) -> Result<Option<String>, String> {
    let item = st(&app).library.lock().unwrap().get(&id).ok_or("That capture no longer exists.")?;
    let ext = Path::new(&item.file_name).extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_else(|| "png".into());
    let Some(target) = app.dialog().file().set_directory(export_folder(&app)).set_file_name(format!("{}.{ext}", item.title)).blocking_save_file().and_then(|f| f.into_path().ok()) else { return Ok(None) };
    export_item(&app, &id, Some(target)).map(|p| Some(p.to_string_lossy().to_string()))
}
#[tauri::command]
async fn library_reveal(app: AppHandle, id: String) {
    let file = { let lib = st(&app).library.lock().unwrap(); lib.get(&id).map(|i| lib.file(&i)) };
    if let Some(f) = file { reveal(&f); }
}
fn reveal(file: &Path) {
    #[cfg(windows)] { let _ = std::process::Command::new("explorer").arg(format!("/select,{}", file.display())).spawn(); }
    #[cfg(target_os = "linux")] { if let Some(dir) = file.parent() { let _ = std::process::Command::new("xdg-open").arg(dir).spawn(); } }
    #[cfg(target_os = "macos")] { let _ = std::process::Command::new("open").arg("-R").arg(file).spawn(); }
}
fn open_path(file: &Path) {
    // explorer opens the file with its default app without a shell, so "&" and other characters are safe.
    #[cfg(windows)] { let _ = std::process::Command::new("explorer").arg(file).spawn(); }
    #[cfg(target_os = "linux")] { let _ = std::process::Command::new("xdg-open").arg(file).spawn(); }
    #[cfg(target_os = "macos")] { let _ = std::process::Command::new("open").arg(file).spawn(); }
}
#[tauri::command]
async fn library_open(app: AppHandle, id: String) {
    let found = { let lib = st(&app).library.lock().unwrap(); lib.get(&id).map(|i| (i.kind.clone(), lib.file(&i))) };
    match found { Some((kind, _)) if kind == "recording" => open_video(&app, &id), Some(_) => open_editor(&app, Some(&id), false), None => {} }
}
/// History's Combine: the chosen screenshots joined into one new capture, in the order they were picked, which opens
/// in the editor.
#[tauri::command]
async fn library_combine(app: AppHandle, ids: Vec<String>, vertical: bool) -> Result<(), String> {
    if ids.len() < 2 { return Err("Choose two or more screenshots to combine.".into()); }
    let files: Vec<PathBuf> = {
        let lib = st(&app).library.lock().unwrap();
        ids.iter().map(|id| lib.get(id).filter(|i| i.kind != "recording").map(|i| lib.file(&i)).ok_or("Only screenshots can be combined.")).collect::<Result<_, _>>()?
    };
    let images: Vec<image::RgbaImage> = files.iter().map(|f| std::fs::read(f).ok().and_then(|b| capture::decode(&b)).ok_or("Couldn’t read one of the screenshots")).collect::<Result<_, _>>()?;
    let joined = combine::combine(&images, vertical);
    let (w, h) = joined.dimensions();
    let title = format!("Combined {} screenshots", images.len());
    let item = st(&app).library.lock().unwrap().add(&capture::png(&joined), "screenshot", "png", Some(title), w, h)?;
    broadcast(&app, "library:changed", Value::Null);
    let a = app.clone();
    let _ = app.run_on_main_thread(move || open_editor(&a, Some(&item.id), false));
    Ok(())
}
#[tauri::command]
async fn library_play(app: AppHandle, id: String) {
    let file = { let lib = st(&app).library.lock().unwrap(); lib.get(&id).map(|i| lib.file(&i)) };
    if let Some(f) = file { open_path(&f); }
}
#[tauri::command]
async fn library_pin(app: AppHandle, id: String) {
    let file = { let lib = st(&app).library.lock().unwrap(); lib.get(&id).map(|i| lib.file(&i)) };
    if let Some(bytes) = file.and_then(|f| std::fs::read(f).ok()) { if let Some(img) = capture::decode(&bytes) { pin_image(&app, &img); } }
}
#[tauri::command]
async fn library_drag(app: AppHandle, window: tauri::Window, id: String) {
    let file = { let lib = st(&app).library.lock().unwrap(); lib.get(&id).map(|i| lib.file(&i)) };
    if let Some(f) = file { start_drag(&app, window, f); }
}

fn start_drag(app: &AppHandle, window: tauri::Window, file: PathBuf) {
    let icon = std::fs::read(&file).ok().and_then(|b| capture::decode(&b))
        .map(|i| capture::png(&image::imageops::thumbnail(&i, 160, (160 * i.height() / i.width().max(1)).max(1))))
        .unwrap_or_default();
    let _ = app.run_on_main_thread(move || {
        #[cfg(target_os = "linux")]
        let handle = window.gtk_window();
        #[cfg(not(target_os = "linux"))]
        let handle: tauri::Result<tauri::Window> = Ok(window.clone());
        if let Ok(h) = handle {
            let _ = drag::start_drag(&h, drag::DragItem::Files(vec![file]), drag::Image::Raw(icon), |_, _| {}, drag::Options::default());
        }
    });
}

#[tauri::command]
async fn editor_save(app: AppHandle, id: String, data_url: String, project: Value) -> Result<String, String> {
    let bytes = capture::data_url_bytes(&data_url).ok_or("Bad image")?;
    // The page's PNG is already lossless, so unless JPEG is wanted it can go straight to disk.
    let (encoded, ext, (w, h)) = match capture::png_size(&bytes).filter(|_| setting(&app, "imageFormat").as_str() != Some("jpg")) {
        Some(size) => (bytes, "png", size),
        None => { let image = capture::decode(&bytes).ok_or("Bad image")?; let (encoded, ext) = encode(&app, &image); (encoded, ext, image.dimensions()) }
    };
    let mut lib = st(&app).library.lock().unwrap();
    // An editor whose capture was deleted mustn't quietly re-create it on autosave.
    if !id.is_empty() && lib.get(&id).is_none() { return Err("That capture no longer exists.".into()); }
    let id = if !id.is_empty() { lib.replace_file(&id, &encoded, ext)?; lib.update(&id, |i| { i.width = w; i.height = h; }); id }
        else { lib.add(&encoded, "screenshot", ext, None, w, h)?.id };
    lib.save_project(&id, &project)?;
    let item = lib.get(&id).filter(library::wants_thumb);
    drop(lib);
    broadcast(&app, "library:changed", Value::Null);
    if let Some(item) = item { let a = app.clone(); std::thread::spawn(move || make_thumb(&a, &item)); }
    Ok(id)
}
#[tauri::command]
async fn editor_copy(app: AppHandle, data_url: String) -> Result<(), String> {
    let image = capture::data_url_bytes(&data_url).and_then(|b| capture::decode(&b)).ok_or("Bad image")?;
    copy_image(&app, &image)
}
#[tauri::command]
async fn editor_export(app: AppHandle, data_url: String, name: String, save_as: bool) -> Result<Option<String>, String> {
    let image = capture::data_url_bytes(&data_url).and_then(|b| capture::decode(&b)).ok_or("Bad image")?;
    let (bytes, ext) = encode(&app, &image);
    let name = if name.is_empty() { library::capture_name("Still") } else { name };
    let mut file = unique_path(&export_folder(&app), &name, ext);
    let failed = |e: std::io::Error, f: &Path| format!("Couldn’t save to {}: {e}", f.display());
    if save_as {
        let suggested = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let Some(chosen) = app.dialog().file().set_directory(export_folder(&app)).set_file_name(suggested)
            .add_filter("PNG", &["png"]).add_filter("JPEG", &["jpg"]).blocking_save_file().and_then(|f| f.into_path().ok()) else { return Ok(None) };
        file = chosen;
        let jpg = file.extension().map(|e| e.eq_ignore_ascii_case("jpg") || e.eq_ignore_ascii_case("jpeg")).unwrap_or(false);
        std::fs::write(&file, if jpg { capture::jpeg(&image, 92) } else { capture::png(&image) }).map_err(|e| failed(e, &file))?;
    } else { std::fs::write(&file, bytes).map_err(|e| failed(e, &file))?; }
    Ok(Some(file.to_string_lossy().to_string()))
}
#[tauri::command]
async fn editor_drag(app: AppHandle, window: tauri::Window, data_url: String) {
    let Some(bytes) = capture::data_url_bytes(&data_url) else { return };
    let file = private_temp().join(format!("{}.png", library::capture_name("Still")));
    if std::fs::write(&file, bytes).is_ok() { start_drag(&app, window, file); }
}
#[tauri::command]
async fn editor_pin(app: AppHandle, data_url: String) {
    if let Some(img) = capture::data_url_bytes(&data_url).and_then(|b| capture::decode(&b)) { pin_image(&app, &img); }
}
#[tauri::command]
async fn editor_open_image(app: AppHandle) -> Option<String> {
    use base64::Engine;
    let path = app.dialog().file().add_filter("Images", &["png", "jpg", "jpeg"]).blocking_pick_file()?.into_path().ok()?;
    let image = capture::decode(&std::fs::read(path).ok()?)?;
    Some(format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(capture::png(&image))))
}

fn pin_image(app: &AppHandle, image: &RgbaImage) {
    let file = private_temp().join(format!("still-pin-{}.png", uuid::Uuid::new_v4().simple()));
    if std::fs::write(&file, capture::png(image)).is_err() { return; }
    let (w, h) = image.dimensions();
    let cursor = app.cursor_position().unwrap_or(PhysicalPosition::new(0.0, 0.0));
    let monitor = app.monitor_from_point(cursor.x, cursor.y).ok().flatten().or_else(|| app.primary_monitor().ok().flatten());
    let (scale, area) = monitor.map(|m| (m.scale_factor(), *m.work_area())).unwrap_or((1.0, tauri::PhysicalRect { position: PhysicalPosition::new(0, 0), size: PhysicalSize::new(1920, 1080) }));
    let fit = (area.size.width as f64 * 0.6 / w as f64).min(area.size.height as f64 * 0.6 / h as f64).min(1.0);
    let (pw, ph) = ((w as f64 * fit) as u32, (h as f64 * fit) as u32);
    let label = format!("pin-{}", uuid::Uuid::new_v4().simple());
    if let Ok(win) = builder(app, &label, "pin.html", json!({ "file": file })).title("Pinned Screenshot").decorations(false).always_on_top(true).skip_taskbar(true)
        .inner_size(pw as f64 / scale, ph as f64 / scale).min_inner_size(60.0, 40.0).build() {
        let _ = win.set_position(PhysicalPosition::new(area.position.x + (area.size.width as i32 - pw as i32) / 2, area.position.y + (area.size.height as i32 - ph as i32) / 2));
        let _ = win.show();
        win.on_window_event(move |e| if let tauri::WindowEvent::Destroyed = e { let _ = std::fs::remove_file(&file); });
    }
}

#[tauri::command]
async fn preview_edit(app: AppHandle, window: tauri::Window, id: String) { let _ = window.close(); open_editor(&app, Some(&id), false); }
#[tauri::command]
async fn open_settings_cmd(app: AppHandle, page: Option<String>) { open_settings(&app, page.as_deref()); }
#[tauri::command]
async fn open_history_cmd(app: AppHandle) { open_history(&app); }
#[tauri::command]
async fn open_demo(app: AppHandle) { open_editor(&app, None, false); }
#[tauri::command]
async fn capture_action(app: AppHandle, action: String) { run_action(&app, &action); }

#[tauri::command]
async fn ocr_result(app: AppHandle, window: tauri::Window, text: String, error: Option<String>) {
    let _ = window.close();
    if let Ok(entries) = std::fs::read_dir(private_temp()) { for e in entries.flatten() { if e.file_name().to_string_lossy().starts_with("still-ocr-") { let _ = std::fs::remove_file(e.path()); } } }
    // A large, noisy picture can keep the QR scan busy for many seconds. The text shouldn't wait for that.
    let scan = st(&app).session.lock().unwrap().qr.remove(window.label());
    let codes = scan.and_then(|s| s.recv_timeout(Duration::from_secs(2)).ok()).unwrap_or_default();
    if let Some(dir) = st(&app).session.lock().unwrap().selftest.clone() { let _ = std::fs::write(dir.join("ocr.txt"), &text); return; }
    // A failed OCR run still has the QR codes to give.
    if let Some(e) = error.filter(|_| codes.is_empty()) { notify(&app, "Text recognition failed", &e); return; }
    let text = qr::with_text(&text, &codes);
    if text.is_empty() { notify(&app, "No text found", "Try selecting a larger area with clearer text."); return; }
    let _ = app.clipboard().write_text(text.clone());
    notify(&app, "Text copied", &text.chars().take(120).collect::<String>());
}

/// The screen has been chosen. The bubble goes up now so it's in place before the countdown ends; the camera
/// light stays off until the user has committed to recording.
#[tauri::command]
async fn recording_prepared(app: AppHandle) {
    let Some(place) = st(&app).session.lock().unwrap().recorded else { return };
    open_marks(&app, place);
    if setting(&app, "recording.camera").as_bool().unwrap_or(false) { open_camera(&app, place); }
    if st(&app).session.lock().unwrap().recording.is_none() { end_recording_extras(&app); }
}
#[tauri::command]
async fn recording_started(app: AppHandle) {
    {
        let mut s = st(&app).session.lock().unwrap();
        s.recording_began = Some(std::time::Instant::now());
        // Where the pointer goes is only watched while recording, and only where it can be (not on Wayland).
        if let Some(place) = s.recorded { s.trail = marks::trail(place.area).ok(); }
    }
    build_tray_menu(&app); start_listening(&app);
}
#[tauri::command]
async fn recording_listen(app: AppHandle, on: bool) {
    // The controls say "listen" when recording runs and "don't" when it pauses or stops: the trail's clock follows.
    if let Some(trail) = &st(&app).session.lock().unwrap().trail { trail.pause(!on); }
    if on { start_listening(&app); } else { let listener = st(&app).session.lock().unwrap().listener.take(); drop(listener); }
}
#[tauri::command]
async fn recording_finished(app: AppHandle) { end_recording_extras(&app); }
#[tauri::command]
async fn camera_failed(app: AppHandle, message: String) {
    if let Some(w) = app.get_webview_window("camera") { let _ = w.destroy(); }
    notify(&app, "Camera bubble is off", &message);
}
#[tauri::command]
async fn recording_cancel(app: AppHandle) { let _ = std::fs::remove_file(recording_part(&app)); stop_recording_state(&app); }

/// Where Still's own recorder writes the video while it records.
fn native_part() -> PathBuf { private_temp().join(format!("still-native-{}.mp4", std::process::id())) }

/// Starts Still's own recorder on the area chosen for this recording.
#[tauri::command]
async fn recording_begin(app: AppHandle) -> Result<(), String> {
    let (params, place) = { let s = st(&app).session.lock().unwrap(); (s.recording.clone(), s.recorded) };
    let (Some(params), Some(place)) = (params, place) else { return Err("There is no recording to start.".into()) };
    let rect = &params["rect"];
    let crop = record::even_crop(rect["x"].as_f64().unwrap_or(0.0), rect["y"].as_f64().unwrap_or(0.0), rect["w"].as_f64().unwrap_or(0.0), rect["h"].as_f64().unwrap_or(0.0),
        params["imageWidth"].as_u64().unwrap_or(0) as u32, params["imageHeight"].as_u64().unwrap_or(0) as u32);
    let options = record::Options {
        monitor: (place.display.x as i32 + 1, place.display.y as i32 + 1), crop,
        fps: params["options"]["fps"].as_u64().unwrap_or(30) as u32,
        quality: params["options"]["quality"].as_str().unwrap_or("high").to_string(),
        // Cursor effects: the pointer stays out of the picture and the video editor draws it from the trail.
        cursor: params["options"]["cursor"].as_bool().unwrap_or(true) && !params["options"]["cursorEffects"].as_bool().unwrap_or(false),
        system_audio: params["options"]["systemAudio"].as_bool().unwrap_or(false),
        microphone: params["options"]["microphone"].as_bool().unwrap_or(false),
        path: native_part(),
    };
    let separate = !options.cursor && params["options"]["cursorEffects"].as_bool().unwrap_or(false);
    let handle = record::start(options)?;
    st(&app).session.lock().unwrap().cursor_separate = separate;
    if !handle.warnings.is_empty() { notify(&app, "Recording without some sound", &handle.warnings.join(" ")); }
    st(&app).session.lock().unwrap().recorder = Some(Arc::new(handle));
    Ok(())
}
#[tauri::command]
async fn recording_stop(app: AppHandle) -> Result<(), String> { finish_native(&app) }
#[tauri::command]
async fn recording_pause(app: AppHandle, on: bool) {
    let recorder = st(&app).session.lock().unwrap().recorder.clone();
    if let Some(recorder) = recorder { recorder.pause(on); }
}
#[tauri::command]
async fn recording_restart(app: AppHandle) {
    let recorder = st(&app).session.lock().unwrap().recorder.clone();
    if let Some(recorder) = recorder { recorder.restart(); }
    if let Some(trail) = &st(&app).session.lock().unwrap().trail { trail.restart(); }
}

/// Ends a recording made by Still's own recorder and puts it in the library.
fn finish_native(app: &AppHandle) -> Result<(), String> {
    let Some(recorder) = st(app).session.lock().unwrap().recorder.take() else { return Ok(()) }; // Already finished.
    let finished = recorder.stop();
    let saved = finished.and_then(|f| {
        let bytes = std::fs::read(&f.path).map_err(|e| format!("The recording’s file couldn’t be read: {e}"))?;
        let _ = std::fs::remove_file(&f.path);
        eprintln!("[recording] {} frames, {} dropped, hardware encoder: {}", f.frames, f.dropped, f.hardware);
        store_recording(app, &bytes, "mp4", f.duration)
    });
    if let Err(e) = &saved { stop_recording_state(app); notify(app, "Recording couldn’t be saved", e); }
    saved
}
#[tauri::command]
async fn recording_error(app: AppHandle, message: String, stage: Option<String>) {
    if stage.as_deref() == Some("save") {
        // Whatever reached the disk before the problem is still a recording worth keeping.
        if salvage_recording(&app) { notify(&app, "Recording saved", &format!("Saving ran into a problem ({message}), so Still kept the video it had already written.")); }
        else { notify(&app, "Recording couldn’t be saved", &message); }
        return;
    }
    stop_recording_state(&app);
    notify(&app, "Recording couldn’t start", &message);
}
/// The recording as written so far. The HUD sends each second of video as the recorder hands it over, so the file
/// grows during the recording and the save at the end is only a rename into the library.
fn recording_part(_app: &AppHandle) -> PathBuf { private_temp().join(format!("still-recording-{}.part", std::process::id())) }
#[tauri::command]
async fn recording_chunk(app: AppHandle, data: String, ext: String) -> Result<(), String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(data).map_err(|e| e.to_string())?;
    {
        let mut s = st(&app).session.lock().unwrap();
        // A chunk arriving after Still has already ended the recording belongs to nothing.
        if s.recording.is_none() { return Ok(()); }
        s.recording_ext = if ext == "mp4" { "mp4".into() } else { "webm".into() };
    }
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(recording_part(&app)).map_err(|e| e.to_string())?;
    std::io::Write::write_all(&mut file, &bytes).map_err(|e| e.to_string())
}
/// Restart throws the recording away and begins again.
#[tauri::command]
async fn recording_reset(app: AppHandle) {
    let _ = std::fs::remove_file(recording_part(&app));
    if let Some(trail) = &st(&app).session.lock().unwrap().trail { trail.restart(); }
}
#[tauri::command]
async fn recording_save(app: AppHandle, ext: String, duration: f64) -> Result<(), String> {
    let part = recording_part(&app);
    // Still may already have ended and saved this recording itself (see request_stop); then there is nothing left to do.
    if st(&app).session.lock().unwrap().recording.is_none() { let _ = std::fs::remove_file(&part); return Ok(()); }
    let bytes = std::fs::read(&part).map_err(|e| format!("The recording’s file couldn’t be read: {e}"))?;
    let _ = std::fs::remove_file(&part);
    if bytes.is_empty() { stop_recording_state(&app); return Err("No video was captured.".into()); }
    store_recording(&app, &bytes, if ext == "mp4" { "mp4" } else { "webm" }, duration)
}
/// Ends a recording whose controls can't finish it themselves, keeping whatever was already written.
/// Returns true when a video was saved.
fn salvage_recording(app: &AppHandle) -> bool {
    let (ext, began) = { let s = st(app).session.lock().unwrap(); (s.recording_ext.clone(), s.recording_began) };
    let part = recording_part(app);
    let bytes = std::fs::read(&part).unwrap_or_default();
    let _ = std::fs::remove_file(&part);
    if bytes.is_empty() { stop_recording_state(app); return false; }
    let duration = began.map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0);
    match store_recording(app, &bytes, if ext == "mp4" { "mp4" } else { "webm" }, duration) {
        Ok(()) => true,
        Err(e) => { notify(app, "Recording couldn’t be saved", &e); false }
    }
}
/// Puts a finished recording in the library and does what the After Recording settings ask.
fn store_recording(app: &AppHandle, bytes: &[u8], ext: &str, duration: f64) -> Result<(), String> {
    let (trail, separate) = { let mut s = st(app).session.lock().unwrap(); (s.trail.take().map(marks::Trail::finish), std::mem::take(&mut s.cursor_separate)) };
    stop_recording_state(app);
    let added = st(app).library.lock().unwrap().add(bytes, "recording", ext, None, 0, 0);
    let item = match added {
        Ok(item) => item,
        Err(e) => {
            // Never lose a recording: if the library can't take it, put it where the user can find it.
            let rescue = unique_path(&app.path().desktop_dir().unwrap_or_else(|_| export_folder(app)), &library::capture_name("Still Recording"), ext);
            return match std::fs::write(&rescue, bytes) {
                Ok(_) => { notify(app, "Recording saved to your Desktop", &format!("Still’s library couldn’t store it ({e}), so it was saved as {}.", rescue.display())); Ok(()) }
                Err(e2) => { notify(app, "Your recording couldn’t be saved", &format!("{e}; {e2}")); Err(e2.to_string()) }
            };
        }
    };
    st(app).library.lock().unwrap().update(&item.id, |i| i.duration = duration);
    // The video editor reads the path and clicks from here, and keeps its own settings beside them.
    let mut project = trail.filter(|t| t["pointer"].as_array().is_some_and(|p| !p.is_empty())).unwrap_or(Value::Null);
    if separate { if project.is_null() { project = json!({}); } project["cursor"] = json!("separate"); }
    if !project.is_null() { let _ = st(app).library.lock().unwrap().save_project(&item.id, &project); }
    if setting(app, "afterRecording.save").as_bool().unwrap_or(true) { if let Err(e) = export_item(app, &item.id, None) { notify(app, "Couldn’t save to your folder", &e); } }
    if setting(app, "afterRecording.quickAccess").as_bool().unwrap_or(true) { show_preview(app, &item, false); }
    broadcast(app, "library:changed", Value::Null);
    Ok(())
}
/// Asks the HUD to stop. If it hasn't ended the recording a few seconds later, its page has stopped answering, so
/// the recording ends here and whatever it had already written is saved. Stopping is never a dead end.
fn request_stop(app: &AppHandle) {
    // Still's own recorder stops here, without the controls' page.
    if st(app).session.lock().unwrap().recorder.is_some() {
        let app = app.clone();
        std::thread::spawn(move || { let _ = finish_native(&app); });
        return;
    }
    let _ = app.emit_to("hud", "hud:stop", ());
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(8));
        if st(&app).session.lock().unwrap().recording.is_none() { return; }
        if !salvage_recording(&app) { notify(&app, "Recording stopped", "The recording controls stopped responding before any video was captured."); }
    });
}

#[tauri::command]
async fn recording_tick(app: AppHandle, seconds: u64, paused: bool) { show_recording_time(&app, seconds, paused); }

// ---- Video editor -------------------------------------------------------------------------------

// The page never names a path to write to: it asks for a save dialog, and this window's chosen file waits
// here until the finished export arrives.
fn video_source(app: &AppHandle, window: &tauri::Window) -> Result<(Item, PathBuf), String> {
    let id = window.label().strip_prefix("video-").ok_or("This window has no recording.")?;
    let lib = st(app).library.lock().unwrap();
    let item = lib.get(id).ok_or("That recording no longer exists.")?;
    let file = lib.file(&item);
    Ok((item, file))
}
fn take_export_target(app: &AppHandle, window: &tauri::Window) -> Result<PathBuf, String> {
    st(app).session.lock().unwrap().export_targets.remove(window.label()).ok_or_else(|| "Choose where to save the export first.".to_string())
}
#[tauri::command]
async fn video_export_target(app: AppHandle, window: tauri::Window, ext: String) -> Result<Option<String>, String> {
    if !video::EXPORT_TYPES.contains(&ext.as_str()) { return Err(format!("Still can’t export .{ext} files.")); }
    let (item, source) = video_source(&app, &window)?;
    let folder = export_folder(&app);
    let suggested = unique_path(&folder, &video::export_name(&item.title, &ext), &ext).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let Some(chosen) = app.dialog().file().set_directory(folder).set_file_name(suggested).add_filter(ext.to_uppercase(), &[ext.as_str()]).blocking_save_file().and_then(|f| f.into_path().ok()) else { return Ok(None) };
    let target = video::export_path(chosen, &ext);
    if video::is_same_file(&target, &source) { return Err("That’s the original recording. Choose another name so it’s kept.".into()); }
    st(&app).session.lock().unwrap().export_targets.insert(window.label().to_string(), target.clone());
    Ok(Some(target.to_string_lossy().to_string()))
}
#[tauri::command]
async fn video_export_save(app: AppHandle, window: tauri::Window, request: tauri::ipc::Request<'_>) -> Result<String, String> {
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else { return Err("Expected the exported file".into()) };
    let target = take_export_target(&app, &window)?;
    video::save_bytes(&private_temp(), bytes, &target)?;
    Ok(target.to_string_lossy().to_string())
}
/// Background music for a recording: the chosen file is copied in beside it (as music.<ext>), so the editor and
/// later exports keep finding it even if the original moves.
#[tauri::command]
async fn video_music_choose(app: AppHandle, window: tauri::Window) -> Result<Option<Value>, String> {
    let (_, source) = video_source(&app, &window)?;
    let Some(picked) = app.dialog().file().add_filter("Music", &["mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "webm"]).blocking_pick_file().and_then(|f| f.into_path().ok()) else { return Ok(None) };
    let ext = picked.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).filter(|e| e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric())).unwrap_or_else(|| "mp3".into());
    let folder = source.parent().ok_or("This recording has no folder.")?;
    let target = folder.join(format!("music.{ext}"));
    std::fs::copy(&picked, &target).map_err(|e| format!("Couldn’t copy the music: {e}"))?;
    let name = picked.file_stem().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "Music".into());
    Ok(Some(json!({ "name": name, "path": target.to_string_lossy() })))
}
/// The video editor's settings for a recording (trim points, background), kept beside it so they come back.
#[tauri::command]
async fn video_project_save(app: AppHandle, window: tauri::Window, project: Value) -> Result<(), String> {
    let (item, _) = video_source(&app, &window)?;
    st(&app).library.lock().unwrap().save_project(&item.id, &project)
}
#[tauri::command]
async fn video_export_copy(app: AppHandle, window: tauri::Window) -> Result<String, String> {
    let (_, source) = video_source(&app, &window)?;
    let target = take_export_target(&app, &window)?;
    video::save_copy(&private_temp(), &source, &target)?;
    Ok(target.to_string_lossy().to_string())
}

// ---- Sharing (self-hosted Still Cloud) -----------------------------------------------------------

fn token_file(app: &AppHandle) -> Option<PathBuf> { app.path().app_config_dir().ok().map(|d| d.join("cloud-token")) }
fn cloud_token(app: &AppHandle) -> String { token_file(app).and_then(|f| std::fs::read_to_string(f).ok()).unwrap_or_default().trim().to_string() }
fn save_token(app: &AppHandle, token: &str) -> Result<(), String> { write_private(&token_file(app).ok_or("No settings folder")?, token) }
fn write_private(file: &Path, token: &str) -> Result<(), String> {
    if let Some(dir) = file.parent() { let _ = std::fs::create_dir_all(dir); }
    // Only your account can read the token, from the moment the file exists.
    let mut options = std::fs::OpenOptions::new(); options.write(true).create(true).truncate(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
    use std::io::Write;
    options.open(file).and_then(|mut f| f.write_all(token.as_bytes())).map_err(|e| e.to_string())?;
    #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; let _ = std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600)); }
    Ok(())
}
fn cloud_client(app: &AppHandle) -> Result<cloud::Cloud, String> {
    let endpoint = setting(app, "cloud.endpoint").as_str().unwrap_or("").to_string();
    if endpoint.is_empty() { return Err("Connect a Still Cloud server in Settings → Cloud first.".into()); }
    cloud::Cloud::new(&endpoint, &cloud_token(app))
}
fn cloud_options(app: &AppHandle, title: String, text: String) -> cloud::Options {
    cloud::Options { title, text, password: String::new(), expiry_days: setting(app, "cloud.expiryDays").as_i64().unwrap_or(7),
        visibility: setting(app, "cloud.visibility").as_str().unwrap_or("link").to_string() }
}
fn drive_token_file(app: &AppHandle) -> Option<PathBuf> { app.path().app_config_dir().ok().map(|d| d.join("drive-token")) }
fn drive_token(app: &AppHandle) -> String { drive_token_file(app).and_then(|f| std::fs::read_to_string(f).ok()).unwrap_or_default().trim().to_string() }
async fn drive_share(app: &AppHandle, file: &Path, title: &str) -> Result<String, String> {
    let token = drive_token(app);
    if token.is_empty() { return Err("Connect Google Drive in Settings → Cloud first.".into()); }
    let folder = setting(app, "cloud.driveFolder").as_str().unwrap_or("").to_string();
    let public = setting(app, "cloud.driveAccess").as_str().unwrap_or("link") == "link";
    let uploaded = drive::upload(&token, &folder, file, title, public).await?;
    if uploaded.folder != folder { st(app).settings.lock().unwrap().update(&json!({ "cloud": { "driveFolder": uploaded.folder } })); }
    Ok(uploaded.link)
}
fn save_to_icloud(file: &Path, title: &str) -> Result<String, String> {
    let folder = cloud::icloud_folder().ok_or("iCloud Drive wasn’t found. Install iCloud for Windows and turn on iCloud Drive.")?.join("Still");
    std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    let target = unique_path(&folder, title, file.extension().and_then(|e| e.to_str()).unwrap_or("png"));
    std::fs::copy(file, &target).map_err(|e| e.to_string())?;
    Ok(target.to_string_lossy().to_string())
}
async fn share(app: &AppHandle, file: PathBuf, title: String, text: String) -> Result<String, String> {
    if setting(app, "cloud.provider").as_str() == Some("icloud") {
        // iCloud has no share links: the file is saved and synced, and there's nothing to copy.
        let saved = save_to_icloud(&file, &title);
        match &saved { Ok(_) => notify(app, "Saved to iCloud Drive", &title), Err(e) => notify(app, "Upload failed", e) }
        return saved;
    }
    let result = if setting(app, "cloud.provider").as_str() == Some("drive") { drive_share(app, &file, &title).await }
        else { match cloud_client(app) { Ok(c) => c.upload(&file, &cloud_options(app, title.clone(), text)).await, Err(e) => Err(e) } };
    match &result {
        Ok(link) => {
            let image = matches!(file.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(), Some("png" | "jpg" | "jpeg" | "gif" | "webp"));
            let format = setting(app, "cloud.linkFormat").as_str().unwrap_or("url").to_string();
            let copied = if link.starts_with("http") { cloud::link_text(link, &title, image, &format) } else { link.clone() };
            let _ = app.clipboard().write_text(copied); notify(app, "Link copied", link);
            if link.starts_with("http") { st(app).session.lock().unwrap().last_link = Some(link.clone()); build_tray_menu(app); }
        }
        Err(e) => notify(app, "Upload failed", e),
    }
    result
}
async fn upload_item(app: &AppHandle, id: &str) -> Result<String, String> {
    let (file, title, text) = { let lib = st(app).library.lock().unwrap(); let i = lib.get(id).ok_or("Missing capture")?; (lib.file(&i), i.title.clone(), i.text.clone()) };
    share(app, file, title, text).await
}

#[tauri::command]
async fn cloud_get(app: AppHandle) -> Value { json!({ "endpoint": setting(&app, "cloud.endpoint"), "hasToken": !cloud_token(&app).is_empty() }) }
#[tauri::command]
async fn cloud_connect(app: AppHandle, endpoint: String, token: String) -> Result<String, String> {
    // Reuse the saved token only for the server it was saved for, never send it to a new address.
    let saved_endpoint = setting(&app, "cloud.endpoint").as_str().unwrap_or("").trim_end_matches('/').to_string();
    let token = if token.trim().is_empty() && endpoint.trim().trim_end_matches('/') == saved_endpoint { cloud_token(&app) } else { token };
    let name = cloud::Cloud::new(&endpoint, &token)?.test().await?;
    save_token(&app, token.trim())?;
    let endpoint = endpoint.trim().trim_end_matches('/').to_string();
    st(&app).settings.lock().unwrap().update(&json!({ "cloud": { "endpoint": endpoint } }));
    Ok(name)
}
#[tauri::command]
async fn cloud_disconnect(app: AppHandle) {
    if let Some(f) = token_file(&app) { let _ = std::fs::remove_file(f); }
    st(&app).settings.lock().unwrap().update(&json!({ "cloud": { "endpoint": "", "autoUpload": false } }));
}
#[tauri::command]
async fn drive_get(app: AppHandle) -> Value { json!({ "available": drive::available(), "connected": !drive_token(&app).is_empty(), "email": setting(&app, "cloud.driveEmail"), "icloud": cloud::icloud_folder().is_some() }) }
#[tauri::command]
async fn drive_connect(app: AppHandle) -> Result<String, String> {
    let connected = drive::connect().await?;
    let file = drive_token_file(&app).ok_or("No settings folder")?;
    write_private(&file, &connected.refresh_token)?;
    st(&app).settings.lock().unwrap().update(&json!({ "cloud": { "provider": "drive", "driveEmail": connected.email } }));
    Ok(connected.email)
}
#[tauri::command]
async fn drive_disconnect(app: AppHandle) {
    let token = drive_token(&app);
    if let Some(f) = drive_token_file(&app) { let _ = std::fs::remove_file(f); }
    st(&app).settings.lock().unwrap().update(&json!({ "cloud": { "provider": "still", "driveEmail": "", "driveFolder": "" } }));
    if !token.is_empty() { drive::revoke(&token).await; }
}
#[tauri::command]
async fn cloud_upload(app: AppHandle, id: String) -> Result<String, String> { upload_item(&app, &id).await }
#[tauri::command]
async fn cloud_upload_data(app: AppHandle, data_url: String, title: String) -> Result<String, String> {
    let bytes = capture::data_url_bytes(&data_url).ok_or("Bad image")?;
    let file = private_temp().join(format!("still-share-{}.png", uuid::Uuid::new_v4().simple()));
    std::fs::write(&file, bytes).map_err(|e| e.to_string())?;
    let result = share(&app, file.clone(), if title.is_empty() { library::capture_name("Still") } else { title }, String::new()).await;
    let _ = std::fs::remove_file(file);
    result
}

#[tauri::command]
async fn update_status(app: AppHandle) -> Value { st(&app).session.lock().unwrap().update.clone() }
#[tauri::command]
async fn update_check(app: AppHandle) { check_update(&app, true); }
#[tauri::command]
async fn update_install(app: AppHandle) { install_update(&app); }

// ---- Self-test (run by CI on real Windows / Linux machines) -------------------------------------

fn self_test(app: AppHandle, dir: PathBuf) {
    std::thread::spawn(move || {
        let _ = std::fs::create_dir_all(&dir);
        let mut results = serde_json::Map::new();
        let mut log = |k: &str, v: Value| { println!("[self-test] {k}: {v}"); results.insert(k.into(), v); };
        let wait = |ms| std::thread::sleep(Duration::from_millis(ms));
        let snap = |name: &str| { if let Ok(g) = capture::grab_all() { let _ = std::fs::write(dir.join(format!("{name}.png")), capture::png(&g[0].image)); } };
        let count = || st(&app).library.lock().unwrap().items.len();
        let has_image = || app.clipboard().read_image().map(|i| i.width() > 0).unwrap_or(false);
        let before = count();
        capture_fullscreen(&app);
        wait(2500);
        log("fullscreenAdded", json!(count() == before + 1));
        let preview = st(&app).session.lock().unwrap().previews.first().cloned();
        let preview_win = preview.as_ref().and_then(|(l, _)| app.get_webview_window(l));
        log("previewCreated", json!(preview.is_some()));
        log("previewVisible", json!(preview_win.as_ref().map(|w| w.is_visible().unwrap_or(false)).unwrap_or(false)));
        log("afterCaptureCopy", json!(has_image()));
        snap("1-after-capture");
        let _ = app.clipboard().clear();
        if let Some(w) = &preview_win { let _ = w.eval("document.querySelector('#copy').click()"); }
        wait(1500);
        log("quickAccessCopy", json!(has_image()));
        // Open windows from a page, the way buttons do (this path used to crash on Windows).
        let a = app.clone();
        let _ = app.run_on_main_thread(move || open_settings(&a, Some("About")));
        wait(2500);
        if let Some(w) = app.get_webview_window("settings") { let _ = w.eval("still.send('open:history')"); }
        wait(3000);
        log("historyFromSettings", json!(app.get_webview_window("history").map(|w| w.is_visible().unwrap_or(false)).unwrap_or(false)));
        snap("1b-history");
        let shot = st(&app).library.lock().unwrap().items.first().cloned();
        if let (Some(item), Some(w)) = (shot.as_ref(), app.get_webview_window("history")) {
            let _ = w.eval(&format!("still.invoke('library:open', '{}')", item.id));
            wait(3500);
            log("editorFromHistory", json!(app.get_webview_window(&format!("editor-{}", item.id)).is_some()));
            if let Some(e) = app.get_webview_window(&format!("editor-{}", item.id)) { let _ = e.close(); }
        }
        start_selection(&app, "screenshot", 0, false);
        wait(3000);
        let overlays = st(&app).session.lock().unwrap().overlays.clone();
        log("overlayWindows", json!(overlays.len()));
        log("overlayPreWarmed", json!(overlays.iter().any(|l| l.starts_with("overlay-warm-"))));
        log("windowList", json!(capture::list_windows(1.0).len()));
        snap("2-overlay");
        let display = st(&app).session.lock().unwrap().grabs.first().map(|g| g.id).unwrap_or(0);
        finish_selection(&app, json!({ "displayId": display, "purpose": "screenshot", "px": { "x": 50, "y": 50, "w": 300, "h": 200 }, "rect": Value::Null }));
        wait(2500);
        let first = st(&app).library.lock().unwrap().items.first().cloned();
        log("areaSize", json!(first.as_ref().map(|i| format!("{}x{}", i.width, i.height))));
        snap("3-after-area");
        let before = count();
        previous::capture_again(&app);
        wait(2000);
        log("previousAreaAdded", json!(count() == before + 1));
        log("previousAreaSize", json!(st(&app).library.lock().unwrap().items.first().map(|i| format!("{}x{}", i.width, i.height))));
        let before = count();
        start_selection(&app, "scroll", 0, false);
        wait(3000);
        let display = st(&app).session.lock().unwrap().grabs.first().map(|g| g.id).unwrap_or(0);
        finish_selection(&app, json!({ "displayId": display, "purpose": "scroll", "px": { "x": 50, "y": 50, "w": 300, "h": 200 }, "rect": Value::Null }));
        wait(2500);
        log("scrollControls", json!(app.get_webview_window("scroll").is_some()));
        snap("3b-scrolling");
        scroll::stop(&app, true);
        wait(2500);
        log("scrollAdded", json!(count() == before + 1));
        st(&app).settings.lock().unwrap().update(&json!({ "hideDesktopIcons": true }));
        let hidden = desktop::hide(&app);
        log("desktopIconsHidden", json!(hidden.is_some()));
        snap("3c-icons-hidden");
        drop(hidden);
        st(&app).settings.lock().unwrap().update(&json!({ "hideDesktopIcons": false }));
        if let Some(item) = first {
            let label = format!("editor-{}", item.id);
            let a = app.clone(); let id = item.id.clone();
            let _ = app.run_on_main_thread(move || open_editor(&a, Some(&id), false));
            wait(4000);
            let _ = app.clipboard().clear();
            if let Some(w) = app.get_webview_window(&label) { let _ = w.eval("document.querySelector('#copy').click()"); }
            wait(2000);
            log("editorCopy", json!(has_image()));
            snap("4-editor");
        }
        // Sharing: upload to a local Still Cloud server when CI provides one.
        if let (Ok(endpoint), Ok(token)) = (std::env::var("STILL_TEST_CLOUD"), std::env::var("STILL_TEST_CLOUD_TOKEN")) {
            let id = st(&app).library.lock().unwrap().items.first().map(|i| i.id.clone()).unwrap_or_default();
            let result = tauri::async_runtime::block_on(async {
                let name = cloud::Cloud::new(&endpoint, &token)?.test().await?;
                save_token(&app, &token)?;
                st(&app).settings.lock().unwrap().update(&json!({ "cloud": { "endpoint": endpoint } }));
                let link = upload_item(&app, &id).await?;
                Ok::<_, String>(format!("{name} {link}"))
            });
            log("cloudUpload", json!(result.map_err(|e| format!("error: {e}")).unwrap_or_else(|e| e)));
            log("cloudLinkCopied", json!(app.clipboard().read_text().map(|t| t.starts_with("http")).unwrap_or(false)));
        }
        // Recording extras: they open and listen, a missing camera closes only the bubble, and nothing outlives the recording.
        st(&app).settings.lock().unwrap().update(&json!({ "recording": { "clicks": true, "keys": true } }));
        let (area, screen) = (marks::Area { x: 100.0, y: 100.0, w: 400.0, h: 300.0 }, marks::Area { x: 0.0, y: 0.0, w: 1280.0, h: 720.0 });
        { let mut s = st(&app).session.lock().unwrap(); s.recording = Some(Value::Null); s.recorded = Some(Recorded { area, display: screen, scale: 1.0 }); }
        log("globalInput", json!(marks::available()));
        open_marks(&app, Recorded { area, display: screen, scale: 1.0 });
        open_camera(&app, Recorded { area, display: screen, scale: 1.0 });
        start_listening(&app);
        wait(1000);
        log("marksWindow", json!(app.get_webview_window("marks").map(|w| w.is_visible().unwrap_or(false)).unwrap_or(false)));
        log("marksListening", json!(st(&app).session.lock().unwrap().listener.is_some()));
        wait(4000);
        log("cameraBubbleOpen", json!(app.get_webview_window("camera").is_some()));
        snap("5-recording-extras");
        end_recording_extras(&app);
        st(&app).session.lock().unwrap().recording = None;
        st(&app).settings.lock().unwrap().update(&json!({ "recording": { "clicks": false, "keys": false } }));
        wait(500);
        log("extrasClosed", json!(app.get_webview_window("marks").is_none() && app.get_webview_window("camera").is_none() && st(&app).session.lock().unwrap().listener.is_none()));
        // Still's own recorder: three seconds of a 400×300 area, finished into a real MP4 (Windows only).
        match record::available() {
            Err(reason) => log("nativeRecorder", json!(reason)),
            Ok(()) => {
                let origin = capture::grab_all().ok().and_then(|g| g.first().map(|g| (g.x + 1, g.y + 1))).unwrap_or((1, 1));
                let path = dir.join("native-recording.mp4");
                let options = record::Options { monitor: origin, crop: (100, 100, 400, 300), fps: 30, quality: "high".into(), cursor: true, system_audio: true, microphone: false, path: path.clone() };
                match record::start(options) {
                    Err(e) => log("nativeRecorder", json!(format!("didn’t start: {e}"))),
                    Ok(recorder) => {
                        log("nativeSoundWarnings", json!(recorder.warnings));
                        wait(3000);
                        match recorder.stop() {
                            Ok(f) => {
                                log("nativeRecorder", json!("recorded"));
                                log("nativeDuration", json!((f.duration * 10.0).round() / 10.0));
                                log("nativeFrames", json!(f.frames));
                                log("nativeHardwareEncoder", json!(f.hardware));
                                log("nativeLitShare", json!((f.lit * 100.0).round() / 100.0));
                                log("nativeAudioTrack", json!(f.audio));
                                log("nativeBytes", json!(std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0)));
                            }
                            Err(e) => log("nativeRecorder", json!(format!("didn’t finish: {e}"))),
                        }
                    }
                }
            }
        }
        let _ = app.run_on_main_thread({ let a = app.clone(); move || { let _ = builder(&a, "ocr-probe", "ocr.html", json!({ "probe": "1" })).build(); } });
        for _ in 0..60 { if dir.join("ocr.txt").exists() { break; } wait(1000); }
        log("ocr", json!(std::fs::read_to_string(dir.join("ocr.txt")).unwrap_or_default().trim()));
        let _ = std::fs::write(dir.join("results.json"), serde_json::to_string_pretty(&Value::Object(results)).unwrap_or_default());
        app.exit(0);
    });
}

// ---- Startup ------------------------------------------------------------------------------------

fn run_args(app: &AppHandle, args: &[String]) -> bool {
    if let Some((path, using)) = image_argument(args) {
        // Windows and the file manager start Still for this, so it may be the first window it shows.
        let app = app.clone();
        let _ = app.clone().run_on_main_thread(move || open_image_file(&app, &path, using));
        return true;
    }
    let action = args.iter().find_map(|a| a.strip_prefix("--capture=").map(|s| s.to_string()))
        .or_else(|| if args.iter().any(|a| a == "--capture") { args.iter().find(|a| ACTIONS.iter().any(|(k, _)| k == a)).cloned() } else { None });
    match action { Some(a) if ACTIONS.iter().any(|(k, _)| *k == a) => { run_action(app, &a); true } _ => false }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if desktop::watch() { return; }
    tauri::Builder::default()
        .on_window_event(|window, event| if let tauri::WindowEvent::Destroyed = event { window_gone(window.app_handle(), window.label()); })
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| { if !run_args(app, &args) { open_settings(app, None); } }))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .setup(|app| {
            if let Ok(cache) = app.path().app_cache_dir() { init_private_temp(cache); }
            desktop::recover();
            clear_private_temp();
            let handle = app.handle().clone();
            let config = app.path().app_config_dir()?;
            let data = app.path().app_data_dir()?;
            app.manage(State {
                settings: Mutex::new(Settings::load(config)),
                library: Mutex::new(Library::open(data.join("Library"))),
                session: Mutex::new(Session { update: json!({ "state": "idle" }), ..Default::default() }),
            });
            apply_name_pattern(&handle);
            apply_history_days(&handle);
            let menu = tray_menu(&handle)?;
            TrayIconBuilder::with_id("still").icon(tray_icon()).tooltip("Still").menu(&menu)
                .show_menu_on_left_click(!cfg!(windows))
                .on_menu_event(|app, e| on_menu(app, e.id().as_ref()))
                .on_tray_icon_event(|tray, e| if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                    // While recording, a click stops it, like the Mac's menu bar button.
                    let app = tray.app_handle();
                    let recording = st(app).session.lock().unwrap().recording.is_some();
                    run_action(app, if recording { "record" } else { "area" });
                })
                .build(app)?;
            register_shortcuts(&handle);
            apply_login_item(&handle);
            std::thread::spawn({ let h = handle.clone(); move || { std::thread::sleep(Duration::from_secs(3)); warm_overlays(&h); backfill_thumbs(&h); } });
            let args: Vec<String> = std::env::args().collect();
            if let Some(dir) = args.iter().find_map(|a| a.strip_prefix("--self-test=")) {
                let dir = PathBuf::from(dir);
                st(&handle).session.lock().unwrap().selftest = Some(dir.clone());
                std::thread::spawn({ let h = handle.clone(); move || { std::thread::sleep(Duration::from_secs(2)); self_test(h, dir) } });
                return Ok(());
            }
            if setting(&handle, "autoUpdate").as_bool().unwrap_or(true) {
                let h = handle.clone();
                std::thread::spawn(move || loop { std::thread::sleep(Duration::from_secs(10)); check_update(&h, false); std::thread::sleep(Duration::from_secs(6 * 3600)); });
            }
            if run_args(&handle, &args) {}
            else if args.iter().any(|a| a == "--editor-demo") { open_editor(&handle, None, false); }
            else if !args.iter().any(|a| a == "--hidden") && !setting(&handle, "welcomed").as_bool().unwrap_or(false) {
                st(&handle).settings.lock().unwrap().update(&json!({ "welcomed": true }));
                open_settings(&handle, None);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            settings_get, settings_set, settings_reset, settings_choose_folder, shortcuts_pause,
            overlay_done, overlay_cancel, overlay_fullscreen, overlay_timer, countdown_cancel, overlay_purpose, overlay_window_mode, overlay_pointer, overlay_color, overlay_ready,
            library_list, library_get, library_rename, library_delete, library_copy, library_save, library_save_as, library_reveal, library_open, library_play, library_combine, library_star, library_pin, library_drag,
            editor_save, editor_copy, editor_export, editor_drag, editor_pin, editor_open_image,
            preview_edit, open_settings_cmd, open_history_cmd, open_demo, capture_action, ocr_result,
            recording_prepared, recording_started, recording_listen, recording_finished, camera_failed,
            recording_cancel, recording_error, recording_chunk, recording_reset, recording_save, recording_begin, recording_stop, recording_pause, recording_restart, recording_tick, video_export_target, video_export_save, video_export_copy, video_project_save, video_music_choose,
            update_status, update_check, update_install,
            cloud_get, cloud_connect, cloud_disconnect, cloud_upload, cloud_upload_data, qr_svg, library_qr, drive_get, drive_connect, drive_disconnect, scroll::scroll_stop, scroll::scroll_auto
        ])
        .build(tauri::generate_context!())
        .expect("error while building Still")
        .run(|_app, event| match event {
            tauri::RunEvent::ExitRequested { api, code, .. } => if code.is_none() { api.prevent_exit(); },
            tauri::RunEvent::Exit => clear_private_temp(),
            _ => {}
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> { std::iter::once("still").chain(list.iter().copied()).map(String::from).collect() }

    #[test]
    fn image_files_from_the_right_click_menu_and_open_with() {
        assert_eq!(image_argument(&args(&["--open=C:\\Users\\Sam\\My shot.png"])), Some((PathBuf::from("C:\\Users\\Sam\\My shot.png"), ImageUse::Edit)));
        assert_eq!(image_argument(&args(&["--text=/home/sam/scan.jpg"])), Some((PathBuf::from("/home/sam/scan.jpg"), ImageUse::Text)));
        assert_eq!(image_argument(&args(&["--pin=/tmp/a.jpeg"])), Some((PathBuf::from("/tmp/a.jpeg"), ImageUse::Pin)));
        assert_eq!(image_argument(&args(&["/home/sam/Photo.JPG"])), Some((PathBuf::from("/home/sam/Photo.JPG"), ImageUse::Edit)));
        // Capture actions, flags and other files aren't images to open; nor is the program's own path.
        assert_eq!(image_argument(&args(&["--capture=area"])), None);
        assert_eq!(image_argument(&args(&["--hidden", "notes.txt"])), None);
        assert_eq!(image_argument(&["C:\\Still\\shot.png".to_string()]), None);
    }
}
