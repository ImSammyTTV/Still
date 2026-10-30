import XCTest
import AppKit
@testable import StillCore

/// Scrolling capture on rendered text, the case flat test patterns don't reach: a wrong join looks fine at a glance,
/// so each run is compared with the original page pixel by pixel.
final class ScrollingTextPageTests: XCTestCase {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }
    static func page(repeated: Bool, width: Int = 900, height: Int = 4200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let words = "still capture screen window arrow text blur crop share preview marks editor record clipboard folder shadow border backdrop".split(separator: " ").map(String.init)
        var y = height-40, index = 0, seed = 7
        while y > 30 {
            var line = ""
            // A long cycle of sentences, like repeated paragraphs. Any page that repeats within one frame can't be solved.
            if repeated { line = ["The quick brown fox jumps over the lazy dog", "and keeps on running past the river bank", "while the sun goes down behind the hills", "until the night falls over the quiet town", "and every window glows against the dark"][(index/6) % 5]+" and keeps going" }
            else { for _ in 0..<12 { seed = (seed*7919+13) % 1009; line += words[seed % words.count]+" " }; line += String(index) }
            (line as NSString).draw(at: NSPoint(x: 24, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
            index += 1; y -= index % 6 == 0 ? 44 : 24
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
    private static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width*image.height*4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
    /// One simulated capture; true when the result exactly matches the page.
    static func run(_ page: CGImage, area: Int, seed: UInt64) throws -> (matches: Bool, refused: Int) {
        var generator = Generator(state: seed)
        func frame(_ top: Int) throws -> CGImage { try ImageRenderer.crop(page, to: CGRect(x: 0, y: top, width: page.width, height: area)) }
        var top = 0, refused = 0, shown = 0
        let stitcher = try ScrollingStitcher(frame(0))
        while top+area < page.height && shown < 4 {
            let jump = Int.random(in: 20...max(21, area*7/10), using: &generator)
            top = min(page.height-area, top+jump)
            do { try stitcher.append(frame(top)); shown += 1 }
            catch StitchError.noOverlap { refused += 1; top -= jump } // the user scrolls back
        }
        let result = try stitcher.result()
        let expected = try ImageRenderer.crop(page, to: CGRect(x: 0, y: 0, width: page.width, height: top+area))
        return (result.height == expected.height && pixels(result) == pixels(expected), refused)
    }
    func testStitchedTextMatchesThePageExactly() throws {
        for repeated in [true, false] {
            let page = Self.page(repeated: repeated, height: 1800)
            for seed: UInt64 in 1...2 { XCTAssertTrue(try Self.run(page, area: 300, seed: seed).matches, "repeated: \(repeated), seed: \(seed)") }
        }
    }
}
