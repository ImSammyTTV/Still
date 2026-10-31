//! Scrolling capture: the selected area is grabbed again and again while the user scrolls, and each new
//! frame is lined up against the one before it. Follows Sources/StillCore/ScrollingStitcher.swift (the Mac
//! app) but works on plain pixels, so the stitching itself can be tested without a screen. It also checks
//! harder before accepting a match: see SAMPLE_WIDTH, EXACT and the contenders in `stitch_frame`.

use crate::{build_tray_menu, capture, complete_image, desktop, hide_floating, notify, st, Grab};
use image::RgbaImage;
use serde_json::json;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize};

// ---- Stitching ----------------------------------------------------------------------------------

/// Frames are compared as small greyscale copies: fast, and blind to subpixel text rendering. The Mac
/// app samples 80 columns, but at that width lines of text blur into identical bars, so a shift of any
/// whole number of lines looks like a match and the picture silently comes out too short.
const SAMPLE_WIDTH: usize = 320;
/// Columns left out on each side: scrollbars move on their own.
const SAMPLE_EDGE: usize = SAMPLE_WIDTH / 16;
const SAMPLE_HEIGHT: usize = 280;
/// The worst average difference, from 0 to 1, that still counts as the same content.
const MATCH: f64 = 0.065;
/// The same at full height for the row 70% of the way from best to worst, where a true shift compares the
/// very same pixels. That far up because over half the rows of a page of text are the blank ones between
/// lines, and sticky bars can spoil the rest. Strict, because a frame that is refused can be recovered by
/// scrolling back, and a bad match can't.
const EXACT: f64 = 0.012;
/// How far behind the best a shift can be and still be looked at closely, and how many are.
const CLOSE: f64 = 0.04;
const CONTENDERS: usize = 24;
const MAX_HEIGHT: u32 = 30_000;
const MAX_PIXELS: u64 = 120_000_000;

#[derive(Debug, PartialEq)]
pub enum StitchError { NoOverlap, DifferentSize, TooLarge }

impl StitchError {
    fn message(&self) -> &'static str {
        match self {
            StitchError::NoOverlap => "No matching overlap. Scroll back a little, then move more slowly.",
            StitchError::DifferentSize => "The capture area changed size. Start a new scrolling capture.",
            StitchError::TooLarge => "This capture is as long as Still can make it. Click Done to keep it.",
        }
    }
}

/// What one more frame did to the picture so far.
#[derive(Debug)]
pub enum Stitched {
    /// The frame is the same as the last one (nothing scrolled, or only a blinking caret).
    Unchanged,
    /// The user scrolled back over something already captured.
    Moved { position: i64 },
    /// New content: the taller picture, and where the frame now sits in it.
    Extended { image: RgbaImage, position: i64 },
}

/// A box-averaged greyscale copy of the image.
fn sample(image: &RgbaImage, width: usize, height: usize) -> Vec<u8> {
    let (iw, ih) = (image.width() as usize, image.height() as usize);
    let raw = image.as_raw();
    let span = |i: usize, to: usize, from: usize| { let start = i * from / to; (start, ((i + 1) * from / to).max(start + 1)) };
    let mut out = vec![0u8; width * height];
    for y in 0..height {
        let (top, bottom) = span(y, height, ih);
        for x in 0..width {
            let (left, right) = span(x, width, iw);
            let mut sum = 0u64;
            for row in top..bottom {
                for pixel in raw[(row * iw + left) * 4..(row * iw + right) * 4].chunks_exact(4) {
                    sum += 77 * pixel[0] as u64 + 150 * pixel[1] as u64 + 29 * pixel[2] as u64;
                }
            }
            out[y * width + x] = (sum / (((bottom - top) * (right - left)) as u64 * 256)) as u8;
        }
    }
    out
}

#[derive(Clone, Copy)]
struct Score { trimmed: f64, overlap: f64, upper: f64 }
const WORST: Score = Score { trimmed: f64::MAX, overlap: f64::MAX, upper: f64::MAX };

