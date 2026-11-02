//! Find Similar: each screenshot gets a 64-bit fingerprint from a 9 × 8 grey copy of it, one bit per neighbouring
//! pair (is the left one brighter than the right?). Pictures that look alike differ in few bits, whatever their size,
//! scaling or file format. The Mac app's ImageFingerprint uses the same rules and test cases.
use image::{imageops::FilterType, RgbaImage};

/// How many of the 64 bits may differ for two pictures to count as similar.
pub const SIMILAR: u32 = 12;

/// The fingerprint of 72 grey values, 9 across and 8 down (0 = black, 255 = white).
pub fn from_grey(grey: &[u8]) -> u64 {
    let mut bits = 0u64;
    for y in 0..8 { for x in 0..8 { bits = (bits << 1) | (grey[y * 9 + x] > grey[y * 9 + x + 1]) as u64; } }
    bits
}

pub fn fingerprint(image: &RgbaImage) -> u64 {
    let small = image::imageops::resize(image, 9, 8, FilterType::Triangle);
    let grey: Vec<u8> = small.pixels().map(|p| {
        // Transparent parts count as white, as they look on most pages.
        let a = p[3] as f32 / 255.0;
        let luma = 0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32;
        (luma * a + 255.0 * (1.0 - a)).round() as u8
    }).collect();
    from_grey(&grey)
}

pub fn distance(a: u64, b: u64) -> u32 { (a ^ b).count_ones() }

/// The candidates within SIMILAR of `target`, closest first (ties keep their order), at most `limit` of them.
pub fn rank(target: u64, candidates: &[(String, u64)], limit: usize) -> Vec<(String, u32)> {
    let mut found: Vec<(String, u32)> = candidates.iter().map(|(id, f)| (id.clone(), distance(target, *f))).filter(|(_, d)| *d <= SIMILAR).collect();
    found.sort_by_key(|(_, d)| *d);
    found.truncate(limit);
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    // The same cases are in the Mac app's ImageFingerprintTests.
    fn ramp(right_darker: bool) -> Vec<u8> { (0..72).map(|i| { let x = (i % 9) as u8; if right_darker { 255 - x * 20 } else { x * 20 } }).collect() }

    #[test]
    fn bits_say_where_the_left_is_brighter() {
        assert_eq!(from_grey(&ramp(true)), u64::MAX);
        assert_eq!(from_grey(&ramp(false)), 0);
        let mut one = ramp(false); one[0] = 255; // only the first pair of the first row
        assert_eq!(from_grey(&one), 1 << 63);
    }

    #[test]
    fn the_same_picture_at_another_size_matches() {
        let big = RgbaImage::from_fn(900, 400, |x, y| { let v = ((x / 100 + y / 100) % 2 * 200 + 20) as u8; image::Rgba([v, v / 2, 255 - v, 255]) });
        let small = image::imageops::resize(&big, 300, 133, FilterType::Triangle);
        assert!(distance(fingerprint(&big), fingerprint(&small)) <= 4);
        let other = RgbaImage::from_fn(900, 400, |x, _| { let v = (x * 255 / 899) as u8; image::Rgba([v, v, v, 255]) });
        assert!(distance(fingerprint(&big), fingerprint(&other)) > SIMILAR);
    }

    #[test]
    fn ranking_keeps_the_close_ones_closest_first() {
        let list = vec![("far".to_string(), u64::MAX), ("two".to_string(), 0b11), ("same".to_string(), 0), ("ten".to_string(), 0x3FF)];
        assert_eq!(rank(0, &list, 10), vec![("same".to_string(), 0), ("two".to_string(), 2), ("ten".to_string(), 10)]);
        assert_eq!(rank(0, &list, 1), vec![("same".to_string(), 0)]);
    }
}
