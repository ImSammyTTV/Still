use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

/// Every capture lives in its own folder: the original, the latest export and an editable project.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub file_name: String,
    pub original_name: String,
    pub created: i64,
    #[serde(default)] pub modified: Option<i64>,
    #[serde(default)] pub width: u32,
    #[serde(default)] pub height: u32,
    #[serde(default)] pub text: String,
    #[serde(default)] pub duration: f64,
}

pub struct Library { dir: PathBuf, pub items: Vec<Item> }

pub fn now_ms() -> i64 { chrono::Utc::now().timestamp_millis() }

/// "Still 2026-10-25 at 15.04.12" — sortable and safe for every file system.
pub fn capture_name(kind: &str) -> String {
    format!("{} {}", kind, chrono::Local::now().format("%Y-%m-%d at %H.%M.%S"))
}

impl Library {
    pub fn open(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        let items: Vec<Item> = fs::read_to_string(dir.join("library.json")).ok()
            .and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        let mut lib = Library { dir, items };
        lib.items.retain(|i| lib_file(&lib.dir, i).exists());
        lib
    }
    fn save(&self) { let _ = fs::write(self.dir.join("library.json"), serde_json::to_string_pretty(&self.items).unwrap_or_default()); }
    pub fn folder(&self, item: &Item) -> PathBuf { self.dir.join(&item.id) }
    pub fn file(&self, item: &Item) -> PathBuf { lib_file(&self.dir, item) }
    pub fn original(&self, item: &Item) -> PathBuf { self.folder(item).join(&item.original_name) }

    pub fn add(&mut self, bytes: &[u8], kind: &str, ext: &str, title: Option<String>, width: u32, height: u32) -> Item {
        let item = Item {
            id: uuid::Uuid::new_v4().to_string(), kind: kind.into(),
            title: title.unwrap_or_else(|| capture_name(if kind == "recording" { "Still Recording" } else { "Still" })),
            file_name: format!("capture.{ext}"), original_name: format!("original.{ext}"),
            created: now_ms(), modified: None, width, height, text: String::new(), duration: 0.0,
        };
        let _ = fs::create_dir_all(self.folder(&item));
        let _ = fs::write(self.file(&item), bytes);
        if kind != "recording" { let _ = fs::write(self.original(&item), bytes); }
        self.items.insert(0, item.clone());
        self.save();
        item
    }
    pub fn get(&self, id: &str) -> Option<Item> { self.items.iter().find(|i| i.id == id).cloned() }
    pub fn update(&mut self, id: &str, f: impl FnOnce(&mut Item)) -> Option<Item> {
        let item = self.items.iter_mut().find(|i| i.id == id)?;
        f(item);
        let out = item.clone();
        self.save();
        Some(out)
    }
    pub fn replace_file(&mut self, id: &str, bytes: &[u8], ext: &str) -> Option<Item> {
        let item = self.get(id)?;
        let name = format!("capture.{ext}");
        if name != item.file_name { let _ = fs::remove_file(self.file(&item)); }
        let updated = self.update(id, |i| { i.file_name = name.clone(); i.modified = Some(now_ms()); })?;
        let _ = fs::write(self.file(&updated), bytes);
        Some(updated)
    }
    pub fn project(&self, id: &str) -> Option<Value> {
        let item = self.get(id)?;
        serde_json::from_str(&fs::read_to_string(self.folder(&item).join("project.json")).ok()?).ok()
    }
    pub fn save_project(&self, id: &str, project: &Value) {
        if let Some(item) = self.get(id) { let _ = fs::write(self.folder(&item).join("project.json"), project.to_string()); }
    }
    pub fn remove(&mut self, id: &str) {
        if let Some(item) = self.get(id) { let _ = fs::remove_dir_all(self.folder(&item)); }
        self.items.retain(|i| i.id != id);
        self.save();
    }
    pub fn search(&self, query: &str, kind: &str) -> Vec<Item> {
        let q = query.trim().to_lowercase();
        self.items.iter().filter(|i| (kind == "all" || i.kind == kind || (kind == "screenshot" && i.kind != "recording"))
            && (q.is_empty() || i.title.to_lowercase().contains(&q) || i.text.to_lowercase().contains(&q))).cloned().collect()
    }
}

fn lib_file(dir: &Path, item: &Item) -> PathBuf { dir.join(&item.id).join(&item.file_name) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_original_edits_and_project() {
        let dir = std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4()));
        let mut lib = Library::open(dir.clone());
        let item = lib.add(b"original", "screenshot", "png", Some("Bug report".into()), 10, 5);
        lib.replace_file(&item.id, b"edited", "jpg");
        lib.save_project(&item.id, &serde_json::json!({ "marks": [{ "type": "arrow" }] }));
        let again = Library::open(dir);
        let reloaded = again.get(&item.id).unwrap();
        assert_eq!(fs::read(again.original(&reloaded)).unwrap(), b"original");
        assert_eq!(fs::read(again.file(&reloaded)).unwrap(), b"edited");
        assert_eq!(reloaded.file_name, "capture.jpg");
        assert_eq!(again.project(&item.id).unwrap()["marks"][0]["type"], "arrow");
    }
    #[test]
    fn search_filters_kind_title_and_text() {
        let mut lib = Library::open(std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4())));
        let a = lib.add(b"a", "screenshot", "png", Some("Invoice".into()), 1, 1);
        lib.update(&a.id, |i| i.text = "total due".into());
        lib.add(b"b", "recording", "mp4", Some("Demo".into()), 0, 0);
        assert_eq!(lib.search("due", "all").len(), 1);
        assert_eq!(lib.search("", "recording")[0].title, "Demo");
        lib.remove(&a.id);
        assert_eq!(lib.items.len(), 1);
    }
}
