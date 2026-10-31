import XCTest
@testable import StillCore

final class StampTests: XCTestCase {
    func testAClickDropsASquareThatSuitsThePicture() {
        let small = Mark.stampBox(at: CGPoint(x: 100, y: 100), pictureSize: CGSize(width: 300, height: 200))
        XCTAssertEqual(small.0, PixelPoint(x: 76, y: 76)); XCTAssertEqual(small.1, PixelPoint(x: 124, y: 124))
        let large = Mark.stampBox(at: CGPoint(x: 1000, y: 500), pictureSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(large.1.x - large.0.x, 180)
    }

    func testTheEmojiIsDrawnInItsBox() throws {
        let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let mark = Mark(tool: .stamp, points: [PixelPoint(x: 50, y: 50), PixelPoint(x: 150, y: 150)], text: "❌")
        let out = try ImageRenderer.render(context.makeImage()!, marks: [mark])
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        let pixel = { (x: Int, y: Int) in Array(data[(y * out.bytesPerRow + x * 4)..<(y * out.bytesPerRow + x * 4 + 3)]) }
        let inked = (60..<140).contains { x in (60..<140).contains { y in pixel(x, y) != [255, 255, 255] } }
        XCTAssertTrue(inked, "something drawn inside the box")
        XCTAssertEqual(pixel(10, 10), [255, 255, 255], "nothing outside it")
    }
}
