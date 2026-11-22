//! Clipboard History: keeps what you copy (text, pictures and files) so any of it can be put back later, like the
//! Mac app's ClipboardHistory, with the same limits. A background thread looks at the clipboard twice a second;
//! nothing here runs on the main thread. The history is kept in the app's data folder, in clipboard/history.json,
//! with pictures beside it in clipboard/images, and never leaves this computer.

#[cfg(not(windows))]
mod unix;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Manager, PhysicalPosition};

/// The longest text kept, in UTF-16 units as the Mac counts it: about a million characters.
const MAX_TEXT_LENGTH: usize = 1_000_000;
/// The largest picture kept, as a PNG.
const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
/// Pictures this big (in pixels, about 16k × 16k) aren't converted at all: the PNG would be over the limit anyway.
const MAX_IMAGE_PIXELS: u64 = 256 * 1024 * 1024;
/// The picker's list shows pictures this big (twice its 32-pixel icons, for sharp high-DPI screens).
const THUMB_SIZE: u32 = 64;
/// The picker's size, in points.
const PICKER: (f64, f64) = (380.0, 460.0);
/// How much of a long text the picker is sent, to show and search: enough for any preview, without handing the
/// page megabytes of text for every open.
const PREVIEW_LENGTH: usize = 10_000;

/// One remembered copy. Saved with the same field names as the Mac's ClipItem.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipItem {
    pub id: String,
    /// "text", "image" or "files".
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_file: Option<String>,
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
    /// When it was copied, in milliseconds since 1970.
    #[serde(default)]
    pub date: i64,
}

impl ClipItem {
    fn new(kind: &str) -> Self {
        ClipItem { id: uuid::Uuid::new_v4().to_string(), kind: kind.into(), text: None, files: None, image_file: None, width: 0, height: 0, date: chrono::Utc::now().timestamp_millis() }
    }
    /// What makes two entries the same copy: copying the same thing again moves it to the top instead of adding it twice.
    fn signature(&self) -> String {
        match self.kind.as_str() {
            "text" => format!("t:{}", self.text.as_deref().unwrap_or("")),
            "image" => format!("i:{}", self.image_file.as_deref().unwrap_or("")),
            _ => format!("f:{}", self.files.as_deref().unwrap_or(&[]).join("\n")),
        }
    }
}

/// Puts `item` at the top, taking out an earlier copy of the same thing, and keeps the newest `limit`.
fn remember(items: &mut Vec<ClipItem>, item: ClipItem, limit: usize) {
    let signature = item.signature();
    items.retain(|i| i.signature() != signature);
    items.insert(0, item);
    trim(items, limit);
}
/// Keeps the newest `limit` entries; returns whether any were dropped.
fn trim(items: &mut Vec<ClipItem>, limit: usize) -> bool {
    if items.len() <= limit { return false; }
    items.truncate(limit);
    true
}
/// Settings → Clipboard → Remember: 25, 50, 100 or 200 entries.
fn limit_from(value: &Value) -> usize { value.as_u64().filter(|n| *n > 0).unwrap_or(100).min(1000) as usize }
/// Text too long to keep. UTF-8 never has fewer bytes than UTF-16 has units, so short text isn't counted.
fn too_long(text: &str) -> bool { text.len() > MAX_TEXT_LENGTH && text.encode_utf16().count() > MAX_TEXT_LENGTH }
/// Where the picker goes: just below and right of the pointer, moved back inside the screen's work area if it would
/// run off it. All in physical pixels: `area` is (x, y, width, height).
fn place(pointer: (i32, i32), area: (i32, i32, i32, i32), size: (i32, i32)) -> (i32, i32) {
    let (x, y, w, h) = area;
    let fit = |at: i32, start: i32, room: i32, length: i32| at.min(start + room - length).max(start);
    (fit(pointer.0 + 8, x, w, size.0), fit(pointer.1 + 8, y, h, size.1))
}

// ---- The history ---------------------------------------------------------------------------------

/// What was just copied, as read from the clipboard.
pub enum Content { Text(String), Files(Vec<String>), Image { width: u32, height: u32, rgba: Vec<u8> } }

