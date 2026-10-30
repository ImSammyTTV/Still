//! Capture the previous area again. The area is kept whatever `rememberSelection` says: that setting only
//! decides whether the capture overlay starts with the last selection in place.

use crate::{capture, complete_image, desktop, hide_floating, notify, occupied, setting, start_selection, st, Grab};
use serde_json::{json, Value};
use std::time::Duration;
use tauri::AppHandle;

pub fn remember(app: &AppHandle, payload: &Value, grab: &Grab) {
    let (width, height) = grab.image.dimensions();
    let area = json!({ "displayId": grab.id, "x": grab.x, "y": grab.y, "width": width, "height": height, "px": payload["px"] });
    st(app).settings.lock().unwrap().update(&json!({ "previousArea": area }));
}

/// The display the area was on. Windows renumbers displays when they change, so a display in the same
/// place at the same size counts too; one of another size would put the area somewhere else on screen.
fn find<'a>(area: &Value, grabs: &'a [Grab]) -> Option<&'a Grab> {
    let same_size = |g: &&Grab| Some(g.image.width() as u64) == area["width"].as_u64() && Some(g.image.height() as u64) == area["height"].as_u64();
    let by_id = grabs.iter().filter(same_size).find(|g| Some(g.id as u64) == area["displayId"].as_u64());
    by_id.or_else(|| grabs.iter().filter(same_size).find(|g| Some(g.x as i64) == area["x"].as_i64() && Some(g.y as i64) == area["y"].as_i64()))
}

/// With no area to repeat (first use, or that display is gone) this asks for one, like the Mac app.
pub fn capture_again(app: &AppHandle) {
    let area = setting(app, "previousArea");
    if !area.is_object() { start_selection(app, "screenshot", 0, false); return; }
    {
        let mut s = st(app).session.lock().unwrap();
        if occupied(&s) { drop(s); notify(app, "Still", "Finish the current capture or recording first."); return; }
        s.busy = true;
    }
    hide_floating(app, true);
    let icons = desktop::hide(app);
    std::thread::sleep(Duration::from_millis(120));
    let result = capture::grab_all();
    drop(icons);
    st(app).session.lock().unwrap().busy = false;
    hide_floating(app, false);
    let grabs = match result { Ok(g) => g, Err(e) => { notify(app, "Capture failed", &e); return; } };
    let Some(grab) = find(&area, &grabs) else { start_selection(app, "screenshot", 0, false); return };
    let px = &area["px"];
    let (x, y, w, h) = (px["x"].as_f64().unwrap_or(0.0), px["y"].as_f64().unwrap_or(0.0), px["w"].as_f64().unwrap_or(0.0), px["h"].as_f64().unwrap_or(0.0));
    complete_image(app, capture::crop(&grab.image, x, y, w, h), false);
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::RgbaImage;

    fn grab(id: u32, x: i32, width: u32) -> Grab { Grab { id, x, y: 0, image: RgbaImage::new(width, 100), factor: 1.0 } }
    fn area(id: u32, x: i32, width: u32) -> Value { json!({ "displayId": id, "x": x, "y": 0, "width": width, "height": 100 }) }

    #[test]
    fn finds_the_display_by_id() {
        let grabs = [grab(1, 0, 200), grab(2, 200, 200)];
        assert_eq!(find(&area(2, 200, 200), &grabs).map(|g| g.id), Some(2));
    }
    #[test]
    fn a_renumbered_display_is_found_by_place_and_size() {
        let grabs = [grab(7, 0, 200), grab(9, 200, 200)];
        assert_eq!(find(&area(2, 200, 200), &grabs).map(|g| g.id), Some(9));
    }
    #[test]
    fn a_display_of_another_size_does_not_match() {
        assert!(find(&area(1, 0, 400), &[grab(1, 0, 200)]).is_none());
        assert!(find(&json!(null), &[grab(1, 0, 200)]).is_none());
    }
}
