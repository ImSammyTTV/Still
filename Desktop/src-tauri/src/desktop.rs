//! Hides the desktop icons while the screen is being grabbed. On Windows that flips the visibility of Explorer's icon
//! list. On Linux each desktop draws its icons its own way, so Still knows the common ones (GNOME's desktop icons
//! extension, Xfce, MATE and Cinnamon) and leaves the rest alone; KDE's icons are part of its desktop and can't be
//! hidden on their own.
//!
//! Icons must always come back, and on Linux hiding them changes a saved setting that would outlast Still. So before
//! hiding, Still writes what to put back into a marker file and starts a copy of itself that only waits on a pipe.
//! If the pipe closes without a word, Still has gone, for whatever reason, and that copy puts the icons back. The
//! marker catches the last case, both processes being killed together: the next start of Still sees it and puts
//! them back.

use crate::{private_temp, setting};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use tauri::AppHandle;

const WATCH: &str = "--restore-desktop-icons=";

#[cfg(windows)]
mod shell {
    use std::ptr::null;
    use windows_sys::core::w;
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::WindowsAndMessaging::{FindWindowExW, FindWindowW, IsWindowVisible, ShowWindowAsync, SW_HIDE, SW_SHOWNA};

    /// The icon list lives under Progman, or under a WorkerW once the wallpaper has been animated.
    fn icon_list() -> Option<HWND> {
        unsafe {
            let none: HWND = std::ptr::null_mut();
            let mut view = FindWindowExW(FindWindowW(w!("Progman"), null()), none, w!("SHELLDLL_DefView"), null());
            let mut worker = none;
            while view.is_null() {
                worker = FindWindowExW(none, worker, w!("WorkerW"), null());
                if worker.is_null() { return None; }
                view = FindWindowExW(worker, none, w!("SHELLDLL_DefView"), null());
            }
            let list = FindWindowExW(view, none, w!("SysListView32"), null());
            (!list.is_null()).then_some(list)
        }
    }
    /// What to put back, if the icons are showing. None when the user has turned them off, so that showing them later
    /// can't undo that choice.
    pub fn plan() -> Option<String> { icon_list().is_some_and(|list| unsafe { IsWindowVisible(list) != 0 }).then(|| "windows".into()) }
    /// Asynchronous, so a hung Explorer can't hold up a capture. SW_SHOWNA leaves the focus where it is.
    fn set_visible(visible: bool) {
        if let Some(list) = icon_list() { unsafe { ShowWindowAsync(list, if visible { SW_SHOWNA } else { SW_HIDE }); } }
    }
    pub fn hide(_plan: &str) { set_visible(false) }
    pub fn show(_plan: &str) { set_visible(true) }
    pub const SETTLE_MS: u64 = 150;
}

#[cfg(target_os = "linux")]
mod shell {
    use std::process::{Command, Stdio};

    const DING: &str = "ding@rastersoft.com";

    /// A command's output, trimmed, if it ran and succeeded.
    fn run(program: &str, args: &[&str]) -> Option<String> {
        let out = Command::new(program).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }
    fn desktop() -> String { std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_lowercase() }

    /// What to put back, if this desktop is one Still knows and its icons are showing.
    pub fn plan() -> Option<String> { super::linux_plan(&desktop(), run) }

    pub fn hide(plan: &str) {
        match plan.split_once(':').map_or(plan, |(kind, _)| kind) {
            "xfce" => { run("xfconf-query", &["-c", "xfce4-desktop", "-p", "/desktop-icons/style", "-s", "0"]); }
            "mate" => { run("gsettings", &["set", "org.mate.background", "show-desktop-icons", "false"]); }
            "nemo" => { run("gsettings", &["set", "org.nemo.desktop", "show-desktop-icons", "false"]); }
            "ding" => { run("gnome-extensions", &["disable", DING]); }
            _ => {}
        }
    }
    pub fn show(plan: &str) {
        let (kind, value) = plan.split_once(':').unwrap_or((plan, ""));
        match kind {
            "xfce" => { let style = if value.chars().all(|c| c.is_ascii_digit()) && !value.is_empty() { value } else { "2" }; run("xfconf-query", &["-c", "xfce4-desktop", "-p", "/desktop-icons/style", "-s", style]); }
            "mate" => { run("gsettings", &["set", "org.mate.background", "show-desktop-icons", "true"]); }
            "nemo" => { run("gsettings", &["set", "org.nemo.desktop", "show-desktop-icons", "true"]); }
            "ding" => { run("gnome-extensions", &["enable", DING]); }
            _ => {}
        }
    }
    /// Desktops redraw a moment after the setting changes.
    pub const SETTLE_MS: u64 = 400;
}

#[cfg(not(any(windows, target_os = "linux")))]
mod shell {
    pub fn plan() -> Option<String> { None }
    pub fn hide(_plan: &str) {}
    pub fn show(_plan: &str) {}
    pub const SETTLE_MS: u64 = 0;
}

