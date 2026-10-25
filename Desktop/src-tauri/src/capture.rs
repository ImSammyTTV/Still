use image::{codecs::jpeg::JpegEncoder, DynamicImage, ImageFormat, RgbaImage};
use serde::Serialize;
use std::io::Cursor;
use xcap::Monitor;
#[cfg(not(windows))]
use xcap::Window;

/// One display grabbed at full resolution. `x`/`y` are its top-left in physical pixels.
pub struct Grab {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub image: RgbaImage,
    /// Physical pixels per xcap unit (xcap reports logical units on some platforms).
    pub factor: f64,
}

pub fn grab_all() -> Result<Vec<Grab>, String> {
    let monitors = Monitor::all().map_err(|e| e.to_string())?;
    let mut grabs = Vec::new();
    for m in monitors {
        let image = match m.capture_image() { Ok(i) => i, Err(e) => { eprintln!("capture failed: {e}"); continue; } };
        let width = m.width().unwrap_or(image.width()).max(1);
        let factor = image.width() as f64 / width as f64;
        grabs.push(Grab {
            id: m.id().unwrap_or(0),
            x: (m.x().unwrap_or(0) as f64 * factor).round() as i32,
            y: (m.y().unwrap_or(0) as f64 * factor).round() as i32,
            image,
            factor,
        });
    }
    if grabs.is_empty() { return Err("Still couldn’t read the screen.".into()); }
    Ok(grabs)
}

/// A window frame in physical pixels, front to back.
#[derive(Clone, Serialize)]
pub struct WindowRect { pub id: u32, pub x: f64, pub y: f64, pub w: f64, pub h: f64 }

/// Windows: EnumWindows walks top-level windows front to back; DWM gives the visible frame
/// (without the invisible resize border) and tells us which windows are cloaked on other desktops.
#[cfg(windows)]
pub fn list_windows(_factor: f64) -> Vec<WindowRect> {
    use windows_sys::core::BOOL;
    use windows_sys::Win32::Foundation::{HWND, LPARAM, RECT};
    use windows_sys::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    unsafe extern "system" fn visit(hwnd: HWND, data: LPARAM) -> BOOL {
        let list = &mut *(data as *mut Vec<WindowRect>);
        if IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 { return 1; }
        if GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW != 0 { return 1; }
        let mut class = [0u16; 64];
        let len = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) as usize;
        let class = String::from_utf16_lossy(&class[..len]);
        if ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"].contains(&class.as_str()) { return 1; }
        let mut title = [0u16; 128];
        let tlen = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32) as usize;
        let title = String::from_utf16_lossy(&title[..tlen]);
        if title.is_empty() || title == "Capture Selection" { return 1; }
        let mut cloaked: u32 = 0;
        if DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED as u32, &mut cloaked as *mut _ as *mut _, 4) == 0 && cloaked != 0 { return 1; }
        let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
        if DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS as u32, &mut r as *mut _ as *mut _, std::mem::size_of::<RECT>() as u32) != 0 { return 1; }
        let (w, h) = ((r.right - r.left) as f64, (r.bottom - r.top) as f64);
        if w < 40.0 || h < 40.0 { return 1; }
        list.push(WindowRect { id: hwnd as usize as u32, x: r.left as f64, y: r.top as f64, w, h });
        1
    }
    let mut list: Vec<WindowRect> = Vec::new();
    unsafe { EnumWindows(Some(visit), &mut list as *mut _ as LPARAM); }
    list
}

/// Linux (X11) and macOS: xcap's window list, sorted front to back.
#[cfg(not(windows))]
pub fn list_windows(factor: f64) -> Vec<WindowRect> {
    let Ok(all) = Window::all() else { return vec![] };
    let mut list: Vec<(i32, WindowRect)> = all.into_iter().filter_map(|w| {
        if w.is_minimized().unwrap_or(true) { return None; }
        let title = w.title().unwrap_or_default();
        if title.is_empty() || title == "Capture Selection" { return None; }
        let (width, height) = (w.width().ok()? as f64 * factor, w.height().ok()? as f64 * factor);
        if width < 40.0 || height < 40.0 { return None; }
        Some((w.z().unwrap_or(0), WindowRect { id: w.id().ok()?, x: w.x().ok()? as f64 * factor, y: w.y().ok()? as f64 * factor, w: width, h: height }))
    }).collect();
    list.sort_by(|a, b| b.0.cmp(&a.0));
    list.into_iter().map(|(_, r)| r).collect()
}

pub fn crop(image: &RgbaImage, x: f64, y: f64, w: f64, h: f64) -> RgbaImage {
    let (iw, ih) = image.dimensions();
    let x0 = x.max(0.0).round() as u32;
    let y0 = y.max(0.0).round() as u32;
    let x0 = x0.min(iw.saturating_sub(1));
    let y0 = y0.min(ih.saturating_sub(1));
    let w = (w.round() as u32).clamp(1, iw - x0);
    let h = (h.round() as u32).clamp(1, ih - y0);
    image::imageops::crop_imm(image, x0, y0, w, h).to_image()
}

pub fn png(image: &RgbaImage) -> Vec<u8> {
    let mut out = Cursor::new(Vec::new());
    let _ = DynamicImage::ImageRgba8(image.clone()).write_to(&mut out, ImageFormat::Png);
    out.into_inner()
}

pub fn jpeg(image: &RgbaImage, quality: u8) -> Vec<u8> {
    let mut out = Vec::new();
    let rgb = DynamicImage::ImageRgba8(image.clone()).to_rgb8();
    let _ = JpegEncoder::new_with_quality(&mut out, quality).encode_image(&rgb);
    out
}

pub fn decode(bytes: &[u8]) -> Option<RgbaImage> { image::load_from_memory(bytes).ok().map(|i| i.to_rgba8()) }

pub fn data_url_bytes(data_url: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let b64 = data_url.split_once(",").map(|(_, b)| b).unwrap_or(data_url);
    base64::engine::general_purpose::STANDARD.decode(b64).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn crop_clamps_to_the_image() {
        let img = RgbaImage::new(100, 50);
        assert_eq!(crop(&img, 90.0, 40.0, 50.0, 50.0).dimensions(), (10, 10));
        assert_eq!(crop(&img, -5.0, -5.0, 20.0, 10.0).dimensions(), (20, 10));
    }
    #[test]
    fn encodes_png_and_jpeg_that_decode_again() {
        let img = RgbaImage::from_pixel(8, 4, image::Rgba([255, 0, 0, 255]));
        assert_eq!(decode(&png(&img)).unwrap().dimensions(), (8, 4));
        assert_eq!(decode(&jpeg(&img, 90)).unwrap().dimensions(), (8, 4));
    }
    #[test]
    fn data_urls_decode() {
        assert_eq!(data_url_bytes("data:text/plain;base64,aGk=").unwrap(), b"hi");
    }
}
