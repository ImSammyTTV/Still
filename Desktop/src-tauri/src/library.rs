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

pub struct Library { dir: PathBuf, pub items: Vec<Item>, /** Settings → Screenshots → File names. */ pub name_pattern: String }

/// A thumbnail lives in its capture's folder, so deleting the capture removes it too.
const THUMBS: [&str; 2] = ["thumb.jpg", "thumb.png"];

pub fn now_ms() -> i64 { chrono::Utc::now().timestamp_millis() }

/// "Still 2026-10-25 at 15.04.12" — sortable and safe for every file system.
pub fn capture_name(kind: &str) -> String {
    format!("{} {}", kind, chrono::Local::now().format("%Y-%m-%d at %H.%M.%S"))
}

/// The pattern a new install starts with: "Screenshot 2026-10-31 at 13.05.22", as on the Mac.
pub const DEFAULT_NAME: &str = "{type} {date} at {time}";

/// A capture's name from a pattern. Tokens: {date} 2026-10-31, {time} 13.05.22, {type} Screenshot or Recording,
/// {width} and {height} in pixels (empty when not known yet, as for a recording), {n} its number among today's
/// captures. Characters no file system accepts become "-", and an empty result falls back to the default.
pub fn name_from(pattern: &str, kind: &str, now: chrono::DateTime<chrono::Local>, width: u32, height: u32, n: usize) -> String {
    let size = |v: u32| if v > 0 { v.to_string() } else { String::new() };
    let fill = |p: &str| p.replace("{date}", &now.format("%Y-%m-%d").to_string()).replace("{time}", &now.format("%H.%M.%S").to_string())
        .replace("{type}", if kind == "recording" { "Recording" } else { "Screenshot" }).replace("{width}", &size(width)).replace("{height}", &size(height))
        .replace("{n}", &n.to_string());
    let clean = |s: String| s.chars().map(|c| if "\\/:*?\"<>|\n\r\t".contains(c) { '-' } else { c }).collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ");
    let name: String = clean(fill(pattern)).chars().take(180).collect();
    if name.trim_matches(['-', ' ', '.']).is_empty() { clean(fill(DEFAULT_NAME)) } else { name }
}

impl Library {
    /// The name a new capture gets when nothing else names it.
    pub fn default_title(&self, kind: &str, width: u32, height: u32) -> String {
        let now = chrono::Local::now();
        let today = now.date_naive();
        let n = 1 + self.items.iter().filter(|i| chrono::DateTime::from_timestamp_millis(i.created).map(|t| t.with_timezone(&chrono::Local).date_naive() == today).unwrap_or(false)).count();
        name_from(&self.name_pattern, kind, now, width, height, n)
    }
    pub fn open(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        let index = dir.join("library.json");
        let items: Vec<Item> = match fs::read_to_string(&index) {
            Err(_) => Vec::new(),
            Ok(text) => match serde_json::from_str(&text) {
                Ok(items) => items,
                // A damaged index is kept aside, never overwritten, and the list is rebuilt from the
                // capture folders so nothing is orphaned.
                Err(_) => { let _ = fs::rename(&index, dir.join(format!("library-damaged-{}.json", now_ms()))); rebuild(&dir) }
            },
        };
        let mut lib = Library { dir, items, name_pattern: DEFAULT_NAME.to_string() };
        lib.items.retain(|i| lib_file(&lib.dir, i).exists());
        let _ = lib.save();
        lib
    }
    /// Writes the index to a temporary file and renames it over the old one, so a crash or a full disk
    /// never leaves a half-written library.json.
    fn save(&self) -> Result<(), String> {
        let text = serde_json::to_string_pretty(&self.items).map_err(|e| e.to_string())?;
        let temp = self.dir.join("library.json.tmp");
        fs::write(&temp, text).map_err(|e| e.to_string())?;
        fs::rename(&temp, self.dir.join("library.json")).map_err(|e| e.to_string())
    }
    pub fn folder(&self, item: &Item) -> PathBuf { self.dir.join(&item.id) }
    pub fn file(&self, item: &Item) -> PathBuf { lib_file(&self.dir, item) }
    pub fn original(&self, item: &Item) -> PathBuf { self.folder(item).join(&item.original_name) }
    pub fn thumb(&self, item: &Item) -> Option<PathBuf> { THUMBS.iter().map(|name| self.folder(item).join(name)).find(|f| f.exists()) }
    /// Screenshots that should have a thumbnail and don't, newest first.
    pub fn missing_thumbs(&self) -> Vec<Item> { self.items.iter().filter(|i| wants_thumb(i) && self.thumb(i).is_none()).cloned().collect() }
    /// Keeps a thumbnail made from `item`, unless the capture was edited or deleted while it was being made.
    pub fn store_thumb(&self, item: &Item, bytes: &[u8], ext: &str) -> Option<PathBuf> {
        if self.get(&item.id)?.modified != item.modified { return None; }
        let (temp, file) = (self.folder(item).join("thumb.tmp"), self.folder(item).join(format!("thumb.{ext}")));
        fs::write(&temp, bytes).ok()?;
        self.remove_thumbs(item);
        fs::rename(&temp, &file).ok()?;
        Some(file)
    }
    fn remove_thumbs(&self, item: &Item) { for name in THUMBS { let _ = fs::remove_file(self.folder(item).join(name)); } }

