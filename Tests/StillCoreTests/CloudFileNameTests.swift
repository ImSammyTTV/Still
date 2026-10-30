import XCTest
@testable import StillCore

final class CloudFileNameTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/Still")
    func testKeepsTitleAndSkipsExistingFiles() {
        let taken = ["/tmp/Still/Bug report.png", "/tmp/Still/Bug report (2).png"]
        let url = CloudFileName.destination(in: folder, title: "Bug report", fileExtension: "png") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "Bug report (3).png")
    }
    func testTitleCantEscapeTheFolder() {
        let url = CloudFileName.destination(in: folder, title: "../secret/name", fileExtension: "png") { _ in false }
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/Still")
        XCTAssertEqual(CloudFileName.destination(in: folder, title: "..", fileExtension: "mp4") { _ in false }.lastPathComponent, "Capture.mp4")
    }
}
