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

    /// The same cases as Desktop/test/captions.test.js.
    func testCaptionsStartThreeSecondsLongInsideTheClip() {
        let c = VideoCaption.new(at: 2, start: 0, end: 10)
        XCTAssertEqual([c.start, c.end], [2, 5]); XCTAssertEqual(c.text, "Your text"); XCTAssertEqual(c.position, "bottom")
        XCTAssertEqual(VideoCaption.new(at: 9, start: 0, end: 10).end, 10)
    }

    func testCaptionsFadeInAndOut() {
        let c = VideoCaption(start: 1, end: 4, text: "Hi")
        XCTAssertNil(c.alpha(at: 0.5)); XCTAssertEqual(c.alpha(at: 1.125), 0.5); XCTAssertEqual(c.alpha(at: 2.5), 1)
        XCTAssertNil(VideoCaption(start: 2, end: 3, text: "").alpha(at: 2.5))
    }

    func testCaptionSizeAndPlaceFollowTheVideoArea() {
        let a = VideoCaption(start: 0, end: 1).layout(width: 1920, height: 1080)
        XCTAssertEqual(a.fontSize, 65); XCTAssertEqual(a.x, 960); XCTAssertEqual(a.y, 950.4, accuracy: 0.001)
        let b = VideoCaption(start: 0, end: 1, position: "top", size: "small").layout(width: 640, height: 360)
        XCTAssertEqual(b.fontSize, 16); XCTAssertEqual(b.y, 36, accuracy: 0.001)
        XCTAssertEqual(VideoCaption(start: 0, end: 1, position: "middle", size: "large").layout(width: 100, height: 100).fontSize, 12)
    }

    /// The same cases as Desktop/test/transitions.test.js.
    func testFadeOpensAndClosesOverSixTenthsOfASecond() {
        XCTAssertEqual(VideoTransition.at(1, start: 1, end: 11, opening: "fade", closing: "fade").level, 0)
        XCTAssertEqual(VideoTransition.at(1.3, start: 1, end: 11, opening: "fade", closing: "fade").level, 0.5, accuracy: 1e-9)
        XCTAssertEqual(VideoTransition.at(5, start: 1, end: 11, opening: "fade", closing: "fade").level, 1)
        XCTAssertEqual(VideoTransition.at(10.7, start: 1, end: 11, opening: "fade", closing: "fade").level, 0.5, accuracy: 1e-9)
        XCTAssertEqual(VideoTransition.at(1, start: 1, end: 11, opening: "none", closing: "fade").level, 1)
    }

    func testRiseGrowsThePictureOnlyOnItsOwnSide() {
        XCTAssertEqual(VideoTransition.at(0, start: 0, end: 10, opening: "rise", closing: "fade").scale, 0.92, accuracy: 1e-9)
        XCTAssertEqual(VideoTransition.at(0.3, start: 0, end: 10, opening: "rise", closing: "fade").scale, 0.96, accuracy: 1e-9)
        XCTAssertEqual(VideoTransition.at(10, start: 0, end: 10, opening: "rise", closing: "fade").scale, 1)
        XCTAssertEqual(VideoTransition.at(0.25, start: 0, end: 1.5, opening: "fade", closing: "none").level, 0.5, accuracy: 1e-9)
    }

    /// The same cases as the Tighten Pauses tests in Desktop/test/trim.test.js.
    func testLongSilencesBecomeCutsThatLeaveABeatEachSide() {
        let levels = Array(repeating: -20.0, count: 10) + Array(repeating: -70.0, count: 20) + Array(repeating: -20.0, count: 10) + Array(repeating: -70.0, count: 5) + Array(repeating: -20.0, count: 10)
        let cuts = AudioPauses.find(levels: levels, step: 0.1, start: 0, end: 5.5)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start, 1.3, accuracy: 1e-9); XCTAssertEqual(cuts[0].end, 2.7, accuracy: 1e-9)
        XCTAssertEqual(AudioPauses.find(levels: Array(repeating: -20.0, count: 30), step: 0.1, start: 0, end: 3), [])
    }

    func testLoudnessLevelsFromSamples() {
        XCTAssertEqual(AudioPauses.levels([1, -1, 1, -1, 0, 0, 0, 0], rate: 40, step: 0.1).map { $0.rounded() }, [0, -120])
    }

    /// The same cases as Desktop/test/blurs.test.js.
    func testBlursStartInTheMiddleAndStayInsideThePicture() {
        let b = VideoBlur.new(at: 2, start: 0, end: 4)
        XCTAssertEqual([b.start, b.end, b.x, b.y, b.w, b.h], [2, 4, 0.35, 0.42, 0.3, 0.16])
        let f = VideoBlur.fit(x: 0.9, y: 0.9, w: 0.5, h: 0.5); XCTAssertEqual([f.x, f.y, f.w, f.h], [0.5, 0.5, 0.5, 0.5])
        let g = VideoBlur.fit(x: 0.2, y: 0.2, w: 0, h: 0.001); XCTAssertEqual([g.x, g.y, g.w, g.h], [0.2, 0.2, 0.01, 0.01])
        let p = VideoBlur.fromPixels(CGRect(x: 104, y: 54, width: 192, height: 12), width: 400, height: 200, at: 0, start: 0, end: 5)
        XCTAssertEqual(p.x, 0.25, accuracy: 1e-9); XCTAssertEqual(p.y, 0.25, accuracy: 1e-9); XCTAssertEqual(p.w, 0.5, accuracy: 1e-9); XCTAssertEqual(p.h, 0.1, accuracy: 1e-9)
    }

    /// The same cases as Desktop/test/chapters.test.js.
    func testChaptersListInTheFinishedVideosTime() {
        let chapters = [VideoChapter(time: 75, title: "Setting up"), VideoChapter(time: 10, title: "Welcome"), VideoChapter(time: 200, title: "  Sharing   it ")]
        XCTAssertEqual(VideoChapters.list(chapters, start: 0, end: 300, cuts: []), "0:00 Intro\n0:10 Welcome\n1:15 Setting up\n3:20 Sharing it")
        XCTAssertEqual(VideoChapters.list(chapters, start: 10, end: 300, cuts: [VideoCut(start: 30, end: 50)], speed: 2), "0:00 Welcome\n0:22 Setting up\n1:25 Sharing it")
        XCTAssertEqual(VideoChapters.list([VideoChapter(time: 40, title: "Gone")], start: 0, end: 100, cuts: [VideoCut(start: 30, end: 50)]), "")
        XCTAssertEqual(VideoChapters.list([VideoChapter(time: 3725, title: "Late")], start: 0, end: 4000, cuts: []), "0:00 Intro\n1:02:05 Late")
    }
}
