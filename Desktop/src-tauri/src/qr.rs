//! QR codes for Capture Text: decoded here in Rust, then added to what the OCR page finds.

use image::RgbaImage;

/// The contents of every QR code in the image, each one once, in the order they were found.
pub fn read(image: &RgbaImage) -> Vec<String> {
    let (width, height) = (image.width() as usize, image.height() as usize);
    let mut prepared = rqrr::PreparedImage::prepare_from_greyscale(width, height, |x, y| {
        let p = image.as_raw()[(y * width + x) * 4..][..3].try_into().unwrap_or([255u8; 3]);
        ((77 * p[0] as u32 + 150 * p[1] as u32 + 29 * p[2] as u32) >> 8) as u8
    });
    let mut codes: Vec<String> = Vec::new();
    for grid in prepared.detect_grids() {
        let mut bytes = Vec::new();
        if grid.decode_to(&mut bytes).is_err() { continue; }
        let text = String::from_utf8_lossy(&bytes).trim().to_string();
        if !text.is_empty() && !codes.contains(&text) { codes.push(text); }
    }
    codes
}

/// Recognised text first, then one QR code per line, as Capture Text does on the Mac.
pub fn with_text(text: &str, codes: &[String]) -> String {
    let text = text.trim();
    if codes.is_empty() { return text.to_string(); }
    let codes = codes.join("\n");
    if text.is_empty() { codes } else { format!("{text}\n{codes}") }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    /// A QR code holding "https://still.app", made with the macOS system generator.
    const CODE: [&str; 25] = [
        "#######.#.#...###.#######",
        "#.....#...#.###...#.....#",
        "#.###.#.##.##.###.#.###.#",
        "#.###.#...##..#.#.#.###.#",
        "#.###.#...#.###...#.###.#",
        "#.....#.##.##.....#.....#",
        "#######.#.#.#.#.#.#######",
        ".........#.#..#..........",
        "#.#...##..#..###...#..#.#",
        "#.##....#.#.########.#.##",
        ".##.####..#....#..#..##.#",
        "###.#....##.##.......#...",
        "#####.##.#.###.##.#.....#",
        ".#.#.#.####.#..##.##...##",
        "###.###.#.#.######...##.#",
        "...#...#...##.####.###...",
        "##..####.##..##.#####..#.",
        "........###..##.#...#...#",
        "#######.##.#....#.#.#...#",
        "#.....#..##..#..#...#..#.",
        "#.###.#..#.###.######..##",
        "#.###.#..##.#....#..#.##.",
        "#.###.#.###.###..#.###.##",
        "#.....#..####.#.#####....",
        "#######.###..##.###..#..#",
    ];

    fn draw(code: &[&str], scale: u32, at: (u32, u32), image: &mut RgbaImage) {
        for (y, row) in code.iter().enumerate() {
            for (x, cell) in row.chars().enumerate() {
                if cell != '#' { continue; }
                for dy in 0..scale { for dx in 0..scale { image.put_pixel(at.0 + x as u32 * scale + dx, at.1 + y as u32 * scale + dy, Rgba([0, 0, 0, 255])); } }
            }
        }
    }
    fn white(width: u32, height: u32) -> RgbaImage { RgbaImage::from_pixel(width, height, Rgba([255, 255, 255, 255])) }

    #[test]
    fn reads_a_code_on_a_screenshot() {
        let mut image = white(400, 300);
        draw(&CODE, 6, (90, 40), &mut image);
        assert_eq!(read(&image), vec!["https://still.app".to_string()]);
    }
    #[test]
    fn the_same_code_twice_is_listed_once() {
        let mut image = white(500, 240);
        draw(&CODE, 5, (20, 40), &mut image);
        draw(&CODE, 5, (270, 40), &mut image);
        assert_eq!(read(&image).len(), 1);
    }
    #[test]
    fn a_screenshot_without_a_code_finds_nothing() {
        let mut state = 0x9E37_79B9_7F4A_7C15u64;
        let image = RgbaImage::from_fn(640, 480, |_, _| { state ^= state << 13; state ^= state >> 7; state ^= state << 17; let v = state as u8; Rgba([v, v, v, 255]) });
        assert!(read(&image).is_empty());
        assert!(read(&white(1, 1)).is_empty());
    }
    #[test]
    fn codes_follow_the_text() {
        let codes = ["https://a.example".to_string(), "second".to_string()];
        assert_eq!(with_text(" Hello\n", &[]), "Hello");
        assert_eq!(with_text("Hello\n", &codes), "Hello\nhttps://a.example\nsecond");
        assert_eq!(with_text("  ", &codes), "https://a.example\nsecond");
    }
}