/// Which way this Linux desktop's icons can be hidden, given its name (XDG_CURRENT_DESKTOP, lower case) and a way to run
/// a command: "xfce:<style to restore>", "mate", "nemo" or "ding". None when its icons aren't showing or it isn't one
/// Still knows.
#[allow(dead_code)]
fn linux_plan(desktop: &str, run: impl Fn(&str, &[&str]) -> Option<String>) -> Option<String> {
    if desktop.contains("xfce") {
        let style = run("xfconf-query", &["-c", "xfce4-desktop", "-p", "/desktop-icons/style"]).unwrap_or_else(|| "2".into());
        return (style != "0" && style.chars().all(|c| c.is_ascii_digit())).then(|| format!("xfce:{style}"));
    }
    if desktop.contains("mate") {
        return (run("gsettings", &["get", "org.mate.background", "show-desktop-icons"])? == "true").then(|| "mate".into());
    }
    if desktop.contains("cinnamon") || desktop.contains("x-cinnamon") {
        return (run("gsettings", &["get", "org.nemo.desktop", "show-desktop-icons"])? == "true").then(|| "nemo".into());
    }
    if desktop.contains("gnome") || desktop.contains("ubuntu") {
        let info = run("gnome-extensions", &["info", "ding@rastersoft.com"])?;
        let enabled = info.lines().any(|l| { let l = l.trim().to_lowercase(); l == "state: enabled" || l == "state: active" || l == "enabled: yes" });
        return enabled.then(|| "ding".into());
    }
    None
}

fn marker() -> PathBuf { private_temp().join("still-icons-hidden") }

/// Icons stay hidden for as long as this is alive. Dropping it brings them back.
pub struct Hidden { watchdog: Child, marker: PathBuf, plan: String }

impl Drop for Hidden {
    fn drop(&mut self) {
        shell::show(&self.plan);
        // A word down the pipe, unlike a closed pipe, tells the watchdog there's nothing left to do.
        if let Some(mut pipe) = self.watchdog.stdin.take() { let _ = pipe.write_all(b"x"); }
        let _ = std::fs::remove_file(&self.marker);
    }
}

/// Hides the icons if the setting is on, they're showing, and the watchdog is running. Nothing is hidden
/// without the watchdog. Waits for the desktop to repaint before returning.
pub fn hide(app: &AppHandle) -> Option<Hidden> {
    if !setting(app, "hideDesktopIcons").as_bool().unwrap_or(false) { return None; }
    let plan = shell::plan()?;
    let exe = std::env::current_exe().ok()?;
    let marker = marker();
    // Nothing is hidden unless the marker says how to bring the icons back.
    std::fs::write(&marker, &plan).ok()?;
    let mut command = Command::new(exe);
    command.arg(format!("{WATCH}{}", marker.display())).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)] { use std::os::windows::process::CommandExt; command.creation_flags(0x0800_0000); } // CREATE_NO_WINDOW
    let Ok(watchdog) = command.spawn() else { let _ = std::fs::remove_file(&marker); return None };
    shell::hide(&plan);
    std::thread::sleep(Duration::from_millis(shell::SETTLE_MS));
    Some(Hidden { watchdog, marker, plan })
}

/// True when Still went away without releasing the icons: the pipe closed with no word sent.
fn abandoned(mut pipe: impl Read) -> bool { !matches!(pipe.read(&mut [0u8; 1]), Ok(n) if n > 0) }

fn restore(marker: &Path) {
    // An older marker is empty: that was always Windows.
    let plan = std::fs::read_to_string(marker).unwrap_or_default();
    shell::show(if plan.trim().is_empty() { "windows" } else { plan.trim() });
    let _ = std::fs::remove_file(marker);
}

/// The watchdog process. Returns true if this run of Still is one, in which case it has done its job.
pub fn watch() -> bool {
    let Some(marker) = std::env::args().find_map(|a| a.strip_prefix(WATCH).map(PathBuf::from)) else { return false };
    if abandoned(std::io::stdin()) { restore(&marker); }
    true
}

/// Called at startup: icons left hidden by a run of Still that died along with its watchdog.
pub fn recover() { let marker = marker(); if marker.exists() { restore(&marker); } }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_closed_pipe_means_still_went_away() {
        assert!(abandoned(std::io::empty()));
        struct Broken;
        impl Read for Broken { fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> { Err(std::io::ErrorKind::BrokenPipe.into()) } }
        assert!(abandoned(Broken));
    }
    #[test]
    fn a_word_on_the_pipe_means_the_icons_are_back() { assert!(!abandoned(&b"x"[..])); }
    #[test]
    fn linux_desktops_are_recognised_and_icons_already_off_are_left_alone() {
        let answers = |pairs: Vec<(&'static str, &'static str)>| move |program: &str, args: &[&str]| -> Option<String> {
            let key = format!("{program} {}", args.join(" "));
            pairs.iter().find(|(k, _)| key.starts_with(k)).map(|(_, v)| v.to_string())
        };
        assert_eq!(linux_plan("xfce", answers(vec![("xfconf-query", "2")])), Some("xfce:2".into()));
        assert_eq!(linux_plan("xfce", answers(vec![("xfconf-query", "0")])), None, "icons already off");
        assert_eq!(linux_plan("mate", answers(vec![("gsettings get org.mate", "true")])), Some("mate".into()));
        assert_eq!(linux_plan("x-cinnamon", answers(vec![("gsettings get org.nemo", "false")])), None);
        assert_eq!(linux_plan("ubuntu:gnome", answers(vec![("gnome-extensions info", "ding@rastersoft.com\n  Name: Desktop Icons\n  State: ENABLED")])), Some("ding".into()));
        assert_eq!(linux_plan("gnome", answers(vec![])), None, "no desktop icons extension");
        assert_eq!(linux_plan("kde", answers(vec![("gsettings", "true")])), None);
    }
    #[test]
    fn restoring_clears_the_marker() {
        let file = std::env::temp_dir().join(format!("still-marker-{}", uuid::Uuid::new_v4()));
        std::fs::write(&file, "").unwrap();
        restore(&file);
        assert!(!file.exists());
    }
}
