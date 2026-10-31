//! Several captures joined into one picture, side by side or top to bottom. Each is scaled to the smallest height
//! (side by side) or width (top to bottom) among them, so none is enlarged and blurred, and they line up exactly.
//! The Mac app's CaptureCombine follows the same rules and shares these tests' cases.

use image::{imageops, RgbaImage};

/// Where each picture goes, as (x, y, width, height), and the size of the whole.
pub fn layout(sizes: &[(u32, u32)], vertical: bool) -> ((u32, u32), Vec<(u32, u32, u32, u32)>) {
    let sizes: Vec<(u32, u32)> = sizes.iter().map(|&(w, h)| (w.max(1), h.max(1))).collect();
    if sizes.is_empty() { return ((0, 0), vec![]); }
    let side = if vertical { sizes.iter().map(|s| s.0).min().unwrap() } else { sizes.iter().map(|s| s.1).min().unwrap() };
    let mut frames = Vec::new();
    let mut along = 0u32;
    for &(w, h) in &sizes {
        let frame = if vertical {
            let height = ((h as f64) * side as f64 / w as f64).round().max(1.0) as u32;
            (0, along, side, height)
        } else {
            let width = ((w as f64) * side as f64 / h as f64).round().max(1.0) as u32;
            (along, 0, width, side)
        };
        along += if vertical { frame.3 } else { frame.2 };
        frames.push(frame);
    }
    (if vertical { (side, along) } else { (along, side) }, frames)
}

pub fn combine(images: &[RgbaImage], vertical: bool) -> RgbaImage {
    let sizes: Vec<(u32, u32)> = images.iter().map(|i| i.dimensions()).collect();
    let ((w, h), frames) = layout(&sizes, vertical);
    let mut out = RgbaImage::new(w.max(1), h.max(1));
    for (image, &(x, y, fw, fh)) in images.iter().zip(&frames) {
        let piece = if (fw, fh) == image.dimensions() { image.clone() } else { imageops::resize(image, fw, fh, imageops::FilterType::Lanczos3) };
        imageops::replace(&mut out, &piece, x as i64, y as i64);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // The same cases are in the Mac app's CaptureCombineTests.
    #[test]
    fn side_by_side_shares_the_smallest_height() {
        assert_eq!(layout(&[(800, 600), (400, 300)], false), ((800, 300), vec![(0, 0, 400, 300), (400, 0, 400, 300)]));
        assert_eq!(layout(&[(100, 200), (300, 100), (50, 50)], false), ((225, 50), vec![(0, 0, 25, 50), (25, 0, 150, 50), (175, 0, 50, 50)]));
    }

    #[test]
    fn top_to_bottom_shares_the_smallest_width() {
        assert_eq!(layout(&[(1200, 400), (600, 900)], true), ((600, 1100), vec![(0, 0, 600, 200), (0, 200, 600, 900)]));
    }

    #[test]
    fn pictures_land_in_their_frames() {
        let red = RgbaImage::from_pixel(4, 2, image::Rgba([255, 0, 0, 255]));
        let blue = RgbaImage::from_pixel(2, 2, image::Rgba([0, 0, 255, 255]));
        let out = combine(&[red, blue], false);
        assert_eq!(out.dimensions(), (6, 2));
        assert_eq!(out.get_pixel(3, 1).0, [255, 0, 0, 255]);
        assert_eq!(out.get_pixel(4, 0).0, [0, 0, 255, 255]);
    }
}