/// How badly row `y + displacement` of `a` differs from row `y` of `b`. The worst fifth of the rows is
/// ignored, so sticky bars and small animations don't spoil a good match. The average over the whole
/// overlap, margins included, comes second: it settles ties on pages of flat colour, where a shift that is
/// slightly off can differ only in the rows that are ignored. (The Mac app takes the smallest shift.)
fn score(a: &[u8], b: &[u8], height: i64, displacement: i64, margin: i64, step: usize) -> Score {
    let (w, edge) = (SAMPLE_WIDTH as i64, SAMPLE_EDGE as i64);
    let (begin, end) = (margin.max(margin - displacement), (height - margin).min(height - displacement - margin));
    if end - begin <= 20 { return WORST; }
    let row = |y: i64| {
        let sum: f64 = (edge..w - edge).step_by(2).map(|x| (a[((y + displacement) * w + x) as usize] as f64 - b[(y * w + x) as usize] as f64).abs()).sum();
        sum / ((w - 2 * edge) / 2) as f64 / 255.0
    };
    let mut rows: Vec<f64> = (begin..end).step_by(step).map(row).collect();
    rows.sort_by(f64::total_cmp);
    let keep = ((rows.len() as f64 * 0.8) as usize).max(1);
    let overlap = (-displacement).max(0)..height.min(height - displacement);
    let count = overlap.clone().step_by(step).count();
    Score { trimmed: rows[..keep].iter().sum::<f64>() / keep as f64, overlap: overlap.step_by(step).map(row).sum::<f64>() / count as f64, upper: rows[rows.len() * 7 / 10] }
}

/// Whether a score beats the best so far. A tie goes to `smaller`, the one that moves the frame less.
fn better(value: Score, best: Score, smaller: bool) -> bool {
    const SAME: f64 = 0.00001;
    if (value.trimmed - best.trimmed).abs() >= SAME { return value.trimmed < best.trimmed; }
    if (value.overlap - best.overlap).abs() >= SAME / 1000.0 { return value.overlap < best.overlap; }
    smaller
}

/// How many rows along one edge stayed put between two frames: a sticky header or footer.
fn fixed_rows(a: &[u8], b: &[u8], height: usize, from_bottom: bool, full_height: usize) -> usize {
    let (w, edge) = (SAMPLE_WIDTH, SAMPLE_EDGE);
    let mut count = 0;
    for index in 0..(height / 5).max(1) {
        let y = if from_bottom { height - 1 - index } else { index };
        let difference: f64 = (edge..w - edge).map(|x| (a[y * w + x] as f64 - b[y * w + x] as f64).abs()).sum();
        if difference / (w - 2 * edge) as f64 / 255.0 > 0.007 { break; }
        count += 1;
    }
    (full_height / 4).min(count * full_height / height)
}

fn rows(image: &RgbaImage, top: usize, bottom: usize) -> &[u8] {
    let stride = image.width() as usize * 4;
    &image.as_raw()[top * stride..bottom * stride]
}

