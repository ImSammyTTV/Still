//! Clicks and keys for the recording overlays, and where the camera bubble sits.
//!
//! Input is sampled about a hundred times a second rather than hooked. No hook or event stream ever hands
//! Still what is typed: with "Shortcuts only" on, the keyboard isn't read at all unless Ctrl, Alt or Win/Super
//! is held, which `Tracker::step` decides. What it finds goes to the on-screen overlay and nowhere else:
//! nothing here writes to disk or a log.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

const POLL: Duration = Duration::from_millis(10);

/// A rectangle on the desktop, in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Area { pub x: f64, pub y: f64, pub w: f64, pub h: f64 }

impl Area {
    /// How far across the area a point is, from 0 to 1 each way, or nothing if it's outside.
    pub fn locate(&self, x: f64, y: f64) -> Option<(f64, f64)> {
        if self.w <= 0.0 || self.h <= 0.0 || x < self.x || y < self.y || x >= self.x + self.w || y >= self.y + self.h { return None; }
        Some(((x - self.x) / self.w, (y - self.y) / self.h))
    }
}

/// The bubble starts in the recorded area's bottom right corner, so it's in the video until it's dragged out,
/// but never off the display: a small selection at the screen edge pushes it back on.
pub fn bubble_origin(area: Area, display: Area, size: f64, margin: f64) -> (i32, i32) {
    let keep = |value: f64, low: f64, high: f64| value.min(high).max(low);
    let x = keep(area.x + area.w - size - margin, display.x, display.x + display.w - size);
    let y = keep(area.y + area.h - size - margin, display.y, display.y + display.h - size);
    (x.round() as i32, y.round() as i32)
}

/// A hand-edited settings file can't make the bubble tiny or larger than the screen.
pub fn bubble_size(value: Option<f64>) -> f64 { value.filter(|v| v.is_finite()).unwrap_or(180.0).clamp(100.0, 360.0) }

/// Wayland keeps every window's input to itself, and XWayland only sees X11 windows, so a session with a
/// Wayland compositor can't show clicks or keys even when DISPLAY is set (`is_wayland` is about capture,
/// where XWayland does help). Each value is the environment variable, if set.
pub fn x11_input(session_type: Option<&str>, wayland_display: Option<&str>, display: Option<&str>) -> bool {
    let set = |v: Option<&str>| v.map(|s| !s.is_empty()).unwrap_or(false);
    session_type != Some("wayland") && !set(wayland_display) && set(display)
}

/// Whether this desktop lets Still see clicks and keys made in other apps.
pub fn available() -> bool {
    let var = |name: &str| std::env::var(name).ok();
    cfg!(windows) || (cfg!(target_os = "linux") && x11_input(var("XDG_SESSION_TYPE").as_deref(), var("WAYLAND_DISPLAY").as_deref(), var("DISPLAY").as_deref()))
}

// ---- Tracking ------------------------------------------------------------------------------------

#[derive(Clone, Copy, Default)]
pub struct Mods { pub ctrl: bool, pub alt: bool, pub shift: bool, pub win: bool, pub altgr: bool }

impl Mods {
    /// AltGr types characters: "@" on a German keyboard is Windows' Ctrl+Alt+Q, and it isn't a shortcut.
    fn shortcut(&self) -> bool { !self.altgr && (self.ctrl || self.alt || self.win) }
    fn label(&self, key: &str) -> String {
        let win = if cfg!(windows) { "Win" } else { "Super" };
        let held = [(self.ctrl && !self.altgr, "Ctrl"), (self.alt && !self.altgr, "Alt"), (self.shift, "Shift"), (self.win, win)];
        held.iter().filter(|(on, _)| *on).map(|(_, name)| *name).chain([key]).collect::<Vec<_>>().join(" + ")
    }
}

#[derive(Clone, Copy, Default)]
pub struct Pointer { pub x: f64, pub y: f64, pub left: bool, pub right: bool }

/// One way of reading the desktop. Each call reads only what it names, so the tracker can leave the keyboard
/// alone. `None` means the desktop has gone away.
pub trait Source {
    fn pointer(&mut self) -> Option<Pointer>;
    fn mods(&mut self) -> Option<Mods>;
    /// The keys down right now, as platform key codes.
    fn keys(&mut self, down: &mut Vec<u32>);
    /// The name to show for a key code. Modifiers have none.
    fn label(&self, key: u32) -> Option<String>;
}

