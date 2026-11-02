import XCTest
import AVFoundation
import AppKit
import ImageIO
@testable import StillCore

final class VideoEngineTests: XCTestCase {
    func fixture(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<24 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var optional: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &optional), kCVReturnSuccess)
            let buffer = optional!
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: index*5, y: 35, width: 70, height: 110))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 12)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
    /// A camera clip: 2 seconds of solid green, as the camera recorder would leave it.
    func cameraFixture(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<24 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var optional: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &optional), kCVReturnSuccess)
            let buffer = optional!
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.setFillColor(NSColor(red: 0, green: 0.8, blue: 0, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 12)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
    /// The camera goes through the same steps as a real recording: trimmed to line up with the screen, then laid over
    /// the bottom right of the export.
    func testCameraAppearsInTheExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-camera-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mp4"), raw = folder.appendingPathComponent("camera.mp4"), camera = folder.appendingPathComponent("aligned.mp4"), output = folder.appendingPathComponent("output.mp4")
        try await fixture(input); try await cameraFixture(raw)
        try await VideoEngine.trim(raw, start: 0.1, duration: 1.8, to: camera)
        var settings = VideoSettings(); settings.fps = 12; settings.cameraSize = 0.3; settings.cameraMirror = false
        var metadata = RecordingMetadata(); metadata.cursorIncludedInVideo = false; metadata.cameraFilename = "aligned.mp4"
        let prepared = try await VideoEngine.prepare(url: input, settings: settings, metadata: metadata, cameraURL: camera)
        try await VideoEngine.export(prepared, to: output)
        let video = AVURLAsset(url: output)
        let image = try await AVAssetImageGenerator(asset: video).image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The bubble's middle: 30% of the width, 3% in from the right and bottom edges. Rows run from the top.
        let side = Double(w)*0.3, cx = Int(Double(w)*0.97 - side/2), cy = Int(Double(h)*0.97 - side/2)
        let at = (cy*w+cx)*4
        XCTAssertGreaterThan(Int(pixels[at+1]), Int(pixels[at])+60, "The camera (green) should be in the bottom right, got rgb(\(pixels[at]), \(pixels[at+1]), \(pixels[at+2]))")
        let away = (20*w+20)*4
        XCTAssertGreaterThan(pixels[away], 200, "Away from the bubble the screen recording shows through")
    }
    func testTrimBackgroundZoomCursorAndMP4GIFExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-video-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mp4"), output = folder.appendingPathComponent("output.mp4"), gif = folder.appendingPathComponent("output.gif")
        try await fixture(input)
        var settings = VideoSettings(); settings.start = 0.25; settings.end = 1.5; settings.frame = "ocean"; settings.padding = 20; settings.aspect = 1; settings.fps = 12
        settings.zooms = [ZoomSegment(start: 0.3, end: 1.4, scale: 1.5, x: 0.5, y: 0.5)]
        var metadata = RecordingMetadata(); metadata.cursorIncludedInVideo = false
        metadata.pointer = [PointerSample(time: 0, x: 0.2, y: 0.3), PointerSample(time: 2, x: 0.7, y: 0.6)]
        metadata.clicks = [ClickSample(time: 0.5, x: 0.4, y: 0.5)]; metadata.keys = [KeySample(time: 0.6, text: "⌘K")]
        let prepared = try await VideoEngine.prepare(url: input, settings: settings, metadata: metadata)
        XCTAssertEqual(prepared.duration, 1.25, accuracy: 0.01); XCTAssertEqual(prepared.size.width, prepared.size.height)
        try await VideoEngine.export(prepared, to: output)
        let video = AVURLAsset(url: output)
        let duration = try await video.load(.duration).seconds
        XCTAssertEqual(duration, 1.25, accuracy: 0.1)
        let generator = AVAssetImageGenerator(asset: video), image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        XCTAssertEqual(image.image.width, 360); XCTAssertEqual(image.image.height, 360)
        var pixels = [UInt8](repeating: 0, count: 360*360*4)
        let context = CGContext(data: &pixels, width: 360, height: 360, bitsPerComponent: 8, bytesPerRow: 360*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.image, in: CGRect(x: 0, y: 0, width: 360, height: 360))
        let center = (180*360+180)*4, corner = (5*360+5)*4
        XCTAssertGreaterThan(pixels[center], 225); XCTAssertGreaterThan(pixels[center+1], 225); XCTAssertGreaterThan(pixels[center+2], 225)
        XCTAssertGreaterThan(pixels[corner+2], pixels[corner], "Ocean background should contain blue pixels, not a blank video")
        XCTAssertGreaterThan(pixels[corner+3], 245)
        try await VideoEngine.gif(prepared, to: gif, fps: 4, width: 200)
        let source = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        XCTAssertEqual(CGImageSourceGetCount(source), 5)
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 200)
    }
    func testQualityEncoderPreservesAudioAndMute() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-audio-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("movie.mp4"), sound = folder.appendingPathComponent("tone.wav"), combined = folder.appendingPathComponent("input.mp4")
        try await fixture(movie)
        var wave = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        wave.append(Data("RIFF".utf8)); appendLE(UInt32(36+96000*2)); wave.append(Data("WAVEfmt ".utf8)); appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(48000)); appendLE(UInt32(96000)); appendLE(UInt16(2)); appendLE(UInt16(16)); wave.append(Data("data".utf8)); appendLE(UInt32(96000*2))
        for index in 0..<96000 { appendLE(Int16(sin(Double(index)*2*Double.pi*440/48000)*12000)) }
        try wave.write(to: sound)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: movie), audioAsset = AVURLAsset(url: sound)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first!
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first!
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        try withExtendedLifetime((videoAsset, audioAsset)) {
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: videoTrack, at: .zero)
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: audioTrack, at: .zero)
        }
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await exporter.export(to: combined, as: .mp4)
        for muted in [false, true] {
            var settings = VideoSettings(); settings.quality = "compact"; settings.muted = muted; settings.fps = 12
            let prepared = try await VideoEngine.prepare(url: combined, settings: settings)
            let destination = folder.appendingPathComponent(muted ? "muted.mp4" : "audible.mp4")
            try await VideoEngine.export(prepared, to: destination)
            let asset = AVURLAsset(url: destination), tracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var maximum: Float = 0
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block); var values = [Float](repeating: 0, count: length/4)
                _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                maximum = max(maximum, values.map { abs($0) }.max() ?? 0)
            }
            if muted { XCTAssertLessThan(maximum, 0.001) } else { XCTAssertGreaterThan(maximum, 0.1) }
            let video = try await asset.loadTracks(withMediaType: .video).first!
            let size = try await video.load(.naturalSize); XCTAssertEqual(size, CGSize(width: 320, height: 180))
        }
    }
    func testCameraSegmentTrimRemovesLeadAndTail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-camera-align-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("camera.mp4"), output = folder.appendingPathComponent("aligned.mp4")
        try await fixture(input)
        try await VideoEngine.trim(input, start: 0.25, duration: 1, to: output)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.09)
    }
    func testConcatenationPreservesBothSegments() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-join-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mp4"), output = folder.appendingPathComponent("joined.mp4")
        try await fixture(input); try await VideoEngine.concatenate([input, input], to: output)
        let inputDuration = try await AVURLAsset(url: input).load(.duration).seconds, duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, inputDuration*2, accuracy: 0.1)
    }
}
