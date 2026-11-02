import XCTest
@testable import StillCore

/// The same cases as Desktop/test/sizes.test.js.
final class SocialSizesTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1000)
    private func near(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] { XCTAssertEqual(x, y, accuracy: 1e-6, "\(a) vs \(b)", file: file, line: line) }
    }

    func testEverySizeHasAUniqueIDAndWholeSides() {
        XCTAssertEqual(Set(SocialSizes.all.map(\.id)).count, SocialSizes.all.count)
        XCTAssertTrue(SocialSizes.all.allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertEqual(SocialSizes.size(id: "yt-banner")?.safe?.width, 1546)
        XCTAssertNil(SocialSizes.size(id: "nope"))
        XCTAssertEqual(SocialSizes.groups.first, "YouTube")
    }

    func testStartsAsTheLargestCropOfItsShapeInTheMiddle() {
        near(SocialSizes.centered(in: bounds, aspect: 16.0/9), CGRect(x: (2000-1000*16.0/9)/2, y: 0, width: 1000*16.0/9, height: 1000))
        near(SocialSizes.centered(in: bounds, aspect: 3), CGRect(x: 0, y: (1000-2000.0/3)/2, width: 2000, height: 2000.0/3))
        near(SocialSizes.centered(in: bounds, aspect: 1), CGRect(x: 500, y: 0, width: 1000, height: 1000))
    }

    func testDraggingKeepsTheShapeAndFollowsThePointerAlongItsDiagonal() {
        let drag = { (a: CGPoint, b: CGPoint) in SocialSizes.dragged(from: a, to: b, aspect: 2, within: self.bounds) }
        near(drag(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 300)), CGRect(x: 100, y: 100, width: 400, height: 200))
        near(drag(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 150)), CGRect(x: 100, y: 100, width: 340, height: 170))
        near(drag(CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 400)), CGRect(x: 100, y: 100, width: 160, height: 80))
        near(drag(CGPoint(x: 500, y: 500), CGPoint(x: 300, y: 400)), CGRect(x: 300, y: 400, width: 200, height: 100))
        near(drag(CGPoint(x: 100, y: 900), CGPoint(x: 900, y: 990)), CGRect(x: 100, y: 900, width: 200, height: 100))
    }

    func testSafeAreaAndNote() throws {
        let banner = try XCTUnwrap(SocialSizes.size(id: "yt-banner"))
        near(try XCTUnwrap(SocialSizes.safeArea(in: CGRect(x: 0, y: 0, width: 1280, height: 720), size: banner)), CGRect(x: (1280-773)/2.0, y: (720-211.5)/2, width: 773, height: 211.5))
        XCTAssertNil(SocialSizes.safeArea(in: CGRect(x: 0, y: 0, width: 10, height: 10), size: try XCTUnwrap(SocialSizes.size(id: "ig-square"))))
        XCTAssertEqual(SocialSizes.note(crop: CGRect(x: 0, y: 0, width: 1280, height: 720), size: banner), "2560 × 1440 · enlarged, may look soft")
        XCTAssertEqual(SocialSizes.note(crop: CGRect(x: 0, y: 0, width: 2560, height: 1440), size: banner), "2560 × 1440")
    }
}