/// Lines `next` up against `previous` and adds whatever is new to `combined`, where `previous` sits at
/// row `position`. Pure: pictures in, pictures out, nothing touches the screen.
pub fn stitch_frame(combined: &RgbaImage, position: i64, previous: &RgbaImage, next: &RgbaImage) -> Result<Stitched, StitchError> {
    if next.dimensions() != previous.dimensions() { return Err(StitchError::DifferentSize); }
    let full = next.height() as i64;
    let h = (full as usize).min(SAMPLE_HEIGHT);
    let (a, b) = (sample(previous, SAMPLE_WIDTH, h), sample(next, SAMPLE_WIDTH, h));
    let difference: f64 = a.iter().zip(&b).map(|(x, y)| (*x as f64 - *y as f64).abs()).sum::<f64>() / a.len() as f64 / 255.0;
    if difference < 0.003 { return Ok(Stitched::Unchanged); }

    let height = h as i64;
    let margin = (height / 18).max(3);
    let limit = (height - margin * 2 - 24).max(3);
    let shifts: Vec<i64> = (-limit..=limit).filter(|d| d.abs() > 1).collect();
    let scores: Vec<Score> = shifts.iter().map(|d| score(&a, &b, height, *d, margin, 2)).collect();
    let lowest = scores.iter().map(|s| s.trimmed).fold(f64::MAX, f64::min);
    if lowest >= MATCH { return Err(StitchError::NoOverlap); }

    // Repeated text can look like a match at the wrong shift, and the sample is too coarse to say which is
    // right. The closest contenders are judged at full height: on a tie the one that overlaps most wins,
    // because it has the most rows agreeing with it.
    let mut contenders: Vec<usize> = (0..shifts.len()).filter(|&i| {
        let (value, before, after) = (scores[i].trimmed, scores.get(i.wrapping_sub(1)), scores.get(i + 1));
        value < MATCH && value <= lowest + CLOSE && before.is_none_or(|s| value <= s.trimmed) && after.is_none_or(|s| value <= s.trimmed)
    }).collect();
    contenders.sort_by(|x, y| scores[*x].trimmed.total_cmp(&scores[*y].trimmed).then(scores[*x].overlap.total_cmp(&scores[*y].overlap)));
    contenders.truncate(CONTENDERS);
    let (full_a, full_b);
    let (exact_a, exact_b) = if full > height {
        (full_a, full_b) = (sample(previous, SAMPLE_WIDTH, full as usize), sample(next, SAMPLE_WIDTH, full as usize));
        (&full_a, &full_b)
    } else { (&a, &b) };
    let radius = (full as f64 / height as f64).ceil().max(2.0) as i64 * 2;
    let (mut best, mut pixels) = (WORST, 0i64);
    for index in contenders {
        let center = (shifts[index] as f64 * full as f64 / height as f64).round() as i64;
        for candidate in center - radius..=center + radius {
            if candidate == 0 { continue; }
            let value = score(exact_a, exact_b, full, candidate, (full / 18).max(3), (full as usize / 350).max(1));
            if better(value, best, candidate.abs() < pixels.abs()) { best = value; pixels = candidate; }
        }
    }
    if pixels == 0 || best.upper >= EXACT { return Err(StitchError::NoOverlap); }

    let moved = position + pixels;
    let (before, after) = ((-moved).max(0), (moved + full - combined.height() as i64).max(0));
    if before == 0 && after == 0 { return Ok(Stitched::Moved { position: moved }); }
    let new_height = combined.height() as u64 + (before + after) as u64;
    if new_height > MAX_HEIGHT as u64 || combined.width() as u64 * new_height > MAX_PIXELS { return Err(StitchError::TooLarge); }

    let (old, full_rows) = (combined.height() as usize, full as usize);
    let mut raw = Vec::with_capacity(combined.width() as usize * new_height as usize * 4);
    // A sticky bar stays at the edge of the finished picture: the rows it covered are replaced by the new
    // content, and the bar itself comes across with the new strip.
    let position = if after > 0 {
        let footer = fixed_rows(&a, &b, h, true, full_rows).min((full - after - 1).max(0) as usize);
        let strip = after as usize + footer;
        raw.extend_from_slice(rows(combined, 0, old - footer));
        raw.extend_from_slice(rows(next, full_rows - strip, full_rows));
        moved
    } else {
        let header = fixed_rows(&a, &b, h, false, full_rows).min((full - before - 1).max(0) as usize);
        raw.extend_from_slice(rows(next, 0, before as usize + header));
        raw.extend_from_slice(rows(combined, header, old));
        0
    };
    let image = RgbaImage::from_raw(combined.width(), new_height as u32, raw).ok_or(StitchError::TooLarge)?;
    Ok(Stitched::Extended { image, position })
}

/// The picture so far. Keeps what `stitch_frame` needs between frames.
pub struct Stitcher { previous: RgbaImage, combined: RgbaImage, position: i64, frames: u32 }

impl Stitcher {
    pub fn new(first: RgbaImage) -> Self { Stitcher { combined: first.clone(), previous: first, position: 0, frames: 1 } }
    pub fn append(&mut self, next: RgbaImage) -> Result<(), StitchError> {
        match stitch_frame(&self.combined, self.position, &self.previous, &next)? {
            Stitched::Unchanged => {}
            Stitched::Moved { position } => { self.previous = next; self.position = position; }
            Stitched::Extended { image, position } => { self.previous = next; self.combined = image; self.position = position; self.frames += 1; }
        }
        Ok(())
    }
    pub fn into_image(self) -> RgbaImage { self.combined }
}

/// A scrolling capture that works out for itself which way the page moves. Sideways is stitched as a turned
/// frame, so the same matching does both. Until something new appears each frame is tried both ways; the first
/// way that grows the picture decides, and the other is dropped.
pub struct Scroller { down: Option<Stitcher>, across: Option<Stitcher> }

impl Scroller {
    pub fn new(first: RgbaImage) -> Self { Scroller { across: Some(Stitcher::new(image::imageops::rotate90(&first))), down: Some(Stitcher::new(first)) } }