struct Store { folder: PathBuf, items: Vec<ClipItem> }
static STORE: Mutex<Option<Store>> = Mutex::new(None);
/// Held while a picture's files are written and the entry added, and while unused pictures are deleted, so a picture
/// just written is never deleted before its entry is in the history. Always taken before STORE.
static FILES: Mutex<()> = Mutex::new(());
/// The clipboard, and what was on it at the last look. Held while reading it and while putting an entry back, so
/// what Still puts back is taken as seen rather than remembered again as a new copy.
struct Io { board: Option<arboard::Clipboard>, watch: Watch }
static IO: Mutex<Option<Io>> = Mutex::new(None);
/// The window that was in front when the picker opened, to paste into (Windows).
#[cfg(windows)]
static PREVIOUS: std::sync::atomic::AtomicIsize = std::sync::atomic::AtomicIsize::new(0);

fn images(folder: &Path) -> PathBuf { folder.join("images") }
fn small_name(file: &str) -> String { file.replace(".png", "-small.png") }

/// Loads the saved history and starts watching the clipboard.
pub fn start(app: &AppHandle) {
    let Ok(data) = app.path().app_data_dir() else { return };
    let folder = data.join("clipboard");
    let _ = std::fs::create_dir_all(images(&folder));
    // Copies can be private: only this account may read them.
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        for dir in [folder.clone(), images(&folder)] { let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)); }
    }
    let items = load(&folder);
    *STORE.lock().unwrap() = Some(Store { folder, items });
    let app = app.clone();
    let _ = std::thread::Builder::new().name("clipboard-history".into()).spawn(move || watch(app));
}

fn load(folder: &Path) -> Vec<ClipItem> {
    let file = folder.join("history.json");
    let Ok(bytes) = std::fs::read(&file) else { return Vec::new() };
    match serde_json::from_slice::<Vec<ClipItem>>(&bytes) {
        Ok(items) => items,
        Err(_) => {
            // Kept aside rather than written over by the next copy.
            let _ = std::fs::rename(&file, folder.join(format!("history-damaged-{}.json", chrono::Utc::now().timestamp())));
            Vec::new()
        }
    }
}

fn enabled(app: &AppHandle) -> bool { crate::setting(app, "clipboard.enabled").as_bool().unwrap_or(true) }
fn limit(app: &AppHandle) -> usize { limit_from(&crate::setting(app, "clipboard.limit")) }

/// The clipboard, opened once and kept: on Linux what Still puts on the clipboard is only there while it's open.
fn board(io: &mut Option<Io>) -> Option<&mut Io> {
    if io.is_none() { *io = Some(Io { board: arboard::Clipboard::new().ok(), watch: Watch::new() }); }
    let io = io.as_mut()?;
    if io.board.is_none() { io.board = arboard::Clipboard::new().ok(); }
    if io.board.is_some() { Some(io) } else { None }
}

