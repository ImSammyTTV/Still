import XCTest
@testable import StillCore

final class SelectionGeometryTests: XCTestCase {
    func testKeyboardMovementClampsAtEveryDisplayEdge() {
        let bounds = CGRect(x: 0,y: 0,width: 1440,height: 900), rect = CGRect(x: 200,y: 100,width: 640,height: 360)
        XCTAssertEqual(SelectionGeometry.move(rect,within: bounds,dx: -1000,dy: -1000).origin,.zero)
        XCTAssertEqual(SelectionGeometry.move(rect,within: bounds,dx: 2000,dy: 2000).origin,CGPoint(x: 800,y: 540))
        let resized = SelectionGeometry.move(rect,within: bounds,dx: 1800,dy: 0,resize: true,aspect: 16.0/9)
        XCTAssertEqual(resized.width/resized.height,16.0/9,accuracy: 0.001)
        XCTAssertTrue(bounds.contains(resized))
    }
    func testMagnifierGrowsWithZoomAndNeverRestsUnderThePointer() {
        XCTAssertEqual(SelectionGeometry.magnifierZooms.map { SelectionGeometry.magnifierSize(zoom: $0) }, [80, 96, 112, 128, 144, 160, 176])
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for zoom in SelectionGeometry.magnifierZooms {
            let size = SelectionGeometry.magnifierSize(zoom: zoom)
            for p in [CGPoint(x: 500, y: 500), CGPoint(x: 1915, y: 500), CGPoint(x: 500, y: 3), CGPoint(x: 1915, y: 3), CGPoint(x: 3, y: 1075), CGPoint(x: 1915, y: 1075)] {
                let frame = SelectionGeometry.magnifierFrame(pointer: p, size: size, within: bounds)
                XCTAssertFalse(frame.contains(p), "size \(size) at \(p)")
                XCTAssertTrue(bounds.insetBy(dx: 9, dy: 9).contains(frame))
            }
        }
        XCTAssertEqual(SelectionGeometry.magnifierFrame(pointer: CGPoint(x: 500, y: 500), size: 144, within: bounds).origin, CGPoint(x: 524, y: 332))
    }
    func testCropSnapOnlyChangesPointsCloseToEdges() {
        let bounds = CGRect(x: 0,y: 0,width: 100,height: 80)
        XCTAssertEqual(SelectionGeometry.snap(CGPoint(x: 3,y: 77),within: bounds,tolerance: 5),CGPoint(x: 0,y: 80))
        XCTAssertEqual(SelectionGeometry.snap(CGPoint(x: 30,y: 40),within: bounds,tolerance: 5),CGPoint(x: 30,y: 40))
    }
    /// The same cases as Desktop/test/geometry.test.js.
    func testAFinishedSelectionCanBeGrabbedByItsEdgesCornersOrMiddle() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.handle(of: r, at: CGPoint(x: 200, y: 150)), "inside")
        XCTAssertEqual(SelectionGeometry.handle(of: r, at: CGPoint(x: 100, y: 150)), "w")
        XCTAssertEqual(SelectionGeometry.handle(of: r, at: CGPoint(x: 304, y: 150)), "e")
        XCTAssertEqual(SelectionGeometry.handle(of: r, at: CGPoint(x: 200, y: 97)), "n")
        XCTAssertEqual(SelectionGeometry.handle(of: r, at: CGPoint(x: 299, y: 201)), "se")
        XCTAssertEqual(SelectionGeometry.handle(of: r, at: CGPoint(x: 101, y: 99)), "nw")
        XCTAssertNil(SelectionGeometry.handle(of: r, at: CGPoint(x: 50, y: 50)))
    }
    func testResizingKeepsTheOppositeSideTheMinimumTheScreenAndTheShape() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100), bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SelectionGeometry.resize(r, handle: "e", dx: 50, dy: 0, within: bounds), CGRect(x: 100, y: 100, width: 250, height: 100))
        XCTAssertEqual(SelectionGeometry.resize(r, handle: "nw", dx: -20, dy: -30, within: bounds), CGRect(x: 80, y: 70, width: 220, height: 130))
        XCTAssertEqual(SelectionGeometry.resize(r, handle: "w", dx: 500, dy: 0, within: bounds), CGRect(x: 296, y: 100, width: 4, height: 100))
        XCTAssertEqual(SelectionGeometry.resize(r, handle: "n", dx: 0, dy: -500, within: bounds), CGRect(x: 100, y: 0, width: 200, height: 200))
        let sq = CGRect(x: 100, y: 100, width: 100, height: 100)
        XCTAssertEqual(SelectionGeometry.resize(sq, handle: "se", dx: 60, dy: 10, within: bounds, aspect: 1), CGRect(x: 100, y: 100, width: 160, height: 160))
        XCTAssertEqual(SelectionGeometry.resize(sq, handle: "s", dx: 0, dy: 40, within: bounds, aspect: 1), CGRect(x: 100, y: 100, width: 140, height: 140))
    }
}