    pub fn append(&mut self, next: RgbaImage) -> Result<(), StitchError> {
        if self.across.is_none() { return self.down.as_mut().map_or(Ok(()), |down| down.append(next)); }
        let turned = image::imageops::rotate90(&next);
        if self.down.is_none() { return self.across.as_mut().map_or(Ok(()), |across| across.append(turned)); }
        let down = self.down.as_mut().map(|d| (d.append(next), d.frames > 1)).unwrap_or((Ok(()), false));
        if down.1 { self.across = None; return down.0; }
        let across = self.across.as_mut().map(|a| (a.append(turned), a.frames > 1)).unwrap_or((Ok(()), false));
        if across.1 { self.down = None; return across.0; }
        // Neither way has found anything new yet: it's only a problem if both say so.
        if down.0.is_ok() || across.0.is_ok() { Ok(()) } else { down.0 }
    }

    fn active(&self) -> &Stitcher { self.down.as_ref().or(self.across.as_ref()).expect("one way is always kept") }
    pub fn frames(&self) -> u32 { self.active().frames }
    /// The picture's size as it will be saved.
    pub fn dimensions(&self) -> (u32, u32) {
        let (w, h) = self.active().combined.dimensions();
        if self.down.is_some() { (w, h) } else { (h, w) }
    }
    pub fn into_image(self) -> RgbaImage {
        match (self.down, self.across) {
            (Some(down), _) => down.into_image(),
            (None, Some(across)) => image::imageops::rotate270(&across.into_image()),
            (None, None) => unreachable!("one way is always kept"),
        }
    }
}

// ---- Placing the controls -----------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect { pub x: f64, pub y: f64, pub w: f64, pub h: f64 }

/// Finds a spot for the controls outside the capture, below it or else above it. When the area fills the
/// height of the screen they sit over its bottom edge and the capture stops above them, so they never end
/// up in the picture. Returns where the controls go and the area to grab.
pub fn place_controls(area: Rect, bounds: Rect, size: (f64, f64), gap: f64) -> ((f64, f64), Rect) {
    let x = (area.x + (area.w - size.0) / 2.0).min(bounds.x + bounds.w - size.0 - gap).max(bounds.x + gap);
    let bottom = bounds.y + bounds.h - gap;
    let below = area.y + area.h + gap;
    if below + size.1 <= bottom { return ((x, below), area); }
    let above = area.y - gap - size.1;
    if above >= bounds.y + gap { return ((x, above), area); }
    let y = (area.y + area.h).min(bottom) - size.1;
    ((x, y), Rect { h: (y - gap - area.y).max(1.0), ..area })
}

// ---- The capture session ------------------------------------------------------------------------

const TICK: Duration = Duration::from_millis(600);
const CONTROLS: (f64, f64) = (536.0, 68.0);
const SCROLLING: &str = "Scroll slowly inside the area, down or sideways, then click Done.";
const RUNNING: u8 = 0;
const DONE: u8 = 1;
const CANCELLED: u8 = 2;

/// Tells the capture loop to stop. Only the first request counts.
#[derive(Default)]
pub struct Control(AtomicU8);
impl Control {
    fn request(&self, state: u8) { let _ = self.0.compare_exchange(RUNNING, state, Ordering::SeqCst, Ordering::SeqCst); }
    /// Sleeps until the next grab is due or a stop is requested, and says which.
    fn wait(&self, time: Duration) -> u8 {
        let start = Instant::now();
        while self.0.load(Ordering::SeqCst) == RUNNING && start.elapsed() < time { std::thread::sleep(Duration::from_millis(30)); }
        self.0.load(Ordering::SeqCst)
    }
}

/// Grabbing every 0.6 seconds needs silent access to the screen. On Wayland each grab goes through the
/// desktop's screenshot portal, which can flash the screen or ask for permission.
pub fn supported() -> bool {
    let var = |name: &str| std::env::var(name).unwrap_or_default().to_lowercase();
    !(cfg!(target_os = "linux") && (var("XDG_SESSION_TYPE") == "wayland" || var("WAYLAND_DISPLAY").contains("wayland")))
}

pub fn active(app: &AppHandle) -> bool { st(app).session.lock().unwrap().scroll.is_some() }

/// `save` keeps what has been stitched so far; otherwise the capture is thrown away.
pub fn stop(app: &AppHandle, save: bool) {
    if let Some(control) = st(app).session.lock().unwrap().scroll.as_ref() { control.request(if save { DONE } else { CANCELLED }); }
}

