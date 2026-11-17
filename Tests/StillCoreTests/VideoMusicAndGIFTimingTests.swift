import XCTest
@testable import StillCore

final class VideoMusicAndGIFTimingTests: XCTestCase {
    private func level(_ levels: [(time: Double, level: Double)], at t: Double) -> Double? {
        levels.first { abs($0.time - t) < 1e-6 }?.level
    }

    func testMusicStaysAtItsVolumeWithNoSpeechOrFades() {
        let levels = VideoEngine.musicLevels(volume: 0.5, speech: [], fadeIn: 0, fadeOut: 10, finished: 10)
        XCTAssertEqual(levels.map { $0.time }, [0, 10])
        XCTAssertEqual(levels.map { $0.level }, [0.5, 0.5])
    }

    func testMusicFadesInAndOutWithTheOpeningAndClosing() {
        let levels = VideoEngine.musicLevels(volume: 0.4, speech: [], fadeIn: 0.6, fadeOut: 9.4, finished: 10)
        XCTAssertEqual(levels.map { $0.time }, [0, 0.6, 9.4, 10])
        XCTAssertEqual(level(levels, at: 0), 0)
        XCTAssertEqual(level(levels, at: 0.6)!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 9.4)!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 10), 0)
    }

    func testMusicDipsUnderSpeechAndTheFadesScaleTheDip() {
        // Speech from the very start: the opening fades in to the dipped level, not to full and then down.
        let levels = VideoEngine.musicLevels(volume: 1, speech: [VideoCut(start: 0, end: 2), VideoCut(start: 5, end: 6)], fadeIn: 0.6, fadeOut: 9.4, finished: 10)
        XCTAssertEqual(level(levels, at: 0), 0)
        XCTAssertEqual(level(levels, at: 0.6)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 2)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 2.15)!, 1, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 4.85)!, 1, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 5)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 6)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 6.15)!, 1, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 10), 0)
        // Times only ever go forward, so no two ramps overlap.
        XCTAssertEqual(levels.map { $0.time }, levels.map { $0.time }.sorted())
        XCTAssertEqual(Set(levels.map { $0.time }).count, levels.count)
    }

    func testSpeechRunningIntoTheClosingStaysDippedAsItFades() {
        let levels = VideoEngine.musicLevels(volume: 1, speech: [VideoCut(start: 8, end: 10)], fadeIn: 0, fadeOut: 9.4, finished: 10)
        XCTAssertEqual(level(levels, at: 9.4)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(level(levels, at: 10), 0)
        XCTAssertTrue(levels.allSatisfy { $0.time <= 10 })
    }

    func testGIFFrameDelaysAddUpToTheVideosLength() {
        for rate in [5, 10, 12, 15, 24, 30] {
            let delays = (0..<(rate * 3)).map { VideoEngine.gifDelay(frame: $0, rate: rate) }
            XCTAssertEqual(delays.reduce(0, +), 3, accuracy: 0.001, "\(rate) fps")
            XCTAssertTrue(delays.allSatisfy { $0 >= 0.02 }, "\(rate) fps")
        }
        let twelve = (0..<6).map { Int((VideoEngine.gifDelay(frame: $0, rate: 12) * 100).rounded()) }
        XCTAssertEqual(twelve, [8, 9, 8, 8, 9, 8])
        XCTAssertEqual(VideoEngine.gifDelay(frame: 0, rate: 10), 0.1, accuracy: 1e-9)
    }
}
