import XCTest
@testable import StillCore

/// The same cases as the cut tests in Desktop/test/trim.test.js.
final class VideoTimelineTests: XCTestCase {
    func testCutsAreKeptSortedInsideTheClipAndMerged() {
        var cuts = VideoTimeline.adding([], from: 6, to: 4, start: 1, end: 10)
        XCTAssertEqual(cuts, [VideoCut(start: 4, end: 6)])
        cuts = VideoTimeline.adding(cuts, from: 5.5, to: 7, start: 1, end: 10)
        XCTAssertEqual(cuts, [VideoCut(start: 4, end: 7)])
        cuts = VideoTimeline.adding(cuts, from: 0, to: 2, start: 1, end: 10)
        XCTAssertEqual(cuts, [VideoCut(start: 1, end: 2), VideoCut(start: 4, end: 7)])
        XCTAssertEqual(VideoTimeline.adding(cuts, from: 8, to: 8.05, start: 1, end: 10), cuts, "too short to count")
    }

    func testKeptStretchesAndTimesEitherSideOfACut() {
        let kept = VideoTimeline.kept(start: 1, end: 10, cuts: [VideoCut(start: 4, end: 7)])
        XCTAssertEqual(kept, [VideoCut(start: 1, end: 4), VideoCut(start: 7, end: 10)])
        XCTAssertEqual(VideoTimeline.length(kept), 6)
        XCTAssertEqual(VideoTimeline.sourceTime(at: 0, kept: kept), 1)
        XCTAssertEqual(VideoTimeline.sourceTime(at: 3, kept: kept), 4)
        XCTAssertEqual(VideoTimeline.sourceTime(at: 3.5, kept: kept), 7.5)
        XCTAssertEqual(VideoTimeline.sourceTime(at: 99, kept: kept), 10)
        XCTAssertEqual(VideoTimeline.outputTime(at: 2, kept: kept), 1)
        XCTAssertEqual(VideoTimeline.outputTime(at: 5, kept: kept), 3)
        XCTAssertEqual(VideoTimeline.outputTime(at: 8, kept: kept), 4)
    }

    /// The same cases as the export size test in Desktop/test/geometry.test.js.
    func testExportSizesBringTheShorterSideDownNeverUpAndStayEven() {
        XCTAssertEqual(VideoExportSize.size(width: 2880, height: 1800, limit: 1080), CGSize(width: 1728, height: 1080))
        XCTAssertEqual(VideoExportSize.size(width: 1920, height: 1080, limit: 720), CGSize(width: 1280, height: 720))
        XCTAssertEqual(VideoExportSize.size(width: 1080, height: 1920, limit: 720), CGSize(width: 720, height: 1280))
        XCTAssertEqual(VideoExportSize.size(width: 1280, height: 720, limit: 1080), CGSize(width: 1280, height: 720))
        XCTAssertEqual(VideoExportSize.size(width: 1001, height: 563, limit: 0), CGSize(width: 1000, height: 562))
    }
}
