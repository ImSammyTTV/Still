use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

pub fn defaults() -> Value {
    json!({
        "theme": "system",
        "launchAtLogin": false,
        "autoUpdate": true,
        "playSounds": true,
        "exportFolder": "",
        "imageFormat": "png",
        "jpegQuality": 90,
        "afterCapture": { "quickAccess": true, "copy": true, "save": false, "annotate": false },
        "afterRecording": { "quickAccess": true, "copy": false, "save": true },
        "quickAccess": { "side": "left", "size": "medium", "autoClose": true, "closeAfter": 15 },
        "crosshair": "partial",
        "magnifier": true,
        "rememberSelection": false,
        // Off unless turned on; a new name so it starts off for everyone, including those who had the earlier default.
        "adjustAreaBeforeCapture": false,
        "hideDesktopIcons": false,
        "fileName": "{type} {date} at {time}",
        "historyDays": 0,
        "watermark": { "kind": "text", "text": "", "image": "", "position": "bottomRight", "size": "medium", "opacity": 0.7 },
        "recording": { "engine": "auto", "quality": "high", "cursorEffects": false, "fps": 30, "format": "mp4", "microphone": false, "systemAudio": false, "countdown": 3, "camera": false, "cameraSize": 180, "cameraShape": "circle",
            "clicks": false, "keys": false, "keysShortcutsOnly": true },
        "annotate": { "color": "#FF453A", "stroke": 4, "font": 28 },
        "ai": { "provider": "gemini" },
        "claude": { "connector": false },
        "shortcuts": {
            "area": "CommandOrControl+Shift+4",
            "allInOne": "CommandOrControl+Shift+5",
            "fullscreen": "CommandOrControl+Shift+3",
            "window": "CommandOrControl+Alt+Shift+4",
            "record": "CommandOrControl+Shift+6",
            "text": "CommandOrControl+Shift+2",
            "previous": "",
            "scrolling": "",
            "history": "",
            "restore": ""
        }
    })
}

/// Deep-merges `patch` into `base`: objects merge key by key, everything else replaces.
pub fn merge(base: &mut Value, patch: &Value) {
    match (base, patch) {
        (Value::Object(b), Value::Object(p)) => {
            for (k, v) in p {
                match b.get_mut(k) {
                    Some(existing) if existing.is_object() && v.is_object() => merge(existing, v),
                    _ => { b.insert(k.clone(), v.clone()); }
                }
            }
        }
        (b, p) => *b = p.clone(),
    }
}

pub struct Settings { file: PathBuf, pub values: Value }

impl Settings {
    pub fn load(dir: PathBuf) -> Self {
        let file = dir.join("settings.json");
        let mut values = defaults();
        // Another program can have the file open for a moment (a virus scan, say): ask again before giving up on it.
        let mut read = fs::read(&file);
        for _ in 0..3 {
            if !matches!(&read, Err(e) if e.kind() != std::io::ErrorKind::NotFound) { break; }
            std::thread::sleep(std::time::Duration::from_millis(200));
            read = fs::read(&file);
        }
        let saved = match &read { Ok(bytes) => serde_json::from_slice::<Value>(bytes).ok().filter(|v| v.is_object()), Err(_) => None };
        match saved {
            Some(saved) => merge(&mut values, &saved),
            // Anything but a JSON object (a damaged or hand-edited file), or a file that can't be read, is kept aside
            // as settings-damaged-<time>.json rather than replacing the settings and crashing later, or being written
            // over by the next change and taking every setting in it with it.
            None if !matches!(&read, Err(e) if e.kind() == std::io::ErrorKind::NotFound) => {
                let kept = file.with_file_name(format!("settings-damaged-{}.json", chrono::Utc::now().timestamp_millis()));
                if fs::rename(&file, &kept).is_err() { let _ = fs::copy(&file, &kept); }
            }
            None => {}
        }
        Settings { file, values }
    }
    pub fn update(&mut self, patch: &Value) -> Value {
        // Only an object of changes is a patch: anything else would replace every setting at once.
        if !patch.is_object() { return self.values.clone(); }
        merge(&mut self.values, patch);
        if let Some(dir) = self.file.parent() { let _ = fs::create_dir_all(dir); }
        // Written beside the old file and renamed into place, so a crash or a full disk mid-write never leaves a
        // half-written settings.json (which would bring back every default on the next start).
        let temp = self.file.with_file_name("settings.json.tmp");
        let saved = fs::write(&temp, serde_json::to_string_pretty(&self.values).unwrap_or_default()).and_then(|_| fs::rename(&temp, &self.file));
        if let Err(e) = saved { let _ = fs::remove_file(&temp); eprintln!("Still couldn’t save its settings: {e}"); }
        self.values.clone()
    }
    pub fn reset(&mut self, key: &str) -> Value {
        let value = defaults().get(key).cloned().unwrap_or(Value::Null);
        self.update(&json!({ key: value }))
    }
    pub fn get(&self, path: &str) -> &Value {
        path.split('.').fold(&self.values, |v, k| v.get(k).unwrap_or(&Value::Null))
    }
    pub fn str(&self, path: &str) -> String { self.get(path).as_str().unwrap_or("").to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn merges_nested_values_and_survives_restart() {
        let dir = std::env::temp_dir().join(format!("still-settings-{}", uuid::Uuid::new_v4()));
        let mut s = Settings::load(dir.clone());
        assert_eq!(s.str("shortcuts.area"), "CommandOrControl+Shift+4");
        s.update(&json!({ "shortcuts": { "area": "Alt+Shift+A" }, "quickAccess": { "side": "right" } }));
        let again = Settings::load(dir);
        assert_eq!(again.str("shortcuts.area"), "Alt+Shift+A");
        assert_eq!(again.str("shortcuts.fullscreen"), "CommandOrControl+Shift+3");
        assert_eq!(again.get("quickAccess.closeAfter").as_i64(), Some(15));
    }
    #[test]
    fn only_an_object_changes_settings_and_a_damaged_file_is_kept() {
        let dir = std::env::temp_dir().join(format!("still-settings-{}", uuid::Uuid::new_v4()));
        let mut s = Settings::load(dir.clone());
        s.update(&json!({ "theme": "dark" }));
        assert_eq!(s.update(&Value::Null)["theme"], "dark");
        assert_eq!(s.update(&json!("light"))["theme"], "dark");
        assert!(!dir.join("settings.json.tmp").exists());
        fs::write(dir.join("settings.json"), "{ \"theme\": \"da").unwrap();
        let again = Settings::load(dir.clone());
        assert_eq!(again.str("theme"), "system");
        assert!(fs::read_dir(&dir).unwrap().flatten().any(|e| e.file_name().to_string_lossy().starts_with("settings-damaged-")));
        let _ = fs::remove_dir_all(dir);
    }
    #[test]
    fn overlays_start_off_and_keys_start_as_shortcuts_only() {
        let values = defaults();
        for key in ["camera", "clicks", "keys"] { assert_eq!(values["recording"][key], json!(false), "{key}"); }
        assert_eq!(values["recording"]["keysShortcutsOnly"], json!(true));
    }
}
