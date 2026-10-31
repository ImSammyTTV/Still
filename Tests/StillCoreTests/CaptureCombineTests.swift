import XCTest
@testable import StillCore

/// The same cases as combine.rs in the Windows and Linux app.
final class CaptureCombineTests: XCTestCase {
    func testSideBySideSharesTheSmallestHeight() {
        let a = CaptureCombine.layout([CGSize(width: 800, height: 600), CGSize(width: 400, height: 300)], vertical: false)
        XCTAssertEqual(a.size, CGSize(width: 800, height: 300))
        XCTAssertEqual(a.frames, [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 400, y: 0, width: 400, height: 300)])
        let b = CaptureCombine.layout([CGSize(width: 100, height: 200), CGSize(width: 300, height: 100), CGSize(width: 50, height: 50)], vertical: false)
        XCTAssertEqual(b.size, CGSize(width: 225, height: 50))
        XCTAssertEqual(b.frames, [CGRect(x: 0, y: 0, width: 25, height: 50), CGRect(x: 25, y: 0, width: 150, height: 50), CGRect(x: 175, y: 0, width: 50, height: 50)])
    }

    func testTopToBottomSharesTheSmallestWidth() {
        let a = CaptureCombine.layout([CGSize(width: 1200, height: 400), CGSize(width: 600, height: 900)], vertical: true)
        XCTAssertEqual(a.size, CGSize(width: 600, height: 1100))
        XCTAssertEqual(a.frames, [CGRect(x: 0, y: 0, width: 600, height: 200), CGRect(x: 0, y: 200, width: 600, height: 900)])
    }

    func testPicturesLandInTheirFrames() throws {
        func solid(_ w: Int, _ h: Int, _ rgb: (CGFloat, CGFloat, CGFloat)) -> CGImage {
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h)); return c.makeImage()!
        }
        // Red on top, blue below.
        let out = try XCTUnwrap(CaptureCombine.combine([solid(4, 2, (1, 0, 0)), solid(4, 4, (0, 0, 1))], vertical: true))
        XCTAssertEqual(out.width, 4); XCTAssertEqual(out.height, 6)
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        let pixel = { (x: Int, y: Int) in Array(data[(y * out.bytesPerRow + x * 4)..<(y * out.bytesPerRow + x * 4 + 3)]) }
        XCTAssertEqual(pixel(1, 0), [255, 0, 0])
        XCTAssertEqual(pixel(1, 5), [0, 0, 255])
    }
}
