import XCTest
import AppKit
import ImageIO
@testable import StillCore

final class ImageRendererTests: XCTestCase {
    func testAspectAlignmentMatchesExportAndPreview() throws {
        let source = fixture()
        let layout = ImageRenderer.canvasLayout(source: CGSize(width: 100, height: 80), framed: true, padding: 10, aspect: 1, alignmentX: 0.5, alignmentY: 0)
        XCTAssertEqual(layout.size, CGSize(width: 120, height: 120))
        XCTAssertEqual(layout.origin, CGPoint(x: 10, y: 10))
        let bottom = ImageRenderer.canvasLayout(source: CGSize(width: 100, height: 80), framed: true, padding: 10, aspect: 1, alignmentX: 0.5, alignmentY: 1)
        XCTAssertEqual(bottom.origin, CGPoint(x: 10, y: 30))
        let image = try ImageRenderer.render(source, frame: .ocean, padding: 10, cornerRadius: 0, shadow: 0, aspectRatio: 1, alignmentY: 1)
        XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 120)
        XCTAssertEqual(pixel(image, x: 50, y: 32), [255, 0, 0, 255])
    }
    func testOldRecordingMetadataStillDecodes() throws {
        let data = Data(#"{"pointer":[{"time":1,"x":0.2,"y":0.3}],"cameraOffset":0.4}"#.utf8)
        let metadata = try JSONDecoder().decode(RecordingMetadata.self, from: data)
        XCTAssertEqual(metadata.pointer.count, 1)
        XCTAssertTrue(metadata.defaultShowCursor); XCTAssertFalse(metadata.defaultShowClicks)
        XCTAssertEqual(metadata.cameraOffset, 0.4)
    }
    func testCurvedArrowControlChangesRenderedPathAndSurvivesMovement() throws {
        var upper = Mark(tool: .arrow, points: [.init(x: 10, y: 40), .init(x: 90, y: 40)], width: 4)
        upper.style = "curved"; upper.control = .init(x: 50, y: 0)
        var lower = upper; lower.control = .init(x: 50, y: 80)
        let top = try ImageRenderer.render(fixture(), marks: [upper])
        let bottom = try ImageRenderer.render(fixture(), marks: [lower])
        XCTAssertLessThan(pixel(top, x: 50, y: 20)[1], 160)
        XCTAssertGreaterThan(pixel(bottom, x: 50, y: 20)[1], 230)
        let moved = upper.moved(dx: 5, dy: 10)
        let restored = try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(restored.control?.x, 55); XCTAssertEqual(restored.control?.y, 10)
    }
    func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 60, width: 100, height: 20))
        return context.makeImage()!
    }
    func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width*image.height*4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y*image.width+x)*4
        return Array(data[index..<index+4])
    }
    func testRenderPreservesOrientationAndPixelDimensions() throws {
        let image = try ImageRenderer.render(fixture())
        XCTAssertEqual(image.width, 100); XCTAssertEqual(image.height, 80)
        XCTAssertEqual(pixel(image, x: 50, y: 5), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, x: 50, y: 70), [255, 255, 255, 255])
    }
    func testRedactionPermanentlyReplacesTopLeftPixelsWithOpaqueFill() throws {
        let mark = Mark(tool: .redact, points: [.init(x: 10, y: 2), .init(x: 60, y: 18)])
        let image = try ImageRenderer.render(fixture(), marks: [mark])
        XCTAssertEqual(pixel(image, x: 20, y: 10), [32, 36, 33, 255])
        XCTAssertEqual(pixel(image, x: 80, y: 10), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, x: 20, y: 70), [255, 255, 255, 255])
        let encoded = try ImageRenderer.data(image)
        let source = CGImageSourceCreateWithData(encoded as CFData, nil)!
        XCTAssertEqual(pixel(CGImageSourceCreateImageAtIndex(source, 0, nil)!, x: 20, y: 10), [32, 36, 33, 255])
    }
    func testLoupeEnlargesWhatIsAtItsCentre() throws {
        // The red band ends 20 rows down. A lens centred at row 26 doubles distances from its centre, so the edge
        // shows at row 14 and row 17, red in the picture, shows white through the lens.
        let mark = Mark(tool: .loupe, points: [.init(x: 30, y: 6), .init(x: 70, y: 46)])
        let image = try ImageRenderer.render(fixture(), marks: [mark])
        XCTAssertEqual(pixel(image, x: 50, y: 17), [255, 255, 255, 255])
        XCTAssertEqual(pixel(image, x: 50, y: 11), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, x: 5, y: 17), [255, 0, 0, 255]) // Outside the lens, nothing changes.
    }
    func testCropUsesTopLeftCoordinatesAndClipsToImageBounds() throws {
        let cropped = try ImageRenderer.crop(fixture(), to: CGRect(x: -5, y: 0, width: 35, height: 15))
        XCTAssertEqual(cropped.width, 30); XCTAssertEqual(cropped.height, 15)
        XCTAssertEqual(pixel(cropped, x: 2, y: 2), [255, 0, 0, 255])
        XCTAssertThrowsError(try ImageRenderer.crop(fixture(), to: CGRect(x: 150, y: 150, width: 10, height: 10)))
    }
    func testBackgroundAddsPaddingAndPNGAndJPEGEncode() throws {
        let image = try ImageRenderer.render(fixture(), frame: .sage, padding: 24)
        XCTAssertEqual(image.width, 148); XCTAssertEqual(image.height, 128)
        let png = try ImageRenderer.data(image), jpeg = try ImageRenderer.data(image, jpeg: true)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(Array(jpeg.prefix(2)), [255, 216])
    }
    func testMarksNormalizeReverseDragAndRoundTrip() throws {
        let mark = Mark(tool: .rectangle, points: [.init(x: 70, y: 60), .init(x: 10, y: 20)])
        XCTAssertEqual(mark.rect, CGRect(x: 10, y: 20, width: 60, height: 40))
        XCTAssertEqual(try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(mark)), mark)
    }
    func testAllDrawingToolsRenderWithoutChangingImageSize() throws {
        _ = NSApplication.shared
        let marks = MarkTool.allCases.map { Mark(tool: $0, points: [.init(x: 20, y: 25), .init(x: 75, y: 65)], width: 3, text: $0 == .number ? "1" : "Note") }
        let image = try ImageRenderer.render(fixture(), marks: marks)
        XCTAssertEqual(image.width, 100); XCTAssertEqual(image.height, 80)
    }
    func testEditableProjectPreservesSourceAndAnnotations() throws {
        let mark = Mark(tool: .redact, points: [.init(x: 2, y: 2), .init(x: 60, y: 15)])
        let document = try ProjectDocument(source: fixture(), marks: [mark], frame: .ocean, padding: 48, cornerRadius: 20, shadow: 30, aspectRatio: 1)
        let data = try JSONEncoder().encode(document), restored = try JSONDecoder().decode(ProjectDocument.self, from: data)
        XCTAssertEqual(restored.marks, [mark]); XCTAssertEqual(restored.frame, "ocean"); XCTAssertEqual(restored.sourceImage()?.width, 100)
        XCTAssertEqual(pixel(restored.sourceImage()!, x: 20, y: 10), [255, 0, 0, 255])
        let rendered = try ImageRenderer.render(restored.sourceImage()!, marks: restored.marks)
        XCTAssertEqual(pixel(rendered, x: 20, y: 10), [32, 36, 33, 255])
    }
    func testResizeRotateAndAspectRatio() throws {
        let resized = try ImageRenderer.resize(fixture(), width: 200, height: 160)
        XCTAssertEqual(resized.width, 200); XCTAssertEqual(resized.height, 160)
        let rotated = try ImageRenderer.orient(fixture(), orientation: 6)
        XCTAssertEqual(rotated.width, 80); XCTAssertEqual(rotated.height, 100)
        let square = try ImageRenderer.render(fixture(), frame: .sky, padding: 20, aspectRatio: 1)
        XCTAssertEqual(square.width, square.height)
    }
}
