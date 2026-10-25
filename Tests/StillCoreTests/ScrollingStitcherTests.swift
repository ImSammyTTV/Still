import XCTest
import AppKit
@testable import StillCore

final class ScrollingStitcherTests: XCTestCase {
    func testOverlappingFramesStitchToOriginalDimensionsAndIgnoreDuplicates() throws {
        let ctx = CGContext(data: nil, width: 160, height: 720, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<720 {
            for x in stride(from: 0, to: 160, by: 8) {
                let level: Int = (y * 17 + x * 13 + y * y * 3) % 251; let v = CGFloat(level) / 255
                ctx.setFillColor(NSColor(white: v, alpha: 1).cgColor); ctx.fill(CGRect(x: x, y: y, width: 8, height: 1))
            }
        }
        let full = ctx.makeImage()!
        let a = try ImageRenderer.crop(full, to: CGRect(x: 0, y: 0, width: 160, height: 280))
        let b = try ImageRenderer.crop(full, to: CGRect(x: 0, y: 120, width: 160, height: 280))
        let c = try ImageRenderer.crop(full, to: CGRect(x: 0, y: 240, width: 160, height: 280))
        let stitcher = try ScrollingStitcher(a)
        XCTAssertFalse(try stitcher.append(a))
        XCTAssertTrue(try stitcher.append(b)); XCTAssertTrue(try stitcher.append(c))
        let result = try stitcher.result()
        XCTAssertEqual(result.width, 160); XCTAssertEqual(result.height, 520, accuracy: 2)
        XCTAssertEqual(stitcher.frameCount, 3)
    }
    func testReverseScrollingPrependsAndRevisitingDoesNotDuplicate() throws {
        let ctx = CGContext(data: nil, width: 160, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<900 {
            for x in stride(from: 0, to: 160, by: 8) {
                let level: Int = (y * 17 + x * 13 + y * y * 3) % 251
                let white = CGFloat(level) / 255
                ctx.setFillColor(NSColor(white: white, alpha: 1).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 1))
            }
        }
        let full = ctx.makeImage()!
        func frame(_ y: Int) throws -> CGImage { try ImageRenderer.crop(full,to: CGRect(x: 0,y: y,width: 160,height: 280)) }
        let stitcher = try ScrollingStitcher(frame(120))
        XCTAssertTrue(try stitcher.append(frame(240)))
        XCTAssertFalse(try stitcher.append(frame(120)))
        XCTAssertTrue(try stitcher.append(frame(0)))
        XCTAssertEqual(try stitcher.result().height,520,accuracy: 2)
        XCTAssertFalse(try stitcher.append(frame(120)))
        XCTAssertFalse(try stitcher.append(frame(240)))
        XCTAssertTrue(try stitcher.append(frame(360)))
        XCTAssertEqual(try stitcher.result().height,640,accuracy: 2)
    }
    func testHorizontalFramesAndChangedSizes() throws {
        let ctx = CGContext(data: nil, width: 600, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<600 { let level: Int = (x * 37 + x * x * 7) % 251; ctx.setFillColor(NSColor(white: CGFloat(level) / 255, alpha: 1).cgColor); ctx.fill(CGRect(x: x, y: 0, width: 1, height: 120)) }
        let full = ctx.makeImage()!
        let a = try ImageRenderer.crop(full, to: CGRect(x: 0, y: 0, width: 280, height: 120)), b = try ImageRenderer.crop(full, to: CGRect(x: 100, y: 0, width: 280, height: 120))
        let stitcher = try ScrollingStitcher(a, axis: .horizontal)
        XCTAssertTrue(try stitcher.append(b)); XCTAssertEqual(try stitcher.result().width, 380, accuracy: 2)
        XCTAssertThrowsError(try stitcher.append(full))
    }
}