#[derive(Clone, Copy)]
pub struct Options { pub area: Area, pub clicks: bool, pub keys: bool, pub shortcuts_only: bool }

#[derive(Debug, PartialEq)]
pub enum Mark { Click { x: f64, y: f64 }, Keys(String) }

pub struct Tracker { options: Options, left: bool, right: bool, reading: bool, held: Vec<u32>, down: Vec<u32> }

impl Tracker {
    pub fn new(options: Options) -> Self { Tracker { options, left: false, right: false, reading: false, held: Vec::new(), down: Vec::new() } }

    pub fn step(&mut self, source: &mut impl Source) -> Option<Vec<Mark>> {
        let mut marks = Vec::new();
        if self.options.clicks {
            let p = source.pointer()?;
            let pressed = (p.left && !self.left) || (p.right && !self.right);
            (self.left, self.right) = (p.left, p.right);
            if let Some((x, y)) = self.options.area.locate(p.x, p.y).filter(|_| pressed) { marks.push(Mark::Click { x, y }); }
        }
        if !self.options.keys { return Some(marks); }
        let mods = source.mods()?;
        if self.options.shortcuts_only && !mods.shortcut() {
            self.reading = false; self.held.clear();
            return Some(marks);
        }
        self.down.clear();
        source.keys(&mut self.down);
        // Whatever is already down the first time the keyboard is read was pressed before reading began: it
        // could be the end of a typed word, not part of the shortcut.
        if self.reading { for key in self.down.iter().filter(|k| !self.held.contains(k)) { if let Some(label) = source.label(*key) { marks.push(Mark::Keys(mods.label(&label))); } } }
        self.reading = true;
        std::mem::swap(&mut self.held, &mut self.down);
        Some(marks)
    }
}

/// Stops the sampling thread when told to or when dropped; a sample in progress can't report after that.
pub struct Listener { stop: Arc<AtomicBool> }

impl Drop for Listener { fn drop(&mut self) { self.stop.store(true, Ordering::SeqCst); } }

pub fn listen(options: Options, emit: impl Fn(Mark) + Send + 'static) -> Result<Listener, String> {
    let mut source = native::open()?;
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    std::thread::Builder::new().name("still-marks".into()).spawn(move || {
        let mut tracker = Tracker::new(options);
        while !stopped.load(Ordering::SeqCst) {
            let Some(marks) = tracker.step(&mut source) else { return };
            for mark in marks { if !stopped.load(Ordering::SeqCst) { emit(mark); } }
            std::thread::sleep(POLL);
        }
    }).map_err(|e| e.to_string())?;
    Ok(Listener { stop })
}

// ---- Key names -----------------------------------------------------------------------------------

/// Names for Windows virtual-key codes. Letters and digits already follow the keyboard layout.
#[cfg_attr(not(windows), allow(dead_code))]
fn vk_label(vk: u32) -> Option<String> {
    let name = match vk {
        0x30..=0x39 | 0x41..=0x5A => return char::from_u32(vk).map(String::from),
        0x60..=0x69 => return char::from_u32(vk - 0x60 + 0x30).map(String::from),
        0x70..=0x87 => return Some(format!("F{}", vk - 0x6F)),
        0x08 => "Backspace", 0x09 => "Tab", 0x0D => "Enter", 0x13 => "Pause", 0x1B => "Esc", 0x20 => "Space",
        0x21 => "PgUp", 0x22 => "PgDn", 0x23 => "End", 0x24 => "Home", 0x25 => "Left", 0x26 => "Up", 0x27 => "Right", 0x28 => "Down",
        0x2C => "PrtSc", 0x2D => "Ins", 0x2E => "Delete",
        0x6A => "*", 0x6B | 0xBB => "+", 0x6D | 0xBD => "-", 0x6E | 0xBE => ".", 0x6F | 0xBF => "/",
        0xBA => ";", 0xBC => ",", 0xC0 => "`", 0xDB => "[", 0xDC => "\\", 0xDD => "]", 0xDE => "'",
        _ => return None,
    };
    Some(name.to_string())
}

