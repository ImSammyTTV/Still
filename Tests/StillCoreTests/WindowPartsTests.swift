import XCTest
@testable import StillCore

final class WindowPartsTests: XCTestCase {
    func testStepsFromTheWholeWindowIntoThePartUnderThePointerAndBack() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let page = CGRect(x: 4, y: 55, width: 992, height: 541), pane = CGRect(x: 600, y: 300, width: 200, height: 150)
        let point = CGPoint(x: 700, y: 350)
        XCTAssertEqual(WindowParts.part(of: window, parts: [pane, page], at: point, depth: 0).rect, window)
        XCTAssertEqual(WindowParts.part(of: window, parts: [pane, page], at: point, depth: 1).rect, page, "the largest part first")
        XCTAssertEqual(WindowParts.part(of: window, parts: [pane, page], at: point, depth: 2).rect, pane)
        XCTAssertEqual(WindowParts.part(of: window, parts: [pane, page], at: point, depth: 9).depth, 2)
        XCTAssertEqual(WindowParts.part(of: window, parts: [pane, page], at: CGPoint(x: 500, y: 20), depth: 1).deepest, 0)
    }
    func testOffersThePageButNotTheWholeWindowOrTinyControls() {
        let window = CGRect(x: 0, y: 0, width: 2000, height: 1200), page = CGRect(x: 8, y: 110, width: 1984, height: 1082)
        let parts = WindowParts.useful([window, page, page, CGRect(x: 40, y: 40, width: 30, height: 20), CGRect(x: -50, y: 100, width: 600, height: 400)], in: window)
        XCTAssertEqual(parts, [page, CGRect(x: 0, y: 100, width: 550, height: 400)])
    }
    func testFindsAPartBelowEachFullWidthLineNearTheTop() {
        // The same "browser" as geometry.test.js: title bar to y 30, toolbar to y 80, a partial page header to y 120.
        let lum: (Int, Int) -> Double = { x, y in y < 30 ? 60 : y < 80 ? 90 : (y < 120 && x < 300) ? 200 : 20 }
        XCTAssertEqual(WindowParts.bands(width: 600, height: 400, luminance: lum), [CGRect(x: 0, y: 30, width: 600, height: 370), CGRect(x: 0, y: 80, width: 600, height: 320)])
        XCTAssertEqual(WindowParts.bands(width: 600, height: 400) { _, _ in 128 }, [])
        XCTAssertEqual(WindowParts.bands(width: 100, height: 100, luminance: lum), [])
    }
}
