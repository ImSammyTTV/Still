//! Deleting from History moves the capture to the Recycle Bin (Windows) or the Trash (Linux), as on the Mac, so a
//! capture deleted by mistake can be put back. The file goes there under the capture's title.
use std::path::Path;

/// A file name made from a title, safe on every file system.
pub fn file_name(title: &str, ext: &str) -> String {
    let clean: String = title.chars().map(|c| if "\\/:*?\"<>|".contains(c) || c.is_control() { '-' } else { c }).collect();
    let clean = clean.trim().trim_matches('.').to_string();
    format!("{}.{ext}", if clean.is_empty() { "Capture".to_string() } else { clean })
}

#[cfg(windows)]
pub fn move_to_trash(file: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::{SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW};
    // The list of paths ends with two nulls.
    let mut from: Vec<u16> = file.as_os_str().encode_wide().collect(); from.push(0); from.push(0);
    let mut op: SHFILEOPSTRUCTW = unsafe { std::mem::zeroed() };
    op.wFunc = FO_DELETE; op.pFrom = from.as_ptr(); op.fFlags = (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT) as u16;
    let code = unsafe { SHFileOperationW(&mut op) };
    if code == 0 && op.fAnyOperationsAborted == 0 { Ok(()) } else { Err(format!("Windows couldn’t move it to the Recycle Bin ({code}).")) }
}

#[cfg(not(windows))]
pub fn move_to_trash(file: &Path) -> Result<(), String> {
    // The desktop's own tool knows about trash folders on other drives; the home Trash is the fallback.
    if std::process::Command::new("gio").arg("trash").arg(file).status().map(|s| s.success()).unwrap_or(false) { return Ok(()); }
    let data = std::env::var_os("XDG_DATA_HOME").map(std::path::PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| Path::new(&h).join(".local/share"))).ok_or("No Trash folder")?;
    let (files, info) = (data.join("Trash/files"), data.join("Trash/info"));
    std::fs::create_dir_all(&files).and_then(|_| std::fs::create_dir_all(&info)).map_err(|e| e.to_string())?;
    let name = file.file_name().and_then(|n| n.to_str()).unwrap_or("Capture");
    let (stem, ext) = name.rsplit_once('.').map(|(s, e)| (s.to_string(), format!(".{e}"))).unwrap_or((name.to_string(), String::new()));
    let mut n = 1; let mut target = name.to_string();
    while files.join(&target).exists() || info.join(format!("{target}.trashinfo")).exists() { n += 1; target = format!("{stem} {n}{ext}"); }
    let when = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S");
    let path: String = file.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() || "/-_.~".contains(c) { c.to_string() } else { c.to_string().bytes().map(|b| format!("%{b:02X}")).collect() }).collect();
    std::fs::write(info.join(format!("{target}.trashinfo")), format!("[Trash Info]\nPath={path}\nDeletionDate={when}\n")).map_err(|e| e.to_string())?;
    std::fs::rename(file, files.join(&target)).or_else(|_| std::fs::copy(file, files.join(&target)).map(|_| ()).and_then(|_| std::fs::remove_file(file))).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    #[test]
    fn titles_become_safe_file_names() {
        assert_eq!(super::file_name("Screenshot 2026-11-07 at 10:04:12", "png"), "Screenshot 2026-11-07 at 10-04-12.png");
        assert_eq!(super::file_name("  ..  ", "mp4"), "Capture.mp4");
        assert_eq!(super::file_name("a/b\\c", "png"), "a-b-c.png");
    }
}