fn watch(app: AppHandle) {
    let mut watching = false;
    let mut kept = limit(&app);
    loop {
        std::thread::sleep(Duration::from_millis(500));
        // Settings → Clipboard → Remember made smaller.
        let wanted = limit(&app);
        if wanted != kept { kept = wanted; changed(&app, |items| trim(items, wanted)); }
        if !enabled(&app) { watching = false; continue; }
        let content = {
            let mut io = IO.lock().unwrap();
            let Some(Io { board: Some(board), watch }) = board(&mut io) else { continue };
            // Like the Mac: what was on the clipboard before the history was switched on isn't added to it.
            if !watching { watching = true; watch.reset(board); continue; }
            watch.changed(board)
        };
        let Some(content) = content else { continue };
        let item = match content {
            Content::Text(text) if text.is_empty() || too_long(&text) => continue,
            Content::Text(text) => { let mut item = ClipItem::new("text"); item.text = Some(text); item }
            Content::Files(files) => { let mut item = ClipItem::new("files"); item.files = Some(files); item }
            Content::Image { width, height, rgba } => {
                if width as u64 * height as u64 > MAX_IMAGE_PIXELS { continue; }
                let Some(picture) = image::RgbaImage::from_raw(width, height, rgba) else { continue };
                let png = crate::capture::png(&picture);
                if png.len() > MAX_IMAGE_BYTES { continue; }
                let small = image::imageops::thumbnail(&picture, thumb_side(width, width.max(height)), thumb_side(height, width.max(height)));
                let mut item = ClipItem::new("image");
                item.image_file = Some(format!("{:016x}.png", hash(&png)));
                item.width = width; item.height = height;
                let _files = FILES.lock().unwrap();
                let Some(folder) = STORE.lock().unwrap().as_ref().map(|s| images(&s.folder)) else { continue };
                let name = item.image_file.clone().unwrap_or_default();
                // A picture that couldn't be stored (a full disk, say) isn't remembered: it couldn't be put back later.
                let file = folder.join(&name);
                if !file.exists() && std::fs::write(&file, &png).is_err() { let _ = std::fs::remove_file(&file); continue; }
                let _ = std::fs::write(folder.join(small_name(&name)), crate::capture::png(&small));
                add(&app, item, wanted);
                continue;
            }
        };
        let _files = FILES.lock().unwrap();
        add(&app, item, wanted);
    }
}
fn thumb_side(side: u32, longest: u32) -> u32 {
    if longest <= THUMB_SIZE { side.max(1) } else { ((side as u64 * THUMB_SIZE as u64 / longest as u64) as u32).max(1) }
}
fn hash(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

/// Adds an entry. The caller holds FILES.
fn add(app: &AppHandle, item: ClipItem, limit: usize) {
    let dropped = {
        let mut store = STORE.lock().unwrap();
        let Some(store) = store.as_mut() else { return };
        let before = store.items.len();
        remember(&mut store.items, item, limit);
        save(&store.folder, &store.items);
        store.items.len() <= before
    };
    if dropped { clean_images(); }
    crate::broadcast(app, "clipboard:changed", Value::Null);
}

/// Changes the history with `change` (which returns whether it changed anything), then saves it and tidies up.
fn changed(app: &AppHandle, change: impl FnOnce(&mut Vec<ClipItem>) -> bool) {
    let _files = FILES.lock().unwrap();
    {
        let mut store = STORE.lock().unwrap();
        let Some(store) = store.as_mut() else { return };
        if !change(&mut store.items) { return; }
        save(&store.folder, &store.items);
    }
    clean_images();
    crate::broadcast(app, "clipboard:changed", Value::Null);
}

/// Deletes pictures no entry uses any more. The caller holds FILES.
fn clean_images() {
    let Some((folder, keep)) = STORE.lock().unwrap().as_ref().map(|s| {
        let keep: std::collections::HashSet<String> = s.items.iter().filter_map(|i| i.image_file.clone()).flat_map(|f| [small_name(&f), f]).collect();
        (images(&s.folder), keep)
    }) else { return };
    let Ok(entries) = std::fs::read_dir(&folder) else { return };
    for entry in entries.flatten() {
        if !keep.contains(&entry.file_name().to_string_lossy().to_string()) { let _ = std::fs::remove_file(entry.path()); }
    }
}

/// The history waiting to be written, and the lock held while writing it. Writing up to 200 long entries is slow,
/// so it's done on a thread of its own; whichever write runs takes the newest history, so they land in order.
static PENDING: Mutex<Option<(PathBuf, Vec<ClipItem>)>> = Mutex::new(None);
static WRITING: Mutex<()> = Mutex::new(());
fn save(folder: &Path, items: &[ClipItem]) {
    *PENDING.lock().unwrap() = Some((folder.to_path_buf(), items.to_vec()));
    std::thread::spawn(write_pending);
}
fn write_pending() {
    let _writing = WRITING.lock().unwrap();
    let Some((folder, items)) = PENDING.lock().unwrap().take() else { return };
    let Ok(json) = serde_json::to_vec(&items) else { return };
    // Written beside the old file and renamed into place, so a crash mid-write never loses the whole history.
    let (file, temp) = (folder.join("history.json"), folder.join("history.json.tmp"));
    if std::fs::write(&temp, json).and_then(|_| std::fs::rename(&temp, &file)).is_err() { let _ = std::fs::remove_file(&temp); }
}
/// Waits for the history to reach the disk, for quitting, so the last thing copied isn't forgotten.
pub fn finish_writing() { write_pending(); }

// ---- Reading the clipboard (Windows) ---------------------------------------------------------------

#[cfg(not(windows))]
use unix::Watch;

/// Windows counts every change to the clipboard, so a look costs nothing until something new is copied.
#[cfg(windows)]
struct Watch { last: Option<u32> }
#[cfg(windows)]
impl Watch {
    fn new() -> Self { Watch { last: None } }
    fn changed(&mut self, board: &mut arboard::Clipboard) -> Option<Content> {
        let now = clipboard_win::seq_num().map(|n| n.get());
        if now == self.last { return None; }
        let first = self.last.is_none();
        self.last = now;
        if first || marked_private() { return None; }
        if let Ok(files) = board.get().file_list() {
            if !files.is_empty() { return Some(Content::Files(files.iter().map(|f| f.to_string_lossy().into_owned()).collect())); }
        }
        if let Ok(text) = board.get_text() { return Some(Content::Text(text)); }
        board.get_image().ok().map(|image| Content::Image { width: image.width as u32, height: image.height as u32, rgba: image.bytes.into_owned() })
    }
    fn reset(&mut self, _board: &mut arboard::Clipboard) { self.last = clipboard_win::seq_num().map(|n| n.get()); }
}

/// Whether the app that copied asked clipboard managers not to keep it, as password managers do: Windows' formats
/// for "leave this out of clipboard monitoring" and "leave this out of clipboard history".
#[cfg(windows)]
fn marked_private() -> bool {
    use clipboard_win::{is_format_avail, register_format};
    for name in ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"] {
        if register_format(name).map_or(false, |f| is_format_avail(f.get())) { return true; }
    }
    // Left out of history only when the format holds a zero.
    let Some(format) = register_format("CanIncludeInClipboardHistory") else { return false };
    if !is_format_avail(format.get()) { return false; }
    // When the clipboard can't be opened to check, the copy is taken as private rather than kept.
    let Ok(_open) = clipboard_win::Clipboard::new_attempts(10) else { return true };
    let mut value = [0u8; 4];
    matches!(clipboard_win::raw::get(format.get(), &mut value), Ok(4)) && u32::from_ne_bytes(value) == 0
}

