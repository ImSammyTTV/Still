import XCTest
@testable import StillCore

/// The same cases as links_are_copied_in_the_chosen_format in cloud.rs.
final class ShareLinkTests: XCTestCase {
    func testLinksAreCopiedInTheChosenFormat() {
        let url = "https://cloud.example/v/abc"
        XCTAssertEqual(ShareLink.text(url, title: "Bug [login]", image: true, format: "url"), url)
        XCTAssertEqual(ShareLink.text(url, title: "Bug [login]", image: true, format: "markdown"), "![Bug login](https://cloud.example/v/abc)")
        XCTAssertEqual(ShareLink.text("https://x.example/a(1)", title: "Demo", image: false, format: "markdown"), "[Demo](https://x.example/a%281%29)")
        XCTAssertEqual(ShareLink.text(url, title: "Tom & \"Jerry\" <3", image: true, format: "html"), "<img src=\"https://cloud.example/v/abc\" alt=\"Tom &amp; &quot;Jerry&quot; &lt;3\">")
        XCTAssertEqual(ShareLink.text(url, title: "Demo", image: false, format: "html"), "<a href=\"https://cloud.example/v/abc\">Demo</a>")
    }
}
