import XCTest
@testable import StillCore

/// The same cases as the Windows and Linux app's tests, so a pattern names files the same everywhere.
final class CaptureNamingTests: XCTestCase {
    private let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 31, hour: 9, minute: 5, second: 7).date!
    private let calendar = Calendar(identifier: .gregorian)

    func testFollowsThePattern() {
        XCTAssertEqual(CaptureNaming.name(pattern: CaptureNaming.defaultPattern, date: date, width: 800, height: 600, calendar: calendar), "Screenshot 2026-10-31 at 09.05.07")
        XCTAssertEqual(CaptureNaming.name(pattern: "{type} #{n} {width}x{height}", isVideo: true, date: date, number: 12, calendar: calendar), "Recording #12 x")
        XCTAssertEqual(CaptureNaming.name(pattern: "Bug: {date}/{time}?", date: date, calendar: calendar), "Bug- 2026-10-31-09.05.07-")
    }

    func testFallsBackAndStaysShort() {
        XCTAssertEqual(CaptureNaming.name(pattern: " ... ", date: date, calendar: calendar), "Screenshot 2026-10-31 at 09.05.07")
        XCTAssertEqual(CaptureNaming.name(pattern: String(repeating: "x", count: 300), date: date, calendar: calendar).count, 180)
    }
}
