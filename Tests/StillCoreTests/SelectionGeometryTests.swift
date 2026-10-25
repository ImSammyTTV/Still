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
    func testCropSnapOnlyChangesPointsCloseToEdges() {
        let bounds = CGRect(x: 0,y: 0,width: 100,height: 80)
        XCTAssertEqual(SelectionGeometry.snap(CGPoint(x: 3,y: 77),within: bounds,tolerance: 5),CGPoint(x: 0,y: 80))
        XCTAssertEqual(SelectionGeometry.snap(CGPoint(x: 30,y: 40),within: bounds,tolerance: 5),CGPoint(x: 30,y: 40))
    }
}
