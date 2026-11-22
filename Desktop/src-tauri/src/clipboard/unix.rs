//! Clipboard History on Linux: noticing a new copy, telling when it's marked private, and pasting it back.
//! Linux desktops share no change counter, so a new copy is noticed by comparing what's on the clipboard with what
//! was there at the last look.

use super::Content;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::{Duration, Instant};

/// A picture is fetched whole to compare it, so while one sits on the clipboard it's looked at every two seconds
/// rather than every half second. A new text or file copy is still noticed at once.
const IMAGE_INTERVAL: Duration = Duration::from_secs(2);

/// What was on the clipboard at the last look.
pub struct Watch { last: Option<u64>, image_at: Option<Instant>, showing_image: bool }

impl Watch {
    pub fn new() -> Self { Watch { last: None, image_at: None, showing_image: false } }

    /// What has been copied since the last look, or None when nothing new has been (or it's marked private).
    pub fn changed(&mut self, board: &mut arboard::Clipboard) -> Option<Content> {
        let content = match self.read(board) { Some(content) => content, None => return None };
        let mut hasher = DefaultHasher::new();
        match &content {
            Some(Content::Text(text)) => { 1u8.hash(&mut hasher); text.hash(&mut hasher); }
            Some(Content::Files(files)) => { 2u8.hash(&mut hasher); files.hash(&mut hasher); }
            Some(Content::Image { width, height, rgba }) => { 3u8.hash(&mut hasher); width.hash(&mut hasher); height.hash(&mut hasher); rgba.hash(&mut hasher); }
            None => 0u8.hash(&mut hasher),
        }
        let print = hasher.finish();
        if self.last == Some(print) { return None; }
        let first = self.last.is_none();
        self.last = Some(print);
        // The first look only learns what's there; it was copied before Still was watching.
        if first || marked_private() { return None; }
        content
    }

    /// Takes what's on the clipboard now as already seen, so it isn't remembered as a new copy.
    pub fn reset(&mut self, board: &mut arboard::Clipboard) {
        self.last = None;
        self.image_at = None;
        let _ = self.changed(board);
    }

    /// The clipboard's content (Some(None) when it holds nothing Still keeps), or None for "not looked at this time".
    fn read(&mut self, board: &mut arboard::Clipboard) -> Option<Option<Content>> {
        if let Ok(files) = board.get().file_list() {
            if !files.is_empty() {
                self.showing_image = false;
                return Some(Some(Content::Files(files.iter().map(|f| f.to_string_lossy().into_owned()).collect())));
            }
        }
        if let Ok(text) = board.get_text() { self.showing_image = false; return Some(Some(Content::Text(text))); }
        if self.showing_image && self.image_at.map_or(false, |at| at.elapsed() < IMAGE_INTERVAL) { return None; }
        self.image_at = Some(Instant::now());
        match board.get_image() {
            Ok(image) => {
                self.showing_image = true;
                Some(Some(Content::Image { width: image.width as u32, height: image.height as u32, rgba: image.bytes.into_owned() }))
            }
            Err(_) => { self.showing_image = false; Some(None) }
        }
    }
}

/// Whether the app that copied asked clipboard managers not to keep it, as password managers do with the
/// x-kde-passwordManagerHint type. Only X11 lets Still ask; elsewhere a copy is never taken as private.
fn marked_private() -> bool { private_hint().unwrap_or(false) }

fn private_hint() -> Result<bool, Box<dyn std::error::Error>> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, CreateWindowAux, WindowClass};
    use x11rb::protocol::Event;
    if std::env::var_os("DISPLAY").is_none() { return Ok(false); }
    let (conn, screen) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen].root;
    let window = conn.generate_id()?;
    conn.create_window(x11rb::COPY_DEPTH_FROM_PARENT, window, root, 0, 0, 1, 1, 0, WindowClass::INPUT_ONLY, x11rb::COPY_FROM_PARENT, &CreateWindowAux::new())?;
    let mut atoms = Vec::new();
    for name in [&b"CLIPBOARD"[..], b"TARGETS", b"STILL_CLIPBOARD_TARGETS", b"x-kde-passwordManagerHint"] {
        atoms.push(conn.intern_atom(false, name)?.reply()?.atom);
    }
    let (clipboard, targets, property, hint) = (atoms[0], atoms[1], atoms[2], atoms[3]);
    conn.convert_selection(window, clipboard, targets, property, x11rb::CURRENT_TIME)?;
    conn.flush()?;
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        match conn.poll_for_event()? {
            Some(Event::SelectionNotify(event)) if event.requestor == window => {
                if event.property == x11rb::NONE { return Ok(false); }
                let reply = conn.get_property(false, window, property, AtomEnum::ATOM, 0, 1024)?.reply()?;
                let found = reply.value32().map(|mut list| list.any(|atom| atom == hint)).unwrap_or(false);
                return Ok(found);
            }
            Some(_) => {}
            None => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    Ok(false)
}

/// Presses Ctrl+V for the app in front, in an X11 session. The V is whichever key types "v" in the keyboard layout
/// in use, since apps match Ctrl shortcuts by the letter, so it works on layouts that move V. Returns false when it
/// couldn't (no X11, or no such key).
pub fn paste() -> bool { press_paste().unwrap_or(false) }

fn press_paste() -> Result<bool, Box<dyn std::error::Error>> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, KEY_PRESS_EVENT, KEY_RELEASE_EVENT};
    use x11rb::protocol::xtest::ConnectionExt as _;
    use x11rb::wrapper::ConnectionExt as _;
    if std::env::var_os("DISPLAY").is_none() { return Ok(false); }
    let (conn, screen) = x11rb::connect(None)?;
    let (first, last, root) = { let setup = conn.setup(); (setup.min_keycode, setup.max_keycode, setup.roots[screen].root) };
    let map = conn.get_keyboard_mapping(first, last - first + 1)?.reply()?;
    let per = (map.keysyms_per_keycode as usize).max(1);
    let key = |symbol: u32| map.keysyms.chunks(per).position(|syms| syms.contains(&symbol)).map(|i| first + i as u8);
    // Control_L, and the letter v.
    let (Some(control), Some(v)) = (key(0xffe3), key(0x0076)) else { return Ok(false) };
    for (kind, code) in [(KEY_PRESS_EVENT, control), (KEY_PRESS_EVENT, v), (KEY_RELEASE_EVENT, v), (KEY_RELEASE_EVENT, control)] {
        conn.xtest_fake_input(kind, code, x11rb::CURRENT_TIME, root, 0, 0, 0)?;
    }
    conn.sync()?;
    Ok(true)
}
