import XCTest
import CoreGraphics
@testable import StillCore

/// The same cases as Desktop/test/fit-size.test.js, plus a real JPEG made to fit.
final class ExportSizeTests: XCTestCase {
    private func fake(_ w: Double, _ h: Double) -> (Double, Double) -> Int { { scale, quality in Int((w*scale*h*scale*(0.2+quality)).rounded()) } }

    func testPlansACentredSquareAndKeepsTheShape() {
        XCTAssertEqual(ExportSize.plan(width: 1920, height: 1080, square: true, width: 500), .init(crop: CGRect(x: 420, y: 0, width: 1080, height: 1080), width: 500, height: 500))
        XCTAssertEqual(ExportSize.plan(width: 1000, height: 500, square: false, width: 400), .init(crop: CGRect(x: 0, y: 0, width: 1000, height: 500), width: 400, height: 200))
        XCTAssertEqual(ExportSize.plan(width: 800, height: 1200, square: true), .init(crop: CGRect(x: 0, y: 200, width: 800, height: 800), width: 800, height: 800))
    }
    func testNoLimitIsFullSizeAtTopQuality() {
        let r = ExportSize.fit(limit: 0, jpeg: true, encode: fake(100, 100))
        XCTAssertEqual([r.scale, r.quality], [1, 0.92]); XCTAssertTrue(r.fits)
    }
    func testJPEGLowersQualityFirst() {
        let r = ExportSize.fit(limit: 1_000_000, jpeg: true, encode: fake(1000, 1000))
        XCTAssertEqual(r.scale, 1); XCTAssertTrue(r.fits); XCTAssertLessThanOrEqual(r.bytes, 1_000_000)
        XCTAssertLessThan(r.quality, 0.92); XCTAssertGreaterThanOrEqual(r.quality, 0.5); XCTAssertGreaterThan(r.bytes, 900_000)
    }
    func testJPEGShrinksWhenLowQualityIsStillTooBig() {
        let r = ExportSize.fit(limit: 300_000, jpeg: true, encode: fake(1000, 1000))
        XCTAssertTrue(r.fits); XCTAssertLessThanOrEqual(r.bytes, 300_000); XCTAssertLessThan(r.scale, 1)
    }
    func testPNGOnlyShrinks() {
        let r = ExportSize.fit(limit: 400_000, jpeg: false, encode: fake(1000, 1000))
        XCTAssertTrue(r.fits); XCTAssertLessThan(r.scale, 1); XCTAssertEqual(r.quality, 1)
    }
    func testImpossibleLimitIsMarkedNotFitting() {
        XCTAssertFalse(ExportSize.fit(limit: 10, jpeg: true) { _, _ in 5000 }.fits)
    }
    func testMakesARealSquareJPEGUnderTheLimit() throws {
        // A noisy 1600 × 900 picture, which won't compress small by accident.
        let w = 1600, h = 900
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt32 = 0x9E3779B9
        for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            ctx.setFillColor(CGColor(red: CGFloat(seed & 255)/255, green: CGFloat((seed >> 8) & 255)/255, blue: CGFloat((seed >> 16) & 255)/255, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        } }
        let source = ctx.makeImage()!
        let plan = ExportSize.plan(width: w, height: h, square: true, width: 800)
        let out = try ExportSize.make(source, plan: plan, limit: 150_000, jpeg: true)
        XCTAssertTrue(out.fits); XCTAssertLessThanOrEqual(out.data.count, 150_000)
        XCTAssertEqual(out.width, out.height)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(out.data as CFData, nil)!, 0, nil)!
        XCTAssertEqual(decoded.width, out.width)
    }
    func testLabels() {
        XCTAssertEqual(ExportSize.label(480*1024), "480 KB")
        XCTAssertEqual(ExportSize.label(Int(2.5*1024*1024)), "2.5 MB")
    }
}
