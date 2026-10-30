import XCTest
import AppKit
import AVFoundation
import ImageIO
@testable import StillCore

final class PreviewAndEncodingTests: XCTestCase {
    private func image(width: Int = 400, height: Int = 240, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue, transparent: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)!
        if !transparent { context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        for index in 0..<40 {
            context.setFillColor(NSColor(hue: Double(index)/40, saturation: 0.8, brightness: 0.8, alpha: transparent ? 0.45 : 1).cgColor)
            context.fill(CGRect(x: index*9, y: index*5, width: 70, height: 30))
        }
        return context.makeImage()!
    }
    private func encodedThenDecodedThenEncoded(_ source: CGImage) throws -> Data {
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(try ImageRenderer.data(source) as CFData, nil)!, 0, nil)!
        return try ImageRenderer.data(decoded)
    }
    /// The library's files must not change: one encode has to produce the bytes the old two-pass save produced.
    func testLibraryDataMatchesTheOldTwoPassEncodeByteForByte() throws {
        let little = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        var spaces = [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!, CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)!]
        if let display = CGDisplayCopyColorSpace(CGMainDisplayID()) as CGColorSpace?, display.model == .rgb { spaces.append(display) }
        for space in spaces {
            for info in [CGImageAlphaInfo.premultipliedLast.rawValue, little] {
                for transparent in [false, true] {
                    let source = image(space: space, bitmapInfo: info, transparent: transparent)
                    XCTAssertEqual(try ImageRenderer.libraryData(source), try encodedThenDecodedThenEncoded(source), "\(String(describing: space.name)) \(info) \(transparent)")
                }
            }
        }
    }
    func testPreviewCacheDrawsTheSamePixelsAsNoCache() throws {
        let source = image(width: 900, height: 600)
        var blur = Mark(tool: .blur, points: [.init(x: 40, y: 40), .init(x: 300, y: 260)], width: 8); blur.style = "smooth"
        let pixelate = Mark(tool: .pixelate, points: [.init(x: 320, y: 60), .init(x: 620, y: 300)], width: 6)
        var picture = Mark(tool: .image, points: [.init(x: 500, y: 320), .init(x: 800, y: 500)]); picture.imageData = try ImageRenderer.data(image(width: 120, height: 80))
        let arrow = Mark(tool: .arrow, points: [.init(x: 30, y: 500), .init(x: 700, y: 120)], width: 7)
        let marks = [blur, pixelate, picture, arrow], cache = PreviewCache()
        let expected = try ImageRenderer.preview(source, marks: marks)
        for _ in 0..<3 { XCTAssertEqual(pixels(try ImageRenderer.preview(source, marks: marks, cache: cache)), pixels(expected)) }
        // A moved mark, a changed picture and a new source must not reuse stale pieces.
        let moved = [blur.moved(dx: 30, dy: 10), pixelate, picture, arrow]
        XCTAssertEqual(pixels(try ImageRenderer.preview(source, marks: moved, cache: cache)), pixels(try ImageRenderer.preview(source, marks: moved)))
        var swapped = picture; swapped.imageData = try ImageRenderer.data(image(width: 60, height: 200))
        XCTAssertEqual(pixels(try ImageRenderer.preview(source, marks: [swapped], cache: cache)), pixels(try ImageRenderer.preview(source, marks: [swapped])))
        let other = image(width: 900, height: 600, transparent: true)
        XCTAssertEqual(pixels(try ImageRenderer.preview(other, marks: marks, cache: cache)), pixels(try ImageRenderer.preview(other, marks: marks)))
    }
    func testScaledRenderLooksLikeTheFullRenderAndExportsStayFullSize() throws {
        let source = image(width: 1600, height: 900)
        let background = try ImageRenderer.data(image(width: 640, height: 480), jpeg: true)
        let marks = [Mark(tool: .rectangle, points: [.init(x: 100, y: 100), .init(x: 900, y: 500)], width: 12)]
        for wallpaper in [nil, background] {
            let full = try ImageRenderer.render(source, marks: marks, frame: .ocean, padding: 120, cornerRadius: 40, shadow: 48, customBackground: wallpaper)
            XCTAssertEqual(full.width, 1840); XCTAssertEqual(full.height, 1140)
            let preview = try ImageRenderer.render(source, marks: marks, frame: .ocean, padding: 120, cornerRadius: 40, shadow: 48, customBackground: wallpaper, maxDimension: 460, cache: PreviewCache())
            XCTAssertEqual(preview.width, 460); XCTAssertEqual(preview.height, 285)
            let reduced = try ImageRenderer.resize(full, width: 460, height: 285), a = pixels(preview), b = pixels(reduced)
            let difference = zip(a, b).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) }
            XCTAssertLessThan(Double(difference)/Double(a.count), 6, "Scaled preview should match the shrunken export")
        }
        XCTAssertEqual(pixels(try ImageRenderer.render(source, marks: marks, maxDimension: 4000)), pixels(try ImageRenderer.render(source, marks: marks)))
    }
    func testMemoryThumbnailMatchesFileThumbnail() throws {
        let source = image(width: 1400, height: 700)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-thumb-\(UUID()).png")
        try ImageRenderer.data(source).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let memory = try XCTUnwrap(ImageRenderer.thumbnail(source, maxPixelSize: 560)), file = try XCTUnwrap(ImageRenderer.thumbnail(url, maxPixelSize: 560))
        XCTAssertEqual(memory.width, file.width); XCTAssertEqual(memory.height, file.height)
        XCTAssertEqual(memory.width, 560); XCTAssertEqual(memory.height, 280)
        let a = pixels(memory), b = pixels(file)
        XCTAssertLessThan(Double(zip(a, b).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) })/Double(a.count), 6)
    }
    func testBitratePresetTagsAndDefaults() {
        let preset = BitratePreset(name: "Tutorials", megabits: 12.5)
        XCTAssertEqual(preset.bitrate, 12_500_000); XCTAssertEqual(preset.tag, "bitrate:12500000")
        XCTAssertEqual(preset.title, "Tutorials (12.5 Mbps)"); XCTAssertEqual(BitratePreset.label(8_000_000), "8 Mbps")
        XCTAssertEqual(BitratePreset.bitrate(tag: preset.tag), 12_500_000)
        for name in VideoQuality.allCases.map(\.rawValue)+["", "bitrate:", "bitrate:abc", "bitrate:-4"] { XCTAssertNil(BitratePreset.bitrate(tag: name), name) }
        XCTAssertNil(BitratePreset.bitrate(tag: nil))
        XCTAssertEqual(BitratePreset.bitrate(tag: "bitrate:900000000000"), 100_000_000, "Hand-edited values stay within the encoder's range")
        XCTAssertEqual(BitratePreset.bitrate(tag: "bitrate:5"), 1_000_000)
        XCTAssertEqual(BitratePreset(name: "Huge", megabits: 500).bitrate, 100_000_000)
        // Built-in qualities keep their numbers.
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(VideoQuality.high.bitrate(size: size, fps: 30), 11_197_440)
        XCTAssertEqual(VideoQuality.balanced.bitrate(size: size, fps: 30), 5_598_720)
        XCTAssertEqual(VideoQuality.compact.bitrate(size: size, fps: 30), 2_799_360)
    }
    func testSettingsWithoutAPresetKeepTheirQuality() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-bitrate-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mp4")
        try await noisyMovie(input)
        var settings = VideoSettings(); settings.fps = 30
        for (quality, expected) in [(nil, VideoQuality.high), ("balanced", .balanced), ("original", .original), ("unknown", .high)] as [(String?, VideoQuality)] {
            settings.quality = quality
            let prepared = try await VideoEngine.prepare(url: input, settings: settings)
            XCTAssertEqual(prepared.quality, expected); XCTAssertNil(prepared.bitrate)
        }
        settings.quality = BitratePreset(name: "x", megabits: 2).tag
        let prepared = try await VideoEngine.prepare(url: input, settings: settings)
        XCTAssertEqual(prepared.bitrate, 2_000_000)
    }
    /// Noise can't be compressed well, so the output rate follows the bitrate the encoder was given. Short clips overshoot
    /// low targets while rate control settles, so this compares two presets rather than expecting an exact rate.
    func testCustomBitrateReachesTheEncoder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-bitrate-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mp4")
        try await noisyMovie(input)
        var rates: [Double] = []
        for megabits in [1.0, 8.0] {
            var settings = VideoSettings(); settings.fps = 30; settings.quality = BitratePreset(name: "x", megabits: megabits).tag
            let output = folder.appendingPathComponent("\(megabits).mp4")
            try await VideoEngine.export(try await VideoEngine.prepare(url: input, settings: settings), to: output)
            let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first!
            let size = try await track.load(.naturalSize), rate = try await track.load(.estimatedDataRate)
            XCTAssertEqual(size, CGSize(width: 640, height: 360))
            rates.append(Double(rate))
        }
        print("measured data rates for 1 and 8 Mbps presets:", rates)
        XCTAssertGreaterThan(rates[1], rates[0]*1.5, "A higher preset should spend more bits on the same clip")
    }
    private func noisyMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for index in 0..<45 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var optional: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &optional), kCVReturnSuccess)
            let buffer = optional!
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<360 { for x in 0..<640 {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let offset = y*row+x*4; base[offset] = UInt8(state&255); base[offset+1] = UInt8((state>>8)&255); base[offset+2] = UInt8((state>>16)&255); base[offset+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width*image.height*4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
