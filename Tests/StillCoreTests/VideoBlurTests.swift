import XCTest
@testable import StillCore

/// The same cases as the moving, fading and see-through tests in Desktop/test/blurs.test.js.
final class VideoBlurTests: XCTestCase {
    private func near(_ a: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, accuracy: 1e-9, file: file, line: line) }

    func testAStillBlurIsItsBoxAndAKeyedOneGlides() {
        let still = VideoBlur(start: 0, end: 10, x: 0.1, y: 0.2, w: 0.3, h: 0.1)
        near(still.box(at: 5).minX, 0.1)
        var moving = still
        moving.keys = [VideoBlurKey(t: 2, x: 0.1, y: 0.2, w: 0.2, h: 0.1), VideoBlurKey(t: 6, x: 0.5, y: 0.6, w: 0.2, h: 0.1)]
        near(moving.box(at: 1).minX, 0.1)
        near(moving.box(at: 4).minX, 0.3); near(moving.box(at: 4).minY, 0.4)
        near(moving.box(at: 9).minX, 0.5)
        XCTAssertLessThan(moving.box(at: 2.5).minX, 0.1+0.4*0.125)
    }

    func testFadingAndSeeThrough() {
        var b = VideoBlur(start: 2, end: 8, x: 0, y: 0, w: 0.1, h: 0.1); b.fade = 1; b.opacity = 0.5
        near(b.alpha(at: 1), 0); near(b.alpha(at: 2), 0); near(b.alpha(at: 2.5), 0.25); near(b.alpha(at: 5), 0.5); near(b.alpha(at: 7.5), 0.25)
        near(VideoBlur(start: 0, end: 4).alpha(at: 2), 1)
        var short = VideoBlur(start: 0, end: 1); short.fade = 5
        near(short.alpha(at: 0.5), 1)
    }

    func testPlacingKeyingAndUnkeying() {
        let b = VideoBlur(start: 0, end: 10, x: 0.1, y: 0.1, w: 0.2, h: 0.2)
        near(b.placing(at: 3, CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)).x, 0.5)
        let keyed = b.addingKey(at: 4)
        XCTAssertEqual(keyed.keys?.map(\.t), [0, 4])
        let moved = keyed.placing(at: 4.02, CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(moved.keys?.map(\.t), [0, 4.02])
        near(moved.box(at: 10).minX, 0.6)
        let back = moved.removingKey(near: 4).removingKey(near: 0)
        XCTAssertNil(back.keys); near(back.x, 0.1); near(back.y, 0.1)
        XCTAssertEqual(moved.removingKey(near: 7), moved)
    }

    func testCornerHandlesAndRetiming() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        XCTAssertEqual(VideoBlur.handle(in: box, at: CGPoint(x: 0.61, y: 0.41)), "se")
        XCTAssertEqual(VideoBlur.handle(in: box, at: CGPoint(x: 0.4, y: 0.3)), "move")
        XCTAssertNil(VideoBlur.handle(in: box, at: CGPoint(x: 0.9, y: 0.9)))
        let se = VideoBlur.dragged(box, handle: "se", dx: 0.1, dy: 0.1)
        near(se.width, 0.5); near(se.height, 0.3); near(se.minX, 0.2)
        let nw = VideoBlur.dragged(box, handle: "nw", dx: 0.1, dy: 0.05)
        near(nw.minX, 0.3); near(nw.minY, 0.25); near(nw.width, 0.3); near(nw.height, 0.15)
        near(VideoBlur.dragged(box, handle: "move", dx: 0.9, dy: 0).minX, 0.6)
        let b = VideoBlur(start: 2, end: 5)
        near(b.retimed(start: true, to: 0, clipStart: 1, clipEnd: 9).start, 1)
        near(b.retimed(start: true, to: 4.95, clipStart: 1, clipEnd: 9).start, 4.8)
        near(b.retimed(start: false, to: 12, clipStart: 1, clipEnd: 9).end, 9)
    }

    func testPreviewGeometryMatchesTheFrame() {
        // A 1000×500 picture in a 1100×600 frame with 50 px padding fills the space inside the padding.
        let rect = VideoGeometry.pictureRect(output: CGSize(width: 1100, height: 600), source: CGSize(width: 1000, height: 500), padding: 50, zooms: [], time: 0)
        near(rect.minX, 50); near(rect.minY, 50); near(rect.width, 1000); near(rect.height, 500)
        // Zoomed 2× on the top-left corner: twice the size, pinned to the content's top-left.
        let zoom = ZoomSegment(start: 0, end: 10, scale: 2, x: 0, y: 0)
        let zoomed = VideoGeometry.pictureRect(output: CGSize(width: 1100, height: 600), source: CGSize(width: 1000, height: 500), padding: 50, zooms: [zoom], time: 5)
        near(zoomed.width, 2000); near(zoomed.minX, 50); near(zoomed.minY, 50)
        let fit = VideoGeometry.fitted(CGSize(width: 1600, height: 900), in: CGSize(width: 800, height: 800))
        near(fit.width, 800); near(fit.height, 450); near(fit.minY, 175)
    }
}