/// Names for X11 keysyms. The server maps key codes to keysyms with the current layout.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn keysym_label(sym: u32) -> Option<String> {
    let name = match sym {
        0x20 => "Space",
        0x21..=0x7E | 0xA1..=0xFF => return char::from_u32(sym).map(|c| c.to_uppercase().collect()),
        0x0100_0100..=0x0110_FFFF => return char::from_u32(sym - 0x0100_0000).map(|c| c.to_uppercase().collect()),
        0xFF08 => "Backspace", 0xFF09 => "Tab", 0xFF0D | 0xFF8D => "Enter", 0xFF13 => "Pause", 0xFF1B => "Esc", 0xFFFF => "Delete",
        0xFF50 => "Home", 0xFF51 => "Left", 0xFF52 => "Up", 0xFF53 => "Right", 0xFF54 => "Down", 0xFF55 => "PgUp", 0xFF56 => "PgDn", 0xFF57 => "End",
        0xFF61 => "PrtSc", 0xFF63 => "Ins", 0xFFAA => "*", 0xFFAB => "+", 0xFFAD => "-", 0xFFAE => ".", 0xFFAF => "/",
        0xFFB0..=0xFFB9 => return char::from_u32(sym - 0xFFB0 + 0x30).map(String::from),
        0xFFBE..=0xFFD5 => return Some(format!("F{}", sym - 0xFFBD)),
        _ => return None,
    };
    Some(name.to_string())
}

// ---- Reading the desktop -------------------------------------------------------------------------

#[cfg(windows)]
mod native {
    use super::{vk_label, Mods, Pointer, Source};
    use windows_sys::Win32::Foundation::POINT;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
    use windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos;

    const LBUTTON: i32 = 0x01;
    const RBUTTON: i32 = 0x02;
    const SHIFT: i32 = 0x10;
    const CONTROL: i32 = 0x11;
    const MENU: i32 = 0x12;
    const LWIN: i32 = 0x5B;
    const RWIN: i32 = 0x5C;
    const RMENU: i32 = 0xA5;

    pub struct Native { codes: Vec<u32> }

    fn state(vk: i32) -> i16 { unsafe { GetAsyncKeyState(vk) } }
    fn held(vk: i32) -> bool { state(vk) < 0 }

    pub fn open() -> Result<Native, String> {
        // The state's low bit means "pressed since the last look": clear what's left over from before.
        state(LBUTTON); state(RBUTTON);
        Ok(Native { codes: (0x08..=0xFF).filter(|vk| vk_label(*vk).is_some()).collect() })
    }

    impl Source for Native {
        fn pointer(&mut self) -> Option<Pointer> {
            let mut point = POINT { x: 0, y: 0 };
            if unsafe { GetCursorPos(&mut point) } == 0 { return Some(Pointer::default()); } // Fails on the secure desktop; carry on.
            // The low bit catches a tap too quick to be held at either look. Keys never use it: it would
            // report plain typing from before a shortcut.
            Some(Pointer { x: point.x as f64, y: point.y as f64, left: state(LBUTTON) != 0, right: state(RBUTTON) != 0 })
        }
        fn mods(&mut self) -> Option<Mods> {
            Some(Mods { ctrl: held(CONTROL), alt: held(MENU), shift: held(SHIFT), win: held(LWIN) || held(RWIN), altgr: held(RMENU) })
        }
        fn keys(&mut self, down: &mut Vec<u32>) { down.extend(self.codes.iter().filter(|vk| held(**vk as i32))); }
        fn label(&self, key: u32) -> Option<String> { vk_label(key) }
    }
}

