use std::fs;
use std::path::{Path, PathBuf};

pub const EXPORT_TYPES: [&str; 3] = ["mp4", "webm", "gif"];

/// The name a save dialog suggests. A GIF is a new kind of file, a video needs telling apart from its source.
pub fn export_name(title: &str, ext: &str) -> String { if ext == "gif" { title.to_string() } else { format!("{title}-trimmed") } }

/// Not every save dialog adds the extension, and the bytes are one format whatever the name says. A name
/// that had to change wasn't the one the dialog confirmed, so it never lands on an existing file.
pub fn export_path(chosen: PathBuf, ext: &str) -> PathBuf {
    let current = chosen.extension().map(|e| e.to_string_lossy().to_lowercase());
    if current.as_deref() == Some(ext) { return chosen; }
    let stem = if current.as_deref().map(|e| EXPORT_TYPES.contains(&e) || e == "mov").unwrap_or(false) { chosen.with_extension("") } else { chosen };
    let named = |suffix: String| { let mut name = stem.clone().into_os_string(); name.push(suffix); PathBuf::from(name) };
    let mut file = named(format!(".{ext}"));
    let mut n = 2;
    while file.exists() { file = named(format!(" ({n}).{ext}")); n += 1; }
    file
}

pub fn is_same_file(a: &Path, b: &Path) -> bool {
    matches!((fs::canonicalize(a), fs::canonicalize(b)), (Ok(a), Ok(b)) if a == b)
}

/// Moves a finished temporary file over the target in one step, so the target is either the old file or the
/// whole new one. Still's temp folder can be on another drive, where a move isn't possible: then the copy
/// goes next to the target first, so a full disk can't leave half a file in its place.
fn place(temp: &Path, target: &Path) -> Result<(), String> {
    if fs::rename(temp, target).is_ok() { return Ok(()); }
    let part = target.with_file_name(format!(".still-part-{}", uuid::Uuid::new_v4().simple()));
    let moved = fs::copy(temp, &part).and_then(|_| fs::rename(&part, target));
    let _ = fs::remove_file(temp);
    if let Err(e) = moved { let _ = fs::remove_file(&part); return Err(format!("Couldn’t save to {}: {e}", target.display())); }
    Ok(())
}

fn temp_file(folder: &Path) -> PathBuf { folder.join(format!("still-export-{}.tmp", uuid::Uuid::new_v4().simple())) }

pub fn save_bytes(temp_folder: &Path, bytes: &[u8], target: &Path) -> Result<(), String> {
    if bytes.is_empty() { return Err("The export came out empty, so nothing was saved.".into()); }
    let temp = temp_file(temp_folder);
    if let Err(e) = fs::write(&temp, bytes) { let _ = fs::remove_file(&temp); return Err(format!("Couldn’t write the export: {e}")); }
    place(&temp, target)
}

/// An untrimmed export: the recording itself, byte for byte.
pub fn save_copy(temp_folder: &Path, source: &Path, target: &Path) -> Result<(), String> {
    let temp = temp_file(temp_folder);
    if let Err(e) = fs::copy(source, &temp) { let _ = fs::remove_file(&temp); return Err(format!("Couldn’t read the recording: {e}")); }
    place(&temp, target)
}

pub fn clock(seconds: u64) -> String { format!("{}:{:02}", seconds / 60, seconds % 60) }

/// What the tray says while recording: the menu item, and the tooltip Windows shows on hover.
pub fn tray_status(seconds: u64, paused: bool) -> (String, String) {
    let time = clock(seconds);
    if paused { (format!("Stop Recording (paused, {time})"), format!("Still: paused at {time}")) }
    else { (format!("Stop Recording ({time})"), format!("Still: recording {time}")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("still-video-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn saves_through_a_temp_file_and_leaves_nothing_behind() {
        let dir = folder(); let temp = dir.join("temp"); fs::create_dir(&temp).unwrap();
        let target = dir.join("clip.mp4");
        save_bytes(&temp, b"video", &target).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"video");
        assert_eq!(fs::read_dir(&temp).unwrap().count(), 0);
    }

    #[test]
    fn replaces_a_chosen_file_only_when_the_export_succeeded() {
        let dir = folder(); let temp = dir.join("temp"); fs::create_dir(&temp).unwrap();
        let target = dir.join("clip.gif");
        fs::write(&target, b"old").unwrap();
        assert!(save_bytes(&temp, b"", &target).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"old");
        save_bytes(&temp, b"new", &target).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
    }

    #[test]
    fn a_failed_save_reports_why_and_cleans_up() {
        let dir = folder(); let temp = dir.join("temp"); fs::create_dir(&temp).unwrap();
        let error = save_bytes(&temp, b"video", &dir.join("missing").join("clip.mp4")).unwrap_err();
        assert!(error.contains("missing"), "{error}");
        assert_eq!(fs::read_dir(&temp).unwrap().count(), 0);
        assert!(save_bytes(&dir.join("no-temp"), b"video", &dir.join("clip.mp4")).unwrap_err().contains("Couldn’t write"));
    }

    #[test]
    fn a_copy_never_touches_the_source() {
        let dir = folder(); let temp = dir.join("temp"); fs::create_dir(&temp).unwrap();
        let (source, target) = (dir.join("capture.webm"), dir.join("copy.webm"));
        fs::write(&source, b"recording").unwrap();
        save_copy(&temp, &source, &target).unwrap();
        assert_eq!(fs::read(&source).unwrap(), b"recording");
        assert_eq!(fs::read(&target).unwrap(), b"recording");
        assert!(save_copy(&temp, &dir.join("gone.webm"), &target).unwrap_err().contains("Couldn’t read"));
        assert_eq!(fs::read(&target).unwrap(), b"recording");
    }

    #[test]
    fn export_paths_get_the_right_extension_without_overwriting() {
        let dir = folder();
        assert_eq!(export_path(dir.join("a.GIF"), "gif"), dir.join("a.GIF"));
        assert_eq!(export_path(dir.join("a"), "gif"), dir.join("a.gif"));
        // Dots inside a name, as in Still's own titles, aren't extensions.
        assert_eq!(export_path(dir.join("Still at 15.04.12"), "mp4"), dir.join("Still at 15.04.12.mp4"));
        assert_eq!(export_path(dir.join("a.mp4"), "webm"), dir.join("a.webm"));
        fs::write(dir.join("b.webm"), b"keep").unwrap();
        assert_eq!(export_path(dir.join("b.mp4"), "webm"), dir.join("b (2).webm"));
    }

    #[test]
    fn spots_the_original_under_another_spelling() {
        let dir = folder(); let source = dir.join("capture.mp4");
        fs::write(&source, b"x").unwrap();
        assert!(is_same_file(&source, &dir.join(".").join("capture.mp4")));
        assert!(!is_same_file(&source, &dir.join("other.mp4")));
    }

    #[test]
    fn names_and_tray_text() {
        assert_eq!(export_name("Demo", "mp4"), "Demo-trimmed");
        assert_eq!(export_name("Demo", "gif"), "Demo");
        assert_eq!(clock(0), "0:00");
        assert_eq!(clock(754), "12:34");
        assert_eq!(tray_status(65, false), ("Stop Recording (1:05)".to_string(), "Still: recording 1:05".to_string()));
        assert_eq!(tray_status(65, true).1, "Still: paused at 1:05");
    }
}
