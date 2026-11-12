import XCTest
@testable import StillCore

// The same cases are in Desktop/src-tauri/src/mcp.rs.
final class StillConnectorTests: XCTestCase {
    func testItIntroducesItselfAndListsItsTools() {
        let never: (String, [String: Any]) -> [String: Any] = { _, _ in XCTFail("no tool call expected"); return [:] }
        let hello = StillConnector.answer(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]], version: "1", call: never)!
        XCTAssertEqual((hello["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        let newer = StillConnector.answer(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]], version: "1", call: never)!
        XCTAssertEqual((newer["result"] as? [String: Any])?["protocolVersion"] as? String, StillConnector.versions[0])
        XCTAssertNil(StillConnector.answer(["jsonrpc": "2.0", "method": "notifications/initialized"], version: "1", call: never))
        let list = StillConnector.answer(["jsonrpc": "2.0", "id": 3, "method": "tools/list"], version: "1", call: never)!
        let names = (((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["still_capture_screen", "still_list_captures", "still_get_capture", "still_describe_capture", "still_open_capture"])
        let unknown = StillConnector.answer(["jsonrpc": "2.0", "id": 4, "method": "resources/list"], version: "1", call: never)!
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }
    func testToolCallsGoToTheAppWithTheirArguments() {
        var seen: [(String, String?)] = []
        let r = StillConnector.answer(["jsonrpc": "2.0", "id": "a", "method": "tools/call", "params": ["name": "still_get_capture", "arguments": ["id": "x1"]]], version: "1") { name, args in
            seen.append((name, args["id"] as? String)); return StillConnector.textResult("ok")
        }!
        XCTAssertEqual(r["id"] as? String, "a")
        XCTAssertEqual(seen.first?.0, "still_get_capture"); XCTAssertEqual(seen.first?.1, "x1")
        XCTAssertTrue(StillConnector.sameSecret("abc", "abc")); XCTAssertFalse(StillConnector.sameSecret("abc", "abd")); XCTAssertFalse(StillConnector.sameSecret("abc", "ab"))
    }
}
