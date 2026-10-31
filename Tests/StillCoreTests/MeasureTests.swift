import XCTest
@testable import StillCore

/// The same cases as the Measure test in Desktop/test/marks.test.js.
final class MeasureTests: XCTestCase {
    private func label(_ a: (Double, Double), _ b: (Double, Double)) -> String {
        Mark(tool: .measure, points: [PixelPoint(x: a.0, y: a.1), PixelPoint(x: b.0, y: b.1)]).measureLabel
    }

    func testLabelledWithItsLengthAndItsSidesWhenSlanted() {
        XCTAssertEqual(label((10, 20), (250, 20)), "240 px")
        XCTAssertEqual(label((0, 0), (300, 400)), "500 px  (300 × 400)")
        XCTAssertEqual(label((5, 5), (5, 5)), "0 px")
    }

    func testDrawsOverThePicture() throws {
        let context = CGContext(data: nil, width: 400, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 400, height: 120))
        let mark = Mark(tool: .measure, points: [PixelPoint(x: 20, y: 60), PixelPoint(x: 380, y: 60)], color: "FF0000", width: 4)
        let out = try ImageRenderer.render(context.makeImage()!, marks: [mark])
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        let pixel = { (x: Int, y: Int) in Array(data[(y * out.bytesPerRow + x * 4)..<(y * out.bytesPerRow + x * 4 + 3)]) }
        XCTAssertEqual(pixel(60, 60), [255, 0, 0], "the line, in the mark's colour")
        let dark = (170..<230).contains { x in (52..<68).contains { y in pixel(x, y).allSatisfy { $0 < 60 } } }
        XCTAssertTrue(dark, "a dark pill behind the label at the middle")
    }
}