    pub fn add(&mut self, bytes: &[u8], kind: &str, ext: &str, title: Option<String>, width: u32, height: u32) -> Result<Item, String> {
        let item = Item {
            id: uuid::Uuid::new_v4().to_string(), kind: kind.into(),
            title: title.unwrap_or_else(|| self.default_title(kind, width, height)),
            file_name: format!("capture.{ext}"), original_name: format!("original.{ext}"),
            created: now_ms(), modified: None, width, height, text: String::new(), duration: 0.0,
        };
        let written = fs::create_dir_all(self.folder(&item)).and_then(|_| fs::write(self.file(&item), bytes))
            .and_then(|_| if kind != "recording" { fs::write(self.original(&item), bytes) } else { Ok(()) });
        if let Err(e) = written { let _ = fs::remove_dir_all(self.folder(&item)); return Err(e.to_string()); }
        self.items.insert(0, item.clone());
        if let Err(e) = self.save() { self.items.remove(0); let _ = fs::remove_dir_all(self.folder(&item)); return Err(e); }
        Ok(item)
    }
    pub fn get(&self, id: &str) -> Option<Item> { self.items.iter().find(|i| i.id == id).cloned() }
    pub fn update(&mut self, id: &str, f: impl FnOnce(&mut Item)) -> Option<Item> {
        let item = self.items.iter_mut().find(|i| i.id == id)?;
        f(item);
        let out = item.clone();
        let _ = self.save();
        Some(out)
    }
    pub fn replace_file(&mut self, id: &str, bytes: &[u8], ext: &str) -> Result<Item, String> {
        let item = self.get(id).ok_or("That capture no longer exists.")?;
        let name = format!("capture.{ext}");
        // Write the new file before removing the old one.
        fs::write(self.folder(&item).join(&name), bytes).map_err(|e| e.to_string())?;
        if name != item.file_name { let _ = fs::remove_file(self.file(&item)); }
        self.remove_thumbs(&item);
        self.update(id, |i| { i.file_name = name.clone(); i.modified = Some(now_ms()); }).ok_or_else(|| "That capture no longer exists.".to_string())
    }
    pub fn project(&self, id: &str) -> Option<Value> {
        let item = self.get(id)?;
        serde_json::from_str(&fs::read_to_string(self.folder(&item).join("project.json")).ok()?).ok()
    }
    pub fn save_project(&self, id: &str, project: &Value) -> Result<(), String> {
        let item = self.get(id).ok_or("That capture no longer exists.")?;
        fs::write(self.folder(&item).join("project.json"), project.to_string()).map_err(|e| e.to_string())
    }
    pub fn remove(&mut self, id: &str) {
        if let Some(item) = self.get(id) { let _ = fs::remove_dir_all(self.folder(&item)); }
        self.items.retain(|i| i.id != id);
        let _ = self.save();
    }
    pub fn search(&self, query: &str, kind: &str) -> Vec<Item> {
        let q = query.trim().to_lowercase();
        self.items.iter().filter(|i| (kind == "all" || i.kind == kind || (kind == "screenshot" && i.kind != "recording"))
            && (q.is_empty() || i.title.to_lowercase().contains(&q) || i.text.to_lowercase().contains(&q))).cloned().collect()
    }
}