// ---- Putting an entry back, and pasting it ---------------------------------------------------------

/// Whether Still can press Ctrl+V for the app in front: on Windows, and in an X11 session. Wayland doesn't let an app
/// type into another.
fn can_paste() -> bool {
    if cfg!(windows) { return true; }
    cfg!(target_os = "linux") && !crate::is_wayland() && std::env::var_os("DISPLAY").is_some()
}

/// Puts an entry back on the clipboard and at the top of the history. A picture whose file has gone can't be put
/// back: the entry is dropped and what's on the clipboard now is left alone.
fn restore(app: &AppHandle, id: &str) -> Result<(), String> {
    let (item, folder) = {
        let store = STORE.lock().unwrap();
        let store = store.as_ref().ok_or("Clipboard History isn’t ready yet.")?;
        (store.items.iter().find(|i| i.id == id).cloned(), images(&store.folder))
    };
    let item = item.ok_or("That item is no longer in Clipboard History.")?;
    let picture = if item.kind == "image" {
        let read = item.image_file.as_ref().and_then(|f| std::fs::read(folder.join(f)).ok()).and_then(|bytes| crate::capture::decode(&bytes));
        if read.is_none() {
            changed(app, |items| { items.retain(|i| i.id != item.id); true });
            return Err("That picture is no longer saved, so it was taken off the list.".into());
        }
        read
    } else { None };
    {
        let mut io = IO.lock().unwrap();
        let Some(Io { board: Some(board), watch }) = board(&mut io) else { return Err("The clipboard isn’t available right now.".into()) };
        match (item.kind.as_str(), &picture) {
            ("image", Some(picture)) => crate::copy_image(app, picture)?,
            ("files", _) => {
                let files: Vec<PathBuf> = item.files.clone().unwrap_or_default().into_iter().map(PathBuf::from).collect();
                board.set().file_list(&files).map_err(|e| e.to_string())?;
            }
            _ => board.set_text(item.text.clone().unwrap_or_default()).map_err(|e| e.to_string())?,
        }
        // What was just put back isn't a new copy.
        watch.reset(board);
    }
    let limit = limit(app);
    changed(app, |items| {
        let Some(mut moved) = items.iter().find(|i| i.id == item.id).cloned() else { return false };
        moved.date = chrono::Utc::now().timestamp_millis();
        remember(items, moved, limit);
        true
    });
    Ok(())
}

