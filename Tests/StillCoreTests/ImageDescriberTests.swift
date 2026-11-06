import XCTest
@testable import StillCore

// The same cases are in Desktop/src-tauri/src/describe.rs.
final class ImageDescriberTests: XCTestCase {
    func testTheTextComesFromEveryPartAndErrorsArePlain() {
        let ok: [String: Any] = ["candidates": [["content": ["parts": [["text": "A settings page "], ["text": "with a dark sidebar.\n"]]]]]]
        XCTAssertEqual(try ImageDescriber.text(of: ok).get(), "A settings page with a dark sidebar.")
        let limit: [String: Any] = ["error": ["code": 429, "message": "Resource exhausted"]]
        XCTAssertThrowsError(try ImageDescriber.text(of: limit).get()) { XCTAssertTrue($0.localizedDescription.contains("free limit")) }
        let blocked: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"]]
        XCTAssertThrowsError(try ImageDescriber.text(of: blocked).get()) { XCTAssertTrue($0.localizedDescription.contains("SAFETY")) }
        XCTAssertTrue(ImageDescriber.explain(400, "API key not valid. Please pass a valid API key.").contains("isn’t valid"))
    }
    func testAFlashModelThatCanWriteIsPicked() {
        let list: [String: Any] = ["models": [
            ["name": "models/gemini-9-pro", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-9-flash-image", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-9-flash", "supportedGenerationMethods": ["generateContent", "countTokens"]],
            ["name": "models/gemini-8-flash", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/embedding-flash", "supportedGenerationMethods": ["embedContent"]]]]
        XCTAssertEqual(ImageDescriber.pickModel(list), "gemini-9-flash")
        XCTAssertNil(ImageDescriber.pickModel([:]))
    }
    func testTheRequestCarriesThePictureAndThePrompt() {
        let b = ImageDescriber.body(mime: "image/png", data: Data([0, 0, 0]))
        let parts = ((b["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
        XCTAssertEqual(parts.first?["text"] as? String, ImageDescriber.prompt)
        XCTAssertEqual((parts.last?["inline_data"] as? [String: Any])?["mime_type"] as? String, "image/png")
    }
}
