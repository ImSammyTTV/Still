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
        "hideDesktopIcons": false,
        "fileName": "{type} {date} at {time}",
        "watermark": { "text": "", "position": "bottomRight", "size": "medium", "opacity": 0.7 },
        "recording": { "engine": "auto", "quality": "high", "cursorEffects": false, "fps": 30, "format": "mp4", "microphone": false, "systemAudio": false, "countdown": 3, "camera": false, "cameraSize": 180, "cameraShape": "circle",
            "clicks": false, "keys": false, "keysShortcutsOnly": true },
        "annotate": { "color": "#FF453A", "stroke": 4, "font": 28 },
        "cloud": { "provider": "still", "endpoint": "", "expiryDays": 7, "visibility": "link", "autoUpload": false, "driveAccess": "link", "driveEmail": "", "driveFolder": "" },
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
        if let Ok(text) = fs::read_to_string(&file) {
            // Anything but a JSON object (a damaged or hand-edited file) is ignored rather than replacing
            // the settings and crashing later.
            if let Ok(saved) = serde_json::from_str::<Value>(&text) { if saved.is_object() { merge(&mut values, &saved); } }
        }
        Settings { file, values }
    }
    pub fn update(&mut self, patch: &Value) -> Value {
        merge(&mut self.values, patch);
        if let Some(dir) = self.file.parent() { let _ = fs::create_dir_all(dir); }
        let _ = fs::write(&self.file, serde_json::to_string_pretty(&self.values).unwrap_or_default());
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
    fn overlays_start_off_and_keys_start_as_shortcuts_only() {
        let values = defaults();
        for key in ["camera", "clicks", "keys"] { assert_eq!(values["recording"][key], json!(false), "{key}"); }
        assert_eq!(values["recording"]["keysShortcutsOnly"], json!(true));
    }
}