#[cfg(target_os = "linux")]
mod native {
    use super::{keysym_label, Mods, Pointer, Source};
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, KeyButMask, QueryPointerReply, Window};
    use x11rb::rust_connection::RustConnection;

    pub struct Native { conn: RustConnection, root: Window, first: u32, per_key: usize, keysyms: Vec<u32> }

    pub fn open() -> Result<Native, String> {
        let (conn, screen) = x11rb::connect(None).map_err(|e| e.to_string())?;
        let setup = conn.setup();
        let root = setup.roots.get(screen).ok_or("No X11 screen")?.root;
        let (first, last) = (setup.min_keycode, setup.max_keycode);
        let map = conn.get_keyboard_mapping(first, last - first + 1).map_err(|e| e.to_string())?.reply().map_err(|e| e.to_string())?;
        Ok(Native { root, first: first as u32, per_key: map.keysyms_per_keycode as usize, keysyms: map.keysyms, conn })
    }

    impl Native {
        fn query(&self) -> Option<QueryPointerReply> { self.conn.query_pointer(self.root).ok()?.reply().ok() }
    }

    impl Source for Native {
        fn pointer(&mut self) -> Option<Pointer> {
            let p = self.query()?;
            Some(Pointer { x: p.root_x as f64, y: p.root_y as f64, left: p.mask.contains(KeyButMask::BUTTON1), right: p.mask.contains(KeyButMask::BUTTON3) })
        }
        fn mods(&mut self) -> Option<Mods> {
            let mask = self.query()?.mask;
            // Mod1 is Alt, Mod4 is Super and Mod5 is AltGr on the standard keyboard setups.
            Some(Mods { ctrl: mask.contains(KeyButMask::CONTROL), alt: mask.contains(KeyButMask::MOD1), shift: mask.contains(KeyButMask::SHIFT), win: mask.contains(KeyButMask::MOD4), altgr: mask.contains(KeyButMask::MOD5) })
        }
        fn keys(&mut self, down: &mut Vec<u32>) {
            let Some(reply) = self.conn.query_keymap().ok().and_then(|c| c.reply().ok()) else { return };
            for (byte, bits) in reply.keys.iter().enumerate() {
                for bit in 0..8 { if bits & (1 << bit) != 0 { down.push(byte as u32 * 8 + bit); } }
            }
        }
        fn label(&self, key: u32) -> Option<String> {
            // The first keysym is the key's own, unshifted symbol.
            self.keysyms.get(key.checked_sub(self.first)? as usize * self.per_key).copied().and_then(keysym_label)
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod native {
    use super::{Mods, Pointer, Source};
    pub struct Native;
    pub fn open() -> Result<Native, String> { Err("Clicks and keys are only shown on Windows and Linux.".into()) }
    impl Source for Native {
        fn pointer(&mut self) -> Option<Pointer> { None }
        fn mods(&mut self) -> Option<Mods> { None }
        fn keys(&mut self, _: &mut Vec<u32>) {}
        fn label(&self, _: u32) -> Option<String> { None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WHOLE: Area = Area { x: 0.0, y: 0.0, w: 1000.0, h: 500.0 };
    const CTRL: Mods = Mods { ctrl: true, alt: false, shift: false, win: false, altgr: false };
    const A: u32 = 65;
    const C: u32 = 67;

    /// A scripted desktop that counts how often the keyboard is read.
    #[derive(Default)]
    struct Fake { pointer: Pointer, mods: Mods, down: Vec<u32>, pointer_reads: usize, mods_reads: usize, key_reads: usize, gone: bool }

    impl Source for Fake {
        fn pointer(&mut self) -> Option<Pointer> { self.pointer_reads += 1; (!self.gone).then_some(self.pointer) }
        fn mods(&mut self) -> Option<Mods> { self.mods_reads += 1; (!self.gone).then_some(self.mods) }
        fn keys(&mut self, down: &mut Vec<u32>) { self.key_reads += 1; down.extend(&self.down); }
        fn label(&self, key: u32) -> Option<String> { vk_label(key) }
    }

    fn tracker(clicks: bool, keys: bool, shortcuts_only: bool) -> Tracker { Tracker::new(Options { area: WHOLE, clicks, keys, shortcuts_only }) }
    fn step(t: &mut Tracker, f: &mut Fake) -> Vec<Mark> { t.step(f).unwrap() }

    #[test]
    fn shortcuts_only_never_reads_the_keyboard_while_typing() {
        let (mut t, mut f) = (tracker(false, true, true), Fake::default());
        for key in [A, C, 0x20, 0x0D] { f.down = vec![key]; assert!(step(&mut t, &mut f).is_empty()); f.down.clear(); step(&mut t, &mut f); }
        // Shift only makes capitals: it's still typing.
        f.mods.shift = true; f.down = vec![A];
        assert!(step(&mut t, &mut f).is_empty());
        assert_eq!(f.key_reads, 0);
    }

    #[test]
    fn shortcuts_show_with_each_modifier() {
        for (mods, expected) in [
            (CTRL, "Ctrl + C"),
            (Mods { alt: true, ..Mods::default() }, "Alt + C"),
            (Mods { win: true, ..Mods::default() }, if cfg!(windows) { "Win + C" } else { "Super + C" }),
            (Mods { ctrl: true, shift: true, ..Mods::default() }, "Ctrl + Shift + C"),
        ] {
            let (mut t, mut f) = (tracker(false, true, true), Fake { mods, ..Fake::default() });
            assert!(step(&mut t, &mut f).is_empty());
            f.down = vec![C];
            assert_eq!(step(&mut t, &mut f), vec![Mark::Keys(expected.into())]);
        }
    }

    #[test]
    fn a_key_still_down_from_typing_is_not_taken_for_a_shortcut() {
        let (mut t, mut f) = (tracker(false, true, true), Fake { mods: CTRL, down: vec![A], ..Fake::default() });
        assert!(step(&mut t, &mut f).is_empty()); // Ctrl arrived while the "a" of a typed word was on its way up.
        f.down = vec![A, C];
        assert_eq!(step(&mut t, &mut f), vec![Mark::Keys("Ctrl + C".into())]);
    }

    #[test]
    fn altgr_characters_are_typing_not_shortcuts() {
        let (mut t, mut f) = (tracker(false, true, true), Fake { mods: Mods { ctrl: true, alt: true, altgr: true, ..Mods::default() }, down: vec![0x51], ..Fake::default() });
        step(&mut t, &mut f); f.down.clear(); step(&mut t, &mut f); f.down = vec![0x51];
        assert!(step(&mut t, &mut f).is_empty());
        assert_eq!(f.key_reads, 0);
    }

    #[test]
    fn a_held_key_shows_once_and_modifiers_alone_show_nothing() {
        let (mut t, mut f) = (tracker(false, true, false), Fake::default());
        step(&mut t, &mut f);
        f.down = vec![0x10, 0x11, 0x5B]; // Shift, Ctrl and Win codes have no label.
        assert!(step(&mut t, &mut f).is_empty());
        f.down = vec![A];
        assert_eq!(step(&mut t, &mut f), vec![Mark::Keys("A".into())]);
        assert!(step(&mut t, &mut f).is_empty());
        f.down.clear(); step(&mut t, &mut f); f.down = vec![A];
        assert_eq!(step(&mut t, &mut f).len(), 1);
    }

    #[test]
    fn everything_shows_with_shortcuts_only_off() {
        let (mut t, mut f) = (tracker(false, true, false), Fake::default());
        step(&mut t, &mut f);
        f.down = vec![A];
        assert_eq!(step(&mut t, &mut f), vec![Mark::Keys("A".into())]);
        f.down.clear(); f.mods.shift = true; step(&mut t, &mut f); f.down = vec![A];
        assert_eq!(step(&mut t, &mut f), vec![Mark::Keys("Shift + A".into())]);
    }

    #[test]
    fn with_keys_off_nothing_about_the_keyboard_is_read() {
        let (mut t, mut f) = (tracker(true, false, true), Fake { mods: CTRL, down: vec![A], ..Fake::default() });
        step(&mut t, &mut f);
        assert_eq!((f.mods_reads, f.key_reads), (0, 0));
    }

    #[test]
    fn clicks_mark_the_press_inside_the_area() {
        let mut t = Tracker::new(Options { area: Area { x: 100.0, y: 100.0, w: 200.0, h: 100.0 }, clicks: true, keys: false, shortcuts_only: true });
        let mut f = Fake { pointer: Pointer { x: 150.0, y: 125.0, ..Pointer::default() }, ..Fake::default() };
        assert!(step(&mut t, &mut f).is_empty());
        f.pointer.left = true;
        assert_eq!(step(&mut t, &mut f), vec![Mark::Click { x: 0.25, y: 0.25 }]);
        assert!(step(&mut t, &mut f).is_empty()); // Holding or dragging isn't another click.
        f.pointer.left = false; step(&mut t, &mut f);
        f.pointer.right = true;
        assert_eq!(step(&mut t, &mut f).len(), 1);
        f.pointer = Pointer { x: 50.0, y: 50.0, left: true, right: false };
        assert!(step(&mut t, &mut f).is_empty());
        assert_eq!(f.key_reads, 0);
    }

    #[test]
    fn a_lost_desktop_ends_the_listener() {
        let (mut t, mut f) = (tracker(true, true, true), Fake { gone: true, ..Fake::default() });
        assert!(t.step(&mut f).is_none());
    }

    #[test]
    fn global_input_needs_a_plain_x11_session() {
        assert!(x11_input(Some("x11"), None, Some(":0")));
        assert!(x11_input(None, Some(""), Some(":0")));
        assert!(!x11_input(Some("wayland"), Some("wayland-0"), None));
        assert!(!x11_input(Some("wayland"), Some("wayland-0"), Some(":0"))); // XWayland.
        assert!(!x11_input(None, Some("wayland-0"), Some(":0")));
        assert!(!x11_input(Some("x11"), None, None));
    }

    #[test]
    fn the_bubble_starts_in_the_area_and_stays_on_the_display() {
        let display = Area { x: 1920.0, y: 0.0, w: 1920.0, h: 1080.0 };
        assert_eq!(bubble_origin(Area { x: 2000.0, y: 100.0, w: 800.0, h: 600.0 }, display, 180.0, 24.0), (2596, 496));
        assert_eq!(bubble_origin(Area { x: 1920.0, y: 0.0, w: 50.0, h: 50.0 }, display, 180.0, 24.0), (1920, 0));
        assert_eq!(bubble_origin(display, display, 180.0, 24.0), (3636, 876));
    }

    #[test]
    fn bubble_size_stays_sensible() {
        assert_eq!(bubble_size(None), 180.0);
        assert_eq!(bubble_size(Some(240.0)), 240.0);
        assert_eq!(bubble_size(Some(4.0)), 100.0);
        assert_eq!(bubble_size(Some(9000.0)), 360.0);
        assert_eq!(bubble_size(Some(f64::NAN)), 180.0);
    }

    #[test]
    fn windows_keys_have_names_and_modifiers_do_not() {
        assert_eq!(vk_label(0x41).as_deref(), Some("A"));
        assert_eq!(vk_label(0x37).as_deref(), Some("7"));
        assert_eq!(vk_label(0x65).as_deref(), Some("5"));
        assert_eq!(vk_label(0x70).as_deref(), Some("F1"));
        assert_eq!(vk_label(0x7B).as_deref(), Some("F12"));
        assert_eq!(vk_label(0x2E).as_deref(), Some("Delete"));
        assert_eq!(vk_label(0xBF).as_deref(), Some("/"));
        for vk in [0x01, 0x02, 0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0x90, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5] { assert_eq!(vk_label(vk), None); }
    }

    #[test]
    fn x11_keys_have_names_and_modifiers_do_not() {
        assert_eq!(keysym_label(0x61).as_deref(), Some("A"));
        assert_eq!(keysym_label(0x20).as_deref(), Some("Space"));
        assert_eq!(keysym_label(0x2F).as_deref(), Some("/"));
        assert_eq!(keysym_label(0xE9).as_deref(), Some("É"));
        assert_eq!(keysym_label(0x0100_0416).as_deref(), Some("Ж"));
        assert_eq!(keysym_label(0xFF0D).as_deref(), Some("Enter"));
        assert_eq!(keysym_label(0xFF52).as_deref(), Some("Up"));
        assert_eq!(keysym_label(0xFFBE).as_deref(), Some("F1"));
        assert_eq!(keysym_label(0xFFC9).as_deref(), Some("F12"));
        assert_eq!(keysym_label(0xFFB7).as_deref(), Some("7"));
        // Shift, Control, Caps Lock, Alt, Super, Hyper, AltGr, Mode switch, Num Lock, no symbol.
        for sym in [0xFFE1, 0xFFE2, 0xFFE3, 0xFFE4, 0xFFE5, 0xFFE9, 0xFFEA, 0xFFEB, 0xFFEC, 0xFFED, 0xFFEE, 0xFE03, 0xFF7E, 0xFF7F, 0] { assert_eq!(keysym_label(sym), None); }
    }
}
