import XCTest
@testable import StillCore

/// The same cases as the tests in Desktop/src-tauri/src/similar.rs.
final class ImageFingerprintTests: XCTestCase {
    private func ramp(rightDarker: Bool) -> [UInt8] { (0..<72).map { i in let x = UInt8(i % 9); return rightDarker ? 255 - x*20 : x*20 } }
    private func image(width: Int, height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height { for x in 0..<width { let c = color(x, y), i = (y*width+x)*4; pixels[i] = c.0; pixels[i+1] = c.1; pixels[i+2] = c.2 } }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testBitsSayWhereTheLeftIsBrighter() {
        XCTAssertEqual(ImageFingerprint.fromGrey(ramp(rightDarker: true)), UInt64.max)
        XCTAssertEqual(ImageFingerprint.fromGrey(ramp(rightDarker: false)), 0)
        var one = ramp(rightDarker: false); one[0] = 255
        XCTAssertEqual(ImageFingerprint.fromGrey(one), 1 << 63)
    }

    func testTheSamePictureAtAnotherSizeMatches() throws {
        let checks = { (x: Int, y: Int, cell: Int) -> (UInt8, UInt8, UInt8) in let v = UInt8(((x/cell + y/cell) % 2) * 200 + 20); return (v, v/2, 255-v) }
        let big = try XCTUnwrap(ImageFingerprint.fingerprint(image(width: 900, height: 400) { checks($0, $1, 100) }))
        let small = try XCTUnwrap(ImageFingerprint.fingerprint(image(width: 300, height: 133) { checks($0*3, $1*3, 100) }))
        XCTAssertLessThanOrEqual(ImageFingerprint.distance(big, small), 4)
        let other = try XCTUnwrap(ImageFingerprint.fingerprint(image(width: 900, height: 400) { x, _ in let v = UInt8(x*255/899); return (v, v, v) }))
        XCTAssertGreaterThan(ImageFingerprint.distance(big, other), ImageFingerprint.similar)
    }

    func testRankingKeepsTheCloseOnesClosestFirst() {
        let list: [(String, UInt64)] = [("far", .max), ("two", 0b11), ("same", 0), ("ten", 0x3FF)]
        XCTAssertEqual(ImageFingerprint.rank(0, list, limit: 10).map(\.0), ["same", "two", "ten"])
        XCTAssertEqual(ImageFingerprint.rank(0, list, limit: 10).map(\.1), [0, 2, 10])
        XCTAssertEqual(ImageFingerprint.rank(0, list, limit: 1).map(\.0), ["same"])
    }
}