#[tauri::command]
pub async fn scroll_stop(app: AppHandle, save: bool) { stop(&app, save); }

/// Starts from the frozen selection: `grab` holds the first frame, and the rectangle is in its pixels.
pub fn start(app: &AppHandle, grab: &Grab, x: f64, y: f64, w: f64, h: f64) {
    if w < 40.0 || h < 40.0 { notify(app, "Still", "Select a larger area for a scrolling capture."); return; }
    let (iw, ih) = grab.image.dimensions();
    let monitor = app.monitor_from_point(grab.x as f64 + 1.0, grab.y as f64 + 1.0).ok().flatten();
    let scale = monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0);
    let bounds = monitor.as_ref().map(|m| m.work_area()).map(|a| Rect { x: (a.position.x - grab.x) as f64, y: (a.position.y - grab.y) as f64, w: a.size.width as f64, h: a.size.height as f64 })
        .unwrap_or(Rect { x: 0.0, y: 0.0, w: iw as f64, h: ih as f64 });
    let size = (CONTROLS.0 * scale, CONTROLS.1 * scale);
    let (at, area) = place_controls(Rect { x, y, w, h }, bounds, size, 12.0 * scale);
    let first = capture::crop(&grab.image, area.x, area.y, area.w, area.h);

    let control = Arc::new(Control::default());
    st(app).session.lock().unwrap().scroll = Some(control.clone());
    hide_floating(app, true);
    let icons = desktop::hide(app);
    let built = crate::builder(app, "scroll", "scroll.html", json!({ "message": SCROLLING })).title("Scrolling Capture").inner_size(CONTROLS.0, CONTROLS.1)
        .decorations(false).transparent(true).shadow(false).resizable(false).always_on_top(true).skip_taskbar(true).focusable(false).focused(false).visible_on_all_workspaces(true).build();
    let Ok(window) = built else {
        drop(icons);
        finish(app);
        notify(app, "Scrolling capture couldn’t start", "Still couldn’t open its controls.");
        return;
    };
    let _ = window.set_size(PhysicalSize::new(size.0 as u32, size.1 as u32));
    let _ = window.set_position(PhysicalPosition::new(grab.x + at.0 as i32, grab.y + at.1 as i32));
    let _ = window.show();
    build_tray_menu(app);
    let (app, display) = (app.clone(), grab.id);
    std::thread::spawn(move || run(app, control, display, area, first, icons));
}

fn run(app: AppHandle, control: Arc<Control>, display: u32, area: Rect, first: RgbaImage, icons: Option<desktop::Hidden>) {
    let mut stitcher = Scroller::new(first);
    let save = loop {
        let state = control.wait(TICK);
        if state == CANCELLED { break false; }
        // Done takes one last grab, so a scroll made just before clicking still counts.
        let grabbed = capture::grab_display(display).map(|g| capture::crop(&g.image, area.x, area.y, area.w, area.h));
        let result = grabbed.and_then(|frame| stitcher.append(frame).map_err(|e| e.message().to_string()));
        report(&app, &stitcher, result.as_ref().err().map(String::as_str).unwrap_or(SCROLLING));
        if state == DONE { break true; }
    };
    drop(icons);
    finish(&app);
    if save { complete_image(&app, stitcher.into_image(), false); }
}

fn report(app: &AppHandle, stitcher: &Scroller, message: &str) {
    let (w, h) = stitcher.dimensions();
    let _ = app.emit_to("scroll", "scroll:status", json!({ "frames": stitcher.frames(), "width": w, "height": h, "message": message }));
}

