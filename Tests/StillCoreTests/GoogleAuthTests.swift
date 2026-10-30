import XCTest
@testable import StillCore

final class GoogleAuthTests: XCTestCase {
    func testChallengeMatchesThePKCESpec() {
        XCTAssertEqual(GoogleAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testCallbackNeedsTheRightState() throws {
        XCTAssertEqual(try GoogleAuth.code(requestLine: "GET /?state=abc&code=4%2F0A HTTP/1.1", state: "abc"), "4/0A")
        XCTAssertNil(try GoogleAuth.code(requestLine: "GET /favicon.ico HTTP/1.1", state: "abc"))
        XCTAssertThrowsError(try GoogleAuth.code(requestLine: "GET /?state=other&code=x HTTP/1.1", state: "abc"))
        XCTAssertThrowsError(try GoogleAuth.code(requestLine: "GET /?state=abc&error=access_denied HTTP/1.1", state: "abc"))
    }
}