/// Screenshots too big to show as they are. A size of 0 means it isn't known, as with a recovered capture.
pub fn wants_thumb(item: &Item) -> bool { item.kind != "recording" && (item.width == 0 || item.width.max(item.height) > crate::capture::THUMB_MAX) }
fn lib_file(dir: &Path, item: &Item) -> PathBuf { dir.join(&item.id).join(&item.file_name) }

/// The captures on disk, newest first, for when library.json can't be read.
fn rebuild(dir: &Path) -> Vec<Item> {
    let mut items: Vec<Item> = fs::read_dir(dir).into_iter().flatten().flatten().filter(|e| e.path().is_dir()).filter_map(|entry| {
        let folder = entry.path();
        let files: Vec<String> = fs::read_dir(&folder).ok()?.flatten().map(|f| f.file_name().to_string_lossy().to_string()).collect();
        let file_name = files.iter().find(|f| f.starts_with("capture."))?.clone();
        let ext = file_name.rsplit('.').next().unwrap_or("png").to_string();
        let original_name = files.iter().find(|f| f.starts_with("original.")).cloned().unwrap_or_else(|| file_name.clone());
        let created = entry.metadata().ok().and_then(|m| m.created().or_else(|_| m.modified()).ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or_else(now_ms);
        Some(Item { id: entry.file_name().to_string_lossy().to_string(), kind: if ["mp4", "webm"].contains(&ext.as_str()) { "recording".into() } else { "screenshot".into() },
            title: "Recovered capture".into(), file_name, original_name, created, modified: None, width: 0, height: 0, text: String::new(), duration: 0.0 })
    }).collect();
    items.sort_by(|a, b| b.created.cmp(&a.created));
    items
}

#[cfg(test)]
mod tests {
    #[test]
    fn names_follow_the_file_name_pattern() {
        use chrono::TimeZone;
        let now = chrono::Local.with_ymd_and_hms(2026, 10, 31, 9, 5, 7).unwrap();
        assert_eq!(name_from(DEFAULT_NAME, "screenshot", now, 800, 600, 1), "Screenshot 2026-10-31 at 09.05.07");
        assert_eq!(name_from("{type} #{n} {width}x{height}", "recording", now, 0, 0, 12), "Recording #12 x");
        assert_eq!(name_from("Bug: {date}/{time}?", "screenshot", now, 1, 1, 1), "Bug- 2026-10-31-09.05.07-");
        // Nothing usable left: the default instead of an empty or dot-only name.
        assert_eq!(name_from(" ... ", "screenshot", now, 1, 1, 1), "Screenshot 2026-10-31 at 09.05.07");
        assert_eq!(name_from(&"x".repeat(300), "screenshot", now, 1, 1, 1).chars().count(), 180);
    }

    use super::*;
    #[test]
    fn keeps_original_edits_and_project() {
        let dir = std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4()));
        let mut lib = Library::open(dir.clone());
        let item = lib.add(b"original", "screenshot", "png", Some("Bug report".into()), 10, 5).unwrap();
        lib.replace_file(&item.id, b"edited", "jpg").unwrap();
        lib.save_project(&item.id, &serde_json::json!({ "marks": [{ "type": "arrow" }] })).unwrap();
        let again = Library::open(dir);
        let reloaded = again.get(&item.id).unwrap();
        assert_eq!(fs::read(again.original(&reloaded)).unwrap(), b"original");
        assert_eq!(fs::read(again.file(&reloaded)).unwrap(), b"edited");
        assert_eq!(reloaded.file_name, "capture.jpg");
        assert_eq!(again.project(&item.id).unwrap()["marks"][0]["type"], "arrow");
    }
    #[test]
    fn thumbnails_follow_their_capture() {
        let dir = std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4()));
        let mut lib = Library::open(dir);
        let big = lib.add(b"a", "screenshot", "png", None, 3840, 2160).unwrap();
        lib.add(b"b", "screenshot", "png", None, 300, 200).unwrap();
        lib.add(b"c", "recording", "mp4", None, 0, 0).unwrap();
        assert_eq!(lib.missing_thumbs().iter().map(|i| i.id.clone()).collect::<Vec<_>>(), vec![big.id.clone()]);
        let file = lib.store_thumb(&big, b"small", "jpg").unwrap();
        assert_eq!(lib.thumb(&big), Some(file.clone()));
        assert!(lib.missing_thumbs().is_empty());
        // A different format replaces the old thumbnail rather than sitting beside it.
        let png = lib.store_thumb(&big, b"small", "png").unwrap();
        assert!(!file.exists() && png.exists());
        // Editing drops the thumbnail, and one made from the old picture can't come back afterwards.
        lib.replace_file(&big.id, b"edited", "png").unwrap();
        assert_eq!(lib.thumb(&big), None);
        assert_eq!(lib.store_thumb(&big, b"stale", "jpg"), None);
        assert_eq!(lib.thumb(&big), None);
        // Deleting takes the thumbnail with it.
        let edited = lib.get(&big.id).unwrap();
        let file = lib.store_thumb(&edited, b"fresh", "jpg").unwrap();
        lib.remove(&big.id);
        assert!(!file.exists());
        assert_eq!(lib.store_thumb(&edited, b"late", "jpg"), None);
        assert!(!lib.folder(&edited).exists());
    }
    #[test]
    fn a_thumbnail_is_not_mistaken_for_the_capture_when_rebuilding() {
        let dir = std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4()));
        let mut lib = Library::open(dir.clone());
        let item = lib.add(b"png", "screenshot", "png", None, 3840, 2160).unwrap();
        lib.store_thumb(&item, b"small", "jpg").unwrap();
        fs::write(dir.join("library.json"), "{ not json").unwrap();
        let again = Library::open(dir);
        assert_eq!(again.items[0].file_name, "capture.png");
    }
    /// cargo test --lib --release -- --ignored --nocapture library_timings
    #[test]
    #[ignore]
    fn library_timings() {
        let mut lib = Library::open(std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4())));
        for _ in 0..1000 { lib.add(b"png", "screenshot", "png", None, 3840, 2160).unwrap(); }
        let time = |name: &str, f: &dyn Fn()| { let t = std::time::Instant::now(); for _ in 0..20 { f(); } println!("  {name:28} {:7.2} ms", t.elapsed().as_secs_f64() * 50.0); };
        println!("1000 captures");
        time("write library.json", &|| lib.save().unwrap());
        time("look for every thumbnail", &|| { lib.missing_thumbs(); });
        let _ = fs::remove_dir_all(&lib.dir);
    }
    #[test]
    fn search_filters_kind_title_and_text() {
        let mut lib = Library::open(std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4())));
        let a = lib.add(b"a", "screenshot", "png", Some("Invoice".into()), 1, 1).unwrap();
        lib.update(&a.id, |i| i.text = "total due".into());
        lib.add(b"b", "recording", "mp4", Some("Demo".into()), 0, 0).unwrap();
        assert_eq!(lib.search("due", "all").len(), 1);
        assert_eq!(lib.search("", "recording")[0].title, "Demo");
        lib.remove(&a.id);
        assert_eq!(lib.items.len(), 1);
    }
    #[test]
    fn damaged_index_is_kept_and_rebuilt() {
        let dir = std::env::temp_dir().join(format!("still-lib-{}", uuid::Uuid::new_v4()));
        let mut lib = Library::open(dir.clone());
        let item = lib.add(b"png", "screenshot", "png", None, 1, 1).unwrap();
        fs::write(dir.join("library.json"), "{ not json").unwrap();
        let again = Library::open(dir.clone());
        assert_eq!(again.items.len(), 1);
        assert_eq!(again.items[0].id, item.id);
        assert!(fs::read_dir(&dir).unwrap().flatten().any(|e| e.file_name().to_string_lossy().starts_with("library-damaged-")));
    }
}
