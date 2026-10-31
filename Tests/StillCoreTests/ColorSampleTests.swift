import CoreGraphics
import XCTest
@testable import StillCore

final class ColorSampleTests: XCTestCase {
    func testReadsOnePixelFromTheTopLeft() throws {
        // Two pixels: red on the left, blue on the right, one row.
        var bytes: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image: CGImage = try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        XCTAssertEqual(ColorSample.hex(in: image, x: 0, y: 0), "#FF0000")
        XCTAssertEqual(ColorSample.hex(in: image, x: 1, y: 0), "#0000FF")
        XCTAssertNil(ColorSample.hex(in: image, x: 2, y: 0))
        XCTAssertNil(ColorSample.hex(in: image, x: -1, y: 0))
    }

    func testRecentColoursAreNewestFirstWithoutRepeats() {
        XCTAssertEqual(ColorSample.remember("#ff8000", in: ["#111111", "#FF8000", "#222222"], max: 3), ["#FF8000", "#111111", "#222222"])
        XCTAssertEqual(ColorSample.remember("#ABCDEF", in: []), ["#ABCDEF"])
        XCTAssertEqual(ColorSample.remember("#FFFFFF", in: (0..<12).map { "#00000\($0 % 10)" }).count, 10)
    }
}