/// Presses Ctrl+V for the window that was in front before the picker opened.
#[cfg(windows)]
fn send_paste() -> bool {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_CONTROL};
    // Windows matches Ctrl shortcuts by virtual key, so V is V whatever the keyboard layout.
    const VK_V: u16 = 0x56;
    let key = |vk: u16, up: bool| INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 } } };
    let inputs = [key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)];
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    sent as usize == inputs.len()
}
#[cfg(windows)]
fn front_window() -> isize { unsafe { windows_sys::Win32::UI::WindowsAndMessaging::GetForegroundWindow() as isize } }
#[cfg(windows)]
fn bring_back(window: isize) { if window != 0 { unsafe { windows_sys::Win32::UI::WindowsAndMessaging::SetForegroundWindow(window as _); } } }

/// Opens the picker near the pointer, or closes it when it's already open (pressing the shortcut again).
pub fn open_picker(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("clipboard") { let _ = win.close(); return; }
    #[cfg(windows)] PREVIOUS.store(front_window(), std::sync::atomic::Ordering::SeqCst);
    let (w, h) = PICKER;
    let built = crate::glass(crate::builder(app, "clipboard", "clipboard.html", json!({})))
        .title("Clipboard History").inner_size(w, h).decorations(false).resizable(false)
        .always_on_top(true).skip_taskbar(true).visible_on_all_workspaces(true).build();
    let Ok(win) = built else { return };
    if let (Ok(pointer), Some(monitor)) = (app.cursor_position(), crate::pointer_monitor(app)) {
        let (area, scale) = (monitor.work_area(), monitor.scale_factor());
        let (x, y) = place((pointer.x as i32, pointer.y as i32), (area.position.x, area.position.y, area.size.width as i32, area.size.height as i32), ((w * scale) as i32, (h * scale) as i32));
        let _ = win.set_position(PhysicalPosition::new(x, y));
        // Moving to a screen with a different scale can change the window's size; this keeps it as asked.
        let _ = win.set_size(tauri::LogicalSize::new(w, h));
    }
    let _ = win.show();
    crate::take_focus(&win);
}

// ---- Commands ------------------------------------------------------------------------------------

/// The history for the picker and Settings, newest first, with where each picture is.
#[tauri::command]
pub async fn clipboard_list(app: AppHandle) -> Value {
    let (items, folder) = match STORE.lock().unwrap().as_ref() { Some(s) => (s.items.clone(), images(&s.folder)), None => (Vec::new(), PathBuf::new()) };
    let items: Vec<Value> = items.iter().map(|item| {
        let mut value = serde_json::to_value(item).unwrap_or(Value::Null);
        if let Some(text) = item.text.as_deref().filter(|t| t.len() > PREVIEW_LENGTH) {
            let mut end = PREVIEW_LENGTH;
            while !text.is_char_boundary(end) { end -= 1; }
            value["text"] = json!(&text[..end]);
        }
        if let Some(file) = &item.image_file {
            value["image"] = json!(folder.join(file));
            value["thumb"] = json!(folder.join(small_name(file)));
        }
        value
    }).collect();
    json!({
        "enabled": enabled(&app),
        "pasteAutomatically": crate::setting(&app, "clipboard.pasteAutomatically").as_bool().unwrap_or(false),
        "canPaste": can_paste(),
        "items": items,
    })
}

