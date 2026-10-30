import XCTest
@testable import StillCore

final class CaptureKeyboardPolicyTests: XCTestCase {
    func testEscapeCancelsEvenWhileEditingDimensions() {
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 53, keyUp: false, editingText: true, windowSelectionAllowed: false), .cancel)
    }
    func testSpaceSupportsWindowSelectionForRecordingAndScreenshots() {
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 49, keyUp: false, editingText: false, windowSelectionAllowed: true), .beginWindowSelection)
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 49, keyUp: false, editingText: false, windowSelectionAllowed: false), .passThrough)
    }
    func testSpaceDoesNotStealTextInputOrSystemCommands() {
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 49, keyUp: false, editingText: true, windowSelectionAllowed: true), .passThrough)
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 49, keyUp: false, editingText: false, windowSelectionAllowed: true, hasCommandModifier: true), .passThrough)
    }
    func testSpaceReleaseStillEndsSelectionAfterFocusChanges() {
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 49, keyUp: true, editingText: true, windowSelectionAllowed: false), .endWindowSelection)
        XCTAssertEqual(CaptureKeyboardPolicy.action(keyCode: 36, keyUp: false, editingText: false, windowSelectionAllowed: true), .passThrough)
    }
}
