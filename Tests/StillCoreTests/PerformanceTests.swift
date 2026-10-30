import XCTest
import AppKit
@testable import StillCore

/// Timing baselines for `swift test`. Debug builds run slower than the app; compare runs on the same machine.
final class PerformanceTests: XCTestCase {
    private let source: CGImage = {
        let context = CGContext(data: nil, width: 3440, height: 1440, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 3440, height: 1440))
        for row in 0..<60 { context.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor); context.fill(CGRect(x: 40, y: row*24, width: 1200+row*30, height: 11)) }
        return context.makeImage()!
    }()
    private let filtered = [Mark(tool: .blur, points: [.init(x: 100, y: 100), .init(x: 700, y: 500)], width: 8), Mark(tool: .pixelate, points: [.init(x: 800, y: 100), .init(x: 1200, y: 400)], width: 8)]
    func testCanvasRedrawWithFilteredMarks() {
        let cache = PreviewCache()
        measure { _ = try? ImageRenderer.preview(source, marks: filtered, cache: cache) }
    }
    func testLibraryEncode() {
        measure { _ = try? ImageRenderer.libraryData(source) }
    }
    func testBackgroundSheetPreview() {
        let cache = PreviewCache()
        measure { _ = try? ImageRenderer.render(source, frame: .ocean, maxDimension: 800, cache: cache) }
    }
}
