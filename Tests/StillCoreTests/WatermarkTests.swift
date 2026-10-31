import XCTest
@testable import StillCore

/// The same cases as Desktop/test/watermark.test.js.
final class WatermarkTests: XCTestCase {
    func testNoTextMeansNoWatermarkAndOddSettingsFallBack() {
        XCTAssertNil(Watermark(text: "   "))
        let w = Watermark(text: " © Sam ", position: "middle", size: "huge", opacity: 5)
        XCTAssertEqual(w?.text, "© Sam"); XCTAssertEqual(w?.position, "bottomRight"); XCTAssertEqual(w?.size, "medium"); XCTAssertEqual(w?.opacity, 1)
    }

    func testSizedFromTheShorterSideAndKeptOffTheEdges() {
        XCTAssertEqual(Watermark(text: "x")!.placement(width: 1920, height: 1080), .init(fontSize: 35, margin: 32, x: 1888, y: 1048, alignX: 1, alignY: 1))
        XCTAssertEqual(Watermark(text: "x", position: "topLeft", size: "small")!.placement(width: 400, height: 300), .init(fontSize: 11, margin: 10, x: 10, y: 10, alignX: 0, alignY: 0))
        XCTAssertEqual(Watermark(text: "x", position: "center", size: "large")!.placement(width: 1000, height: 800), .init(fontSize: 38, margin: 34, x: 500, y: 400, alignX: 0.5, alignY: 0.5))
        XCTAssertEqual(Watermark(text: "x", size: "large")!.placement(width: 8000, height: 6000).fontSize, 96)
    }

    func testDrawsInTheChosenCorner() throws {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let out = Watermark(text: "WWWWWW", position: "bottomRight", size: "large", opacity: 1)!.apply(to: context.makeImage()!)
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        func brightest(_ xs: Range<Int>, _ ys: Range<Int>) -> UInt8 { var best: UInt8 = 0; for y in ys { for x in xs { best = max(best, data[y * out.bytesPerRow + x * 4]) } }; return best }
        XCTAssertGreaterThan(brightest(200..<400, 200..<300), 200, "text in the bottom right")
        XCTAssertLessThan(brightest(0..<200, 0..<150), 40, "nothing in the top left")
    }
}
