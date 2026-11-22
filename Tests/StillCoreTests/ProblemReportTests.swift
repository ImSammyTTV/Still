import XCTest
@testable import StillCore

/// Report a Problem: the log's lines and rotation, keeping secrets out of the report, and the issue page's link.
final class ProblemReportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 11, day: 22, hour: 14, minute: 5, second: 9).date!

    func testLogLineIsOneTimestampedLine() {
        XCTAssertEqual(ProblemReport.logLine("Launched", date: date, timeZone: utc), "2026-11-22 14:05:09.000 Launched\n")
        XCTAssertEqual(ProblemReport.logLine("Capture failed\n  The disk is full.\n", date: date, timeZone: utc), "2026-11-22 14:05:09.000 Capture failed | The disk is full.\n")
    }

    func testRotatesOnlyPastTheLimit() {
        XCTAssertFalse(ProblemReport.shouldRotate(currentSize: 0, adding: 5_000_000))
        XCTAssertFalse(ProblemReport.shouldRotate(currentSize: 999_900, adding: 100))
        XCTAssertTrue(ProblemReport.shouldRotate(currentSize: 999_950, adding: 100))
        XCTAssertTrue(ProblemReport.shouldRotate(currentSize: 20, adding: 15, limit: 30))
    }

    func testLastLinesKeepsTheNewest() {
        XCTAssertEqual(ProblemReport.lastLines("a\nb\n\nc\nd\n", count: 3), ["b", "c", "d"])
        XCTAssertEqual(ProblemReport.lastLines("a\nb", count: 10), ["a", "b"])
        XCTAssertEqual(ProblemReport.lastLines("a\nb", count: 0), [])
    }

    func testNamePartsSplitCamelCaseAndSeparators() {
        XCTAssertEqual(ProblemReport.nameParts("serviceAPIKey"), ["service", "api", "key"])
        XCTAssertEqual(ProblemReport.nameParts("service_access-token"), ["service", "access", "token"])
        XCTAssertEqual(ProblemReport.nameParts("keysSize"), ["keys", "size"])
    }

    func testSecretNames() {
        for name in ["apiKey", "serviceAPIKey", "service_api_key", "authToken", "password", "clientSecret", "APIKEY", "connectorCredentials"] {
            XCTAssertTrue(ProblemReport.isSecretName(name), name)
        }
        for name in ["keysSize", "keysStyle", "recordingKeys", "recordingCommandKeysOnly", "autoUpdate", "exportFormat", "showMenuBar"] {
            XCTAssertFalse(ProblemReport.isSecretName(name), name)
        }
    }

    func testSecretLookingValues() {
        XCTAssertTrue(ProblemReport.looksLikeSecretValue("AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUv"))
        XCTAssertTrue(ProblemReport.looksLikeSecretValue("sk-abc123def456ghi789"))
        XCTAssertTrue(ProblemReport.looksLikeSecretValue("3f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"))
        XCTAssertFalse(ProblemReport.looksLikeSecretValue("Screenshot {date} at {time}"))
        XCTAssertFalse(ProblemReport.looksLikeSecretValue("bottomRight"))
        XCTAssertFalse(ProblemReport.looksLikeSecretValue("/Users/someone/Documents/Still/Exports2026"))
    }

    func testSettingLinesLeaveOutSecretsAndTypedText() {
        let lines = ProblemReport.settingLines([
            "exportFormat": "png", "apiKey": "abc", "watermarkText": "My Company", "filenamePattern": "",
            "note": "0123456789abcdefghijklmnopqrstuv"
        ], privateText: ["watermarkText", "filenamePattern"])
        XCTAssertEqual(lines, ["apiKey: (removed)", "exportFormat: png", "filenamePattern: (empty)", "note: (removed)", "watermarkText: (set, left out)"])
        XCTAssertFalse(lines.joined().contains("My Company"))
        XCTAssertFalse(lines.joined().contains("abc"))
    }

    func testHidesTheHomeFolder() {
        XCTAssertEqual(ProblemReport.hidingHome("Saved to /Users/sam/Desktop/a.png", home: "/Users/sam"), "Saved to ~/Desktop/a.png")
        XCTAssertEqual(ProblemReport.hidingHome("Saved to /Users/sam/Desktop", home: "/Users/sam/"), "Saved to ~/Desktop")
        XCTAssertEqual(ProblemReport.hidingHome("/tmp/x", home: "/"), "/tmp/x")
        XCTAssertEqual(ProblemReport.hidingHome("/Users/samantha/a.png", home: "/Users/sam"), "/Users/samantha/a.png")
    }

    func testFileNameHasNoColons() {
        XCTAssertEqual(ProblemReport.fileName(date: date, timeZone: utc), "Still problem report 2026-11-22 at 14.05.09.txt")
    }

    func testReportText() {
        let facts = ProblemReport.Facts(version: "1.3.0", build: "130", macOS: "Version 15.1 (Build 24B83)", model: "Mac15,3",
                                        displays: ["Built-in Display: 1512×982 points at 2x"], screenRecordingAllowed: false,
                                        settings: ["exportFormat: png"], historyCount: 12, logLines: ["2026-11-22 14:00:00.000 Launched"], created: date)
        let text = ProblemReport.text(facts, timeZone: utc)
        XCTAssertTrue(text.hasPrefix("Still problem report\nMade 2026-11-22 14:05:09.000."))
        for part in ["Still 1.3.0 (build 130)", "macOS Version 15.1 (Build 24B83)", "Mac model: Mac15,3", "Screen recording permission: not allowed",
                     "Items in Capture History: 12", "Built-in Display: 1512×982 points at 2x", "exportFormat: png", "last 1 lines", "Launched"] {
            XCTAssertTrue(text.contains(part), part)
        }
    }

    func testPercentEncodingLeavesOnlyUnreservedCharacters() {
        XCTAssertEqual(ProblemReport.percentEncoded("Problem: "), "Problem%3A%20")
        XCTAssertEqual(ProblemReport.percentEncoded("a&b=c+d#e\n"), "a%26b%3Dc%2Bd%23e%0A")
        XCTAssertEqual(ProblemReport.percentEncoded("×"), "%C3%97")
        XCTAssertEqual(ProblemReport.percentEncoded("A-z_0.9~"), "A-z_0.9~")
    }

    func testIssueURL() throws {
        let url = try XCTUnwrap(ProblemReport.issueURL(repository: "owner/app", version: "1.3.0", build: "130", macOS: "Version 15.1 (Build 24B83)"))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("https://github.com/owner/app/issues/new?title=Problem%3A%20&body=%23%23%23%20What%20happened"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["title", "body"])
        XCTAssertEqual(items[0].value, "Problem: ")
        let body = try XCTUnwrap(items[1].value)
        for part in ["### What happened", "### What you expected", "### Steps to make it happen", "### System", "Still 1.3.0 (build 130)", "macOS Version 15.1 (Build 24B83)"] {
            XCTAssertTrue(body.contains(part), part)
        }
        XCTAssertFalse(text.contains(" "))
        XCTAssertFalse(text.contains("\n"))
    }
}
