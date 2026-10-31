import XCTest
@testable import StillCore

/// The same cases as Desktop/test/private.test.js.
final class PrivateInfoTests: XCTestCase {
    private func kinds(_ text: String) -> [[String]] {
        PrivateInfo.find(text).map { [$0.kind, (text as NSString).substring(with: $0.range)] }
    }

    func testFindsEachKindOfPrivateDetail() {
        XCTAssertEqual(kinds("Write to jane.doe+work@mail.example.com today"), [["email", "jane.doe+work@mail.example.com"]])
        XCTAssertEqual(kinds("Card 4242 4242 4242 4242 exp 12/29"), [["card", "4242 4242 4242 4242"]])
        XCTAssertEqual(kinds("Server 192.168.1.20 is up"), [["ip", "192.168.1.20"]])
        XCTAssertEqual(kinds("Call +1 415-555-0132 or (020) 7946 0958"), [["phone", "+1 415-555-0132"], ["phone", "(020) 7946 0958"]])
        XCTAssertEqual(kinds("STRIPE_KEY=sk_live_51HxQabcDEF123"), [["key", "sk_live_51HxQabcDEF123"]])
        XCTAssertEqual(kinds("token ghp_A1b2C3d4E5f6G7h8I9j0K1l2"), [["key", "ghp_A1b2C3d4E5f6G7h8I9j0K1l2"]])
        XCTAssertEqual(kinds("secret: Zx81kQp02LmNv7RtYb44WcHs"), [["key", "Zx81kQp02LmNv7RtYb44WcHs"]])
    }

    func testLeavesOrdinaryTextAlone() {
        XCTAssertEqual(kinds("Meeting on 2026-10-31 at 13:45, room 4, version 1.2.20"), [])
        XCTAssertEqual(kinds("Order 4242 4242 4242 4241 shipped"), [])
        XCTAssertEqual(kinds("internationalisationcharacteristics"), [])
        XCTAssertEqual(kinds("Version 999.1.1.1"), [])
    }

    func testCardChecksum() {
        XCTAssertTrue(PrivateInfo.luhn("4242424242424242"))
        XCTAssertFalse(PrivateInfo.luhn("4242424242424241"))
    }
}