fn finish(app: &AppHandle) {
    st(app).session.lock().unwrap().scroll = None;
    if let Some(window) = app.get_webview_window("scroll") { let _ = window.close(); }
    hide_floating(app, false);
    build_tray_menu(app);
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    /// A made-up page: bands of grey of uneven height, so that no two stretches of it look alike.
    fn page(width: u32, height: u32) -> RgbaImage {
        let mut image = RgbaImage::new(width, height);
        let (mut state, mut y) = (0x2545_F491_4F6C_DD1Du64, 0);
        let mut next = move || { state ^= state << 13; state ^= state >> 7; state ^= state << 17; state };
        while y < height {
            let (band, base) = (3 + (next() % 18) as u32, (next() % 256) as u8);
            for row in y..(y + band).min(height) {
                for x in 0..width { let shade = base.wrapping_add((x / 7 * 13) as u8 / 4); image.put_pixel(x, row, Rgba([shade, shade, shade, 255])); }
            }
            y += band;
        }
        image
    }
    fn frame(source: &RgbaImage, top: u32, height: u32) -> RgbaImage { image::imageops::crop_imm(source, 0, top, source.width(), height).to_image() }
    fn stitched(source: &RgbaImage, height: u32, tops: &[u32]) -> RgbaImage {
        let mut stitcher = Stitcher::new(frame(source, tops[0], height));
        for top in &tops[1..] { stitcher.append(frame(source, *top, height)).unwrap(); }
        stitcher.into_image()
    }

    /// Lines of "text": same spacing and same weight all the way down, so that at a glance every line
    /// looks like the next, and only the positions of the words tell them apart. Some paragraphs come
    /// back word for word, as they do on real pages.
    fn text_page(width: u32, height: u32, repeats: bool) -> RgbaImage {
        let mut image = RgbaImage::from_pixel(width, height, Rgba([255, 255, 255, 255]));
        let mut state = 0x9E37_79B9_7F4A_7C15u64;
        let next = |state: &mut u64| { *state ^= *state << 13; *state ^= *state >> 7; *state ^= *state << 17; *state };
        let mut order = 0x2545_F491_4F6C_DD1Du64;
        for line in 0..height / 22 {
            if repeats && line % 6 == 0 { state = 0x9E37_79B9_7F4A_7C15 + next(&mut order) % 5; }
            let mut x = 20;
            while x < width - 40 {
                let word = 12 + (next(&mut state) % 50) as u32;
                for y in line * 22 + 6..line * 22 + 16 { for dx in 0..word.min(width - x - 1) { if (dx + y) % 3 != 0 { image.put_pixel(x + dx, y, Rgba([40, 40, 40, 255])); } } }
                x += word + 8;
            }
        }
        image
    }

    #[test]
    fn lines_of_text_are_not_mistaken_for_each_other() {
        let source = text_page(1100, 2400, true);
        assert!(stitched(&source, 620, &[0, 150, 240, 541, 585, 900, 1020, 1400, 1780]) == source);
        assert!(stitched(&source, 240, &[0, 60, 180, 213, 363, 443, 543]) == frame(&source, 0, 783));
    }
    #[test]
    fn a_jump_too_big_to_follow_is_refused_rather_than_guessed() {
        let source = text_page(1100, 1600, false);
        let mut stitcher = Stitcher::new(frame(&source, 0, 620));
        assert_eq!(stitcher.append(frame(&source, 540, 620)), Err(StitchError::NoOverlap));
        stitcher.append(frame(&source, 300, 620)).unwrap();
        assert!(stitcher.into_image() == frame(&source, 0, 920));
    }
    #[test]
    fn scrolling_sideways_rebuilds_the_page() {
        let source = image::imageops::rotate270(&page(160, 500)); // 500 wide, 160 tall.
        let across = |left: u32| image::imageops::crop_imm(&source, left, 0, 200, 160).to_image();
        let mut scroller = Scroller::new(across(0));
        for left in [70, 150, 230, 300] { scroller.append(across(left)).unwrap(); }
        assert_eq!(scroller.dimensions(), (500, 160));
        assert!(scroller.into_image() == source);
    }
    #[test]
    fn scrolling_down_is_still_down_when_either_way_is_possible() {
        let source = page(160, 500);
        let mut scroller = Scroller::new(frame(&source, 0, 200));
        for top in [70, 150, 230, 300] { scroller.append(frame(&source, top, 200)).unwrap(); }
        assert_eq!(scroller.frames(), 5);
        assert!(scroller.into_image() == source);
    }
    #[test]
    fn scrolling_down_rebuilds_the_page() {
        let source = page(160, 500);
        let result = stitched(&source, 200, &[0, 70, 150, 230, 300]);
        assert_eq!(result.dimensions(), (160, 500));
        assert!(result == source);
    }
    #[test]
    fn tall_areas_line_up_to_the_exact_pixel() {
        let source = page(120, 1400);
        let result = stitched(&source, 700, &[0, 233, 480, 700]);
        assert!(result == source);
    }
    #[test]
    fn scrolling_up_past_the_start_adds_above() {
        let source = page(160, 420);
        let result = stitched(&source, 200, &[220, 150, 80, 0]);
        assert!(result == source);
    }
    #[test]
    fn scrolling_back_and_on_again_adds_nothing_twice() {
        let source = page(160, 460);
        assert!(stitched(&source, 200, &[0, 90, 30, 110, 260]) == source);
    }
    #[test]
    fn an_unchanged_frame_changes_nothing() {
        let source = page(160, 300);
        let first = frame(&source, 0, 200);
        let result = stitch_frame(&first, 0, &first, &first.clone()).unwrap();
        assert!(matches!(result, Stitched::Unchanged));
    }
    #[test]
    fn sticky_header_and_footer_appear_once() {
        let (content, bar) = (page(160, 460), 24);
        let header = RgbaImage::from_pixel(160, bar, Rgba([20, 90, 200, 255]));
        let footer = RgbaImage::from_pixel(160, bar, Rgba([200, 90, 20, 255]));
        let window = |top: u32| {
            let mut f = frame(&content, top, 200);
            image::imageops::replace(&mut f, &header, 0, 0);
            image::imageops::replace(&mut f, &footer, 0, 176);
            f
        };
        let mut stitcher = Stitcher::new(window(0));
        for top in [80, 170, 260] { stitcher.append(window(top)).unwrap(); }
        let result = stitcher.into_image();
        assert_eq!(result.height(), 460);
        assert!(frame(&result, 0, 24) == header);
        assert!(frame(&result, 436, 24) == footer);
        assert!(frame(&result, 24, 412) == frame(&content, 24, 412));
    }
    #[test]
    fn losing_the_overlap_is_an_error_and_recovers() {
        let source = page(160, 800);
        let mut stitcher = Stitcher::new(frame(&source, 0, 200));
        assert_eq!(stitcher.append(frame(&source, 500, 200)), Err(StitchError::NoOverlap));
        stitcher.append(frame(&source, 120, 200)).unwrap();
        assert!(stitcher.into_image() == frame(&source, 0, 320));
    }
    #[test]
    fn a_frame_of_another_size_is_refused() {
        let source = page(160, 300);
        let mut stitcher = Stitcher::new(frame(&source, 0, 200));
        assert_eq!(stitcher.append(frame(&source, 0, 180)), Err(StitchError::DifferentSize));
    }
    #[test]
    fn the_picture_stops_growing_at_the_limit() {
        let source = page(160, 300);
        let (previous, next) = (frame(&source, 0, 200), frame(&source, 60, 200));
        let full = RgbaImage::new(160, MAX_HEIGHT);
        let position = MAX_HEIGHT as i64 - 200;
        assert_eq!(stitch_frame(&full, position, &previous, &next).unwrap_err(), StitchError::TooLarge);
    }
    #[test]
    fn controls_stay_out_of_the_capture() {
        let screen = Rect { x: 0.0, y: 0.0, w: 1920.0, h: 1040.0 };
        let area = Rect { x: 100.0, y: 100.0, w: 600.0, h: 400.0 };
        assert_eq!(place_controls(area, screen, (488.0, 68.0), 12.0), ((156.0, 512.0), area));
        let low = Rect { y: 900.0, h: 140.0, ..area };
        assert_eq!(place_controls(low, screen, (488.0, 68.0), 12.0), ((156.0, 820.0), low));
        // Nothing free above or below: the area gives up the rows under the controls.
        let tall = Rect { x: 0.0, y: 0.0, w: 1920.0, h: 1040.0 };
        let ((_, y), grabbed) = place_controls(tall, screen, (488.0, 68.0), 12.0);
        assert_eq!(y, 960.0);
        assert_eq!(grabbed, Rect { h: 948.0, ..tall });
        assert!(grabbed.y + grabbed.h <= y);
    }
    #[test]
    fn controls_fit_a_screen_narrower_than_they_are() {
        let screen = Rect { x: 0.0, y: 0.0, w: 300.0, h: 600.0 };
        let ((x, _), _) = place_controls(Rect { x: 10.0, y: 10.0, w: 100.0, h: 100.0 }, screen, (488.0, 68.0), 12.0);
        assert_eq!(x, 12.0);
    }
    #[test]
    fn only_the_first_stop_counts() {
        let control = Control::default();
        control.request(CANCELLED);
        control.request(DONE);
        assert_eq!(control.wait(Duration::ZERO), CANCELLED);
    }
}