/// Puts an entry back on the clipboard and, with "Paste automatically" on, closes the picker and pastes it into the
/// app that was in front. Returns whether it was pasted.
#[tauri::command]
pub async fn clipboard_choose(app: AppHandle, window: tauri::Window, id: String) -> Result<bool, String> {
    crate::blocking(move || {
        restore(&app, &id)?;
        let wanted = crate::setting(&app, "clipboard.pasteAutomatically").as_bool().unwrap_or(false);
        if !wanted || !can_paste() { return Ok(false); }
        // The app goes back in front while the picker still has the focus Windows asks for, then the picker goes.
        #[cfg(windows)] bring_back(PREVIOUS.load(std::sync::atomic::Ordering::SeqCst));
        let _ = window.hide();
        std::thread::sleep(Duration::from_millis(if cfg!(windows) { 60 } else { 150 }));
        #[cfg(windows)] let pasted = send_paste();
        #[cfg(not(windows))] let pasted = unix::paste();
        let _ = window.close();
        Ok(pasted)
    }).await
}

#[tauri::command]
pub async fn clipboard_remove(app: AppHandle, id: String) {
    crate::blocking(move || changed(&app, |items| { let before = items.len(); items.retain(|i| i.id != id); items.len() != before })).await
}

#[tauri::command]
pub async fn clipboard_clear(app: AppHandle) {
    crate::blocking(move || changed(&app, |items| { let any = !items.is_empty(); items.clear(); any })).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(t: &str) -> ClipItem { let mut i = ClipItem::new("text"); i.text = Some(t.into()); i }

    #[test]
    fn copying_the_same_thing_again_moves_it_to_the_top() {
        let mut items = Vec::new();
        for t in ["one", "two", "three"] { remember(&mut items, text(t), 100); }
        remember(&mut items, text("one"), 100);
        let order: Vec<_> = items.iter().map(|i| i.text.clone().unwrap()).collect();
        assert_eq!(order, ["one", "three", "two"]);
        // A file and a text that read the same are different copies.
        let mut file = ClipItem::new("files"); file.files = Some(vec!["one".into()]);
        remember(&mut items, file, 100);
        assert_eq!(items.len(), 4);
    }

    #[test]
    fn keeps_only_the_newest_up_to_the_limit() {
        let mut items = Vec::new();
        for n in 0..30 { remember(&mut items, text(&n.to_string()), 25); }
        assert_eq!(items.len(), 25);
        assert_eq!(items[0].text.as_deref(), Some("29"));
        assert!(trim(&mut items, 10));
        assert!(!trim(&mut items, 10));
        assert_eq!(items.last().unwrap().text.as_deref(), Some("20"));
        assert_eq!(limit_from(&json!(50)), 50);
        assert_eq!(limit_from(&Value::Null), 100);
        assert_eq!(limit_from(&json!(0)), 100);
    }

    #[test]
    fn very_long_text_is_left_out() {
        assert!(!too_long("hello"));
        assert!(!too_long(&"é".repeat(MAX_TEXT_LENGTH)));
        assert!(too_long(&"a".repeat(MAX_TEXT_LENGTH + 1)));
    }

    #[test]
    fn a_saved_history_reads_back() {
        let saved = r#"[{"id":"A1","kind":"image","imageFile":"abc.png","width":10,"height":20,"date":1,"source":"Preview"},{"id":"B2","kind":"files","files":["/tmp/a.txt"]}]"#;
        let items: Vec<ClipItem> = serde_json::from_str(saved).unwrap();
        assert_eq!(items[0].image_file.as_deref(), Some("abc.png"));
        assert_eq!(items[1].signature(), "f:/tmp/a.txt");
        assert!(!serde_json::to_string(&items[1]).unwrap().contains("imageFile"));
    }

    #[test]
    fn the_picker_stays_on_screen() {
        let area = (0, 0, 1920, 1040);
        assert_eq!(place((100, 100), area, (380, 460)), (108, 108));
        assert_eq!(place((1900, 1000), area, (380, 460)), (1540, 580));
        // A second screen to the left of the main one.
        assert_eq!(place((-10, 5), (-1280, 0, 1280, 1000), (380, 460)), (-380, 13));
        assert_eq!(thumb_side(4000, 4000), THUMB_SIZE);
        assert_eq!(thumb_side(10, 4000), 1);
        assert_eq!(thumb_side(20, 30), 20);
    }
}
