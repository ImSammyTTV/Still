import XCTest
import AppKit
@testable import StillCore

final class TextRecognitionTests: XCTestCase {
    func testRecognizesScreenshotTextLocally() throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 700, height: 160))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 700, height: 160).fill()
        ("Capture a clear idea" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let text = try TextRecognition.recognize(cg)
        XCTAssertTrue(text.contains("Capture a clear idea"), "Recognized: \(text)")
        let bounds = try TextRecognition.lineBounds(cg)
        XCTAssertEqual(bounds.count, 1)
        let line = try XCTUnwrap(bounds.first)
        XCTAssertGreaterThan(line.width/Double(cg.width), 0.4)
        XCTAssertGreaterThan(line.minY, 0); XCTAssertLessThan(line.maxY, Double(cg.height))
    }
}
