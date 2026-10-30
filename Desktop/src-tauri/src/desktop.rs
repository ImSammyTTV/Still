//! Hides the desktop icons while the screen is being grabbed, on Windows. Linux has no way that works
//! across desktops (each one draws its icons differently, and the settings that hide them outlive a crash),
//! so `icons_visible` says no there and nothing here runs.
//!
//! Icons must always come back. Hiding only flips the visibility of Explorer's icon list, which Windows
//! doesn't save, but it would last until Explorer restarts if Still died first. So before hiding, Still
//! starts a copy of itself that only waits on a pipe. If the pipe closes without a word, Still has gone, for
//! whatever reason, and that copy shows the icons. A marker file catches the last case, both processes
//! being killed together: the next start of Still sees it and shows them.

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
    /// False when the user has turned desktop icons off, so that showing them later can't undo that choice.
    pub fn icons_visible() -> bool { icon_list().is_some_and(|list| unsafe { IsWindowVisible(list) != 0 }) }
    /// Asynchronous, so a hung Explorer can't hold up a capture. SW_SHOWNA leaves the focus where it is.
    pub fn set_icons_visible(visible: bool) {
        if let Some(list) = icon_list() { unsafe { ShowWindowAsync(list, if visible { SW_SHOWNA } else { SW_HIDE }); } }
    }
}

#[cfg(not(windows))]
mod shell {
    pub fn icons_visible() -> bool { false }
    pub fn set_icons_visible(_visible: bool) {}
}

fn marker() -> PathBuf { private_temp().join("still-icons-hidden") }

/// Icons stay hidden for as long as this is alive. Dropping it brings them back.
pub struct Hidden { watchdog: Child, marker: PathBuf }

impl Drop for Hidden {
    fn drop(&mut self) {
        shell::set_icons_visible(true);
        // A word down the pipe, unlike a closed pipe, tells the watchdog there's nothing left to do.
        if let Some(mut pipe) = self.watchdog.stdin.take() { let _ = pipe.write_all(b"x"); }
        let _ = std::fs::remove_file(&self.marker);
    }
}

/// Hides the icons if the setting is on, they're showing, and the watchdog is running. Nothing is hidden
/// without the watchdog. Waits for the desktop to repaint before returning.
pub fn hide(app: &AppHandle) -> Option<Hidden> {
    if !setting(app, "hideDesktopIcons").as_bool().unwrap_or(false) || !shell::icons_visible() { return None; }
    let exe = std::env::current_exe().ok()?;
    let marker = marker();
    let _ = std::fs::write(&marker, "");
    let mut command = Command::new(exe);
    command.arg(format!("{WATCH}{}", marker.display())).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)] { use std::os::windows::process::CommandExt; command.creation_flags(0x0800_0000); } // CREATE_NO_WINDOW
    let Ok(watchdog) = command.spawn() else { let _ = std::fs::remove_file(&marker); return None };
    shell::set_icons_visible(false);
    std::thread::sleep(Duration::from_millis(150));
    Some(Hidden { watchdog, marker })
}

/// True when Still went away without releasing the icons: the pipe closed with no word sent.
fn abandoned(mut pipe: impl Read) -> bool { !matches!(pipe.read(&mut [0u8; 1]), Ok(n) if n > 0) }

fn restore(marker: &Path) {
    shell::set_icons_visible(true);
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
    fn restoring_clears_the_marker() {
        let file = std::env::temp_dir().join(format!("still-marker-{}", uuid::Uuid::new_v4()));
        std::fs::write(&file, "").unwrap();
        restore(&file);
        assert!(!file.exists());
    }
}
