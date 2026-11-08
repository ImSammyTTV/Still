import XCTest
@testable import StillCore

final class ClaudeExtensionTests: XCTestCase {
    func testManifestRunsThisStillWithMCPAndListsEveryTool() throws {
        let m = ClaudeExtension.manifest(version: "1.2.48", executable: "/Applications/Still.app/Contents/MacOS/Still")
        XCTAssertEqual(m["manifest_version"] as? String, "0.3")
        let server = try XCTUnwrap(m["server"] as? [String: Any]), config = try XCTUnwrap(server["mcp_config"] as? [String: Any])
        XCTAssertEqual(config["command"] as? String, "/Applications/Still.app/Contents/MacOS/Still")
        XCTAssertEqual(config["args"] as? [String], ["--mcp"])
        XCTAssertEqual(server["entry_point"] as? String, "server/still-mcp")
        XCTAssertEqual((m["tools"] as? [[String: Any]])?.count, StillConnector.tools.count)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(m))
    }
    func testWritesManifestIconAndRunnableLauncher() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("still-mcpb-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ClaudeExtension.write(into: folder, version: "1.2.48", executable: "/Applications/Still.app/Contents/MacOS/Still", iconPNG: Data([0x89, 0x50, 0x4E, 0x47]))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["name"] as? String, "still")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("icon.png").path))
        let script = folder.appendingPathComponent("server/still-mcp").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script))
        XCTAssertTrue(try String(contentsOfFile: script, encoding: .utf8).contains("exec \"/Applications/Still.app/Contents/MacOS/Still\" --mcp"))
    }
}
