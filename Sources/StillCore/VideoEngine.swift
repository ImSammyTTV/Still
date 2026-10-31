import AVFoundation
import AppKit
import CoreImage
import CoreText
import UniformTypeIdentifiers

public struct PreparedVideo {
    public let asset: AVMutableComposition
    public let composition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix
    public let duration: Double
    public let size: CGSize
    public let quality: VideoQuality
    /// A custom preset's bitrate; when set it replaces the size-based bitrate of `quality`.
    public let bitrate: Int?
}
public enum VideoError: LocalizedError {
    case noVideo, export, invalidRange, cancelled
    public var errorDescription: String? { switch self { case .noVideo: return "This file has no readable video track."; case .export: return "Video export failed. Try a smaller output size."; case .invalidRange: return "Choose a trim range with at least one frame."; case .cancelled: return "Export cancelled." } }
}
public enum VideoEngine {
    public static func prepare(url: URL, settings: VideoSettings, metadata: RecordingMetadata = .init(), cameraURL: URL? = nil) async throws -> PreparedVideo {
        let source = AVURLAsset(url: url)
        guard let original = try await source.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let duration = try await source.load(.duration).seconds
        let start = max(0, min(settings.start, duration)), end = settings.end > 0 ? min(settings.end, duration) : duration
        guard end-start > 0.025 else { throw VideoError.invalidRange }
        // The stretches that stay, laid end to end: cuts drop out and the rest closes up.
        let kept = VideoTimeline.kept(start: start, end: end, cuts: settings.cuts ?? [])
        guard VideoTimeline.length(kept) > 0.025 else { throw VideoError.invalidRange }
        let cm = { (t: Double) in CMTime(seconds: t, preferredTimescale: 600) }
        let pieces = kept.map { CMTimeRange(start: cm($0.start), duration: cm($0.end-$0.start)) }
        let total = VideoTimeline.length(kept)
        let asset = AVMutableComposition()
        guard let video = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoError.noVideo }
        var at = CMTime.zero
        for piece in pieces { try video.insertTimeRange(piece, of: original, at: at); at = at + piece.duration }
        let naturalSize = try await original.load(.naturalSize), transform = try await original.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        var cameraID: CMPersistentTrackID?
        var cameraTransform = CGAffineTransform.identity
        if settings.cameraEnabled, let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) {
            let camera = AVURLAsset(url: cameraURL)
            if let originalCamera = try await camera.loadTracks(withMediaType: .video).first, let track = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let cameraDuration = try await camera.load(.duration).seconds
                var cameraAt = 0.0, inserted = false
                for segment in kept {
                    let cameraStart = max(0, segment.start+metadata.cameraOffset), length = min(segment.end-segment.start, cameraDuration-cameraStart)
                    if length > 0 { try track.insertTimeRange(CMTimeRange(start: cm(cameraStart), duration: cm(length)), of: originalCamera, at: cm(cameraAt)); inserted = true }
                    cameraAt += segment.end-segment.start
                }
                if inserted { cameraID = track.trackID; cameraTransform = try await originalCamera.load(.preferredTransform) }
            }
        }
        let mix = AVMutableAudioMix(); var mixInputs: [AVMutableAudioMixInputParameters] = []
        for originalAudio in try await source.loadTracks(withMediaType: .audio) {
            if let audio = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var audioAt = CMTime.zero
                for piece in pieces { try audio.insertTimeRange(piece, of: originalAudio, at: audioAt); audioAt = audioAt + piece.duration }
                let input = AVMutableAudioMixInputParameters(track: audio); input.setVolume(settings.muted ? 0 : 1, at: .zero); mixInputs.append(input)
            }
        }
        mix.inputParameters = mixInputs
        let padding = settings.frame == "none" ? 0 : settings.padding
        var width = oriented.width+padding*2, height = oriented.height+padding*2
        if settings.aspect > 0 { if width/height < settings.aspect { width = height*settings.aspect } else { height = width/settings.aspect } }
        let limit = min(1, 4096/max(width, height)); width = max(2, floor(width*limit/2)*2); height = max(2, floor(height*limit/2)*2)
        if let chosen = settings.exportHeight, chosen > 0 { let reduced = VideoExportSize.size(width: width, height: height, limit: chosen); width = reduced.width; height = reduced.height }
        let size = CGSize(width: width, height: height)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = CaptureVideoCompositor.self
        composition.renderSize = size; composition.frameDuration = CMTime(value: 1, timescale: Int32(max(1, min(60, settings.fps))))
        let instruction = CaptureVideoInstruction(timeRange: CMTimeRange(start: .zero, duration: cm(total)), kept: kept, screenID: video.trackID, cameraID: cameraID, settings: settings, metadata: metadata, size: size, transform: transform, cameraTransform: cameraTransform, sourceSize: oriented)
        composition.instructions = [instruction]
        return PreparedVideo(asset: asset, composition: composition, audioMix: mix, duration: total, size: size, quality: VideoQuality(rawValue: settings.quality ?? "high") ?? .high, bitrate: BitratePreset.bitrate(tag: settings.quality))
    }
    public static func export(_ prepared: PreparedVideo, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if prepared.quality != .original || prepared.bitrate != nil { try await VideoEncoder.encode(prepared, to: url, quality: prepared.quality, progress: progress); return }
        guard let exporter = AVAssetExportSession(asset: prepared.asset, presetName: AVAssetExportPresetHighestQuality) else { throw VideoError.export }
        exporter.videoComposition = prepared.composition; exporter.audioMix = prepared.audioMix; exporter.shouldOptimizeForNetworkUse = true
        let observer = Task {
            for await state in exporter.states(updateInterval: 0.15) {
                if case .exporting(let progressState) = state { progress(progressState.fractionCompleted) }
            }
        }
        defer { observer.cancel() }
        try await withTaskCancellationHandler { try await exporter.export(to: url, as: .mp4) } onCancel: { exporter.cancelExport() }
        progress(1)
    }
    public static func gif(_ prepared: PreparedVideo, to url: URL, fps: Int, width: Int, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let rate = max(1, min(30, fps)), count = max(1, Int(ceil(prepared.duration*Double(rate))))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw VideoError.export }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: prepared.asset); generator.videoComposition = prepared.composition
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: width, height: max(1, Int(Double(width)*prepared.size.height/prepared.size.width)))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                let time = CMTime(seconds: min(prepared.duration-0.001, Double(index)/Double(rate)), preferredTimescale: 600)
                let result = try await generator.image(at: time)
                CGImageDestinationAddImage(destination, result.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0/Double(rate), kCGImagePropertyGIFUnclampedDelayTime: 1.0/Double(rate)]] as CFDictionary)
                progress(Double(index+1)/Double(count))
            }
            guard CGImageDestinationFinalize(destination) else { throw VideoError.export }
        } catch { generator.cancelAllCGImageGeneration(); try? FileManager.default.removeItem(at: url); throw error }
    }
    public static func trim(_ url: URL, start: Double, duration: Double, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        let available = try await asset.load(.duration).seconds
        let beginning = max(0, min(start, max(0, available-0.001)))
        let length = min(max(0, duration), available-beginning)
        guard length > 0 else { throw VideoError.noVideo }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: beginning, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        for kind in [AVMediaType.video, .audio] {
            for source in try await asset.loadTracks(withMediaType: kind) {
                guard let track = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoError.export }
                try track.insertTimeRange(range, of: source, at: .zero)
                track.preferredTransform = try await source.load(.preferredTransform)
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw VideoError.export }
        try await exporter.export(to: output, as: .mp4)
    }
    public static func concatenate(_ urls: [URL], to output: URL) async throws {
        guard !urls.isEmpty else { throw VideoError.noVideo }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoError.noVideo }
        var audioTracks: [AVMutableCompositionTrack] = [], offset = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url), duration = try await AVURLAsset(url: url).load(.duration)
            if duration.seconds <= 0 { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            if let track = try await asset.loadTracks(withMediaType: .video).first { try video.insertTimeRange(range, of: track, at: offset); if offset == .zero { video.preferredTransform = try await track.load(.preferredTransform) } }
            for (index, source) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                while audioTracks.count <= index { if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { audioTracks.append(track) } else { throw VideoError.export } }
                try audioTracks[index].insertTimeRange(range, of: source, at: offset)
            }
            offset = offset+duration
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw VideoError.export }
        try await exporter.export(to: output, as: .mp4)
    }
}

final class CaptureVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    /// The stretches of the recording laid end to end, to find the recording's time at each frame.
    let kept: [VideoCut]
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenID: CMPersistentTrackID
    let cameraID: CMPersistentTrackID?
    let settings: VideoSettings
    let metadata: RecordingMetadata
    let size: CGSize
    let transform: CGAffineTransform
    let sourceSize: CGSize
    let cameraTransform: CGAffineTransform
    init(timeRange: CMTimeRange, kept: [VideoCut], screenID: CMPersistentTrackID, cameraID: CMPersistentTrackID?, settings: VideoSettings, metadata: RecordingMetadata, size: CGSize, transform: CGAffineTransform, cameraTransform: CGAffineTransform, sourceSize: CGSize) {
        self.timeRange = timeRange; self.kept = kept; self.screenID = screenID; self.cameraID = cameraID; self.settings = settings; self.metadata = metadata; self.size = size; self.transform = transform; self.sourceSize = sourceSize; self.cameraTransform = cameraTransform
        requiredSourceTrackIDs = ([screenID]+(cameraID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

public final class CaptureVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    #if compiler(>=6.4)
    public typealias PixelAttributes = [String: any Sendable]
    #else
    public typealias PixelAttributes = [String: Any]
    #endif
    public var sourcePixelBufferAttributes: PixelAttributes? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    public var requiredPixelBufferAttributesForRenderContext: PixelAttributes { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true] }
    private let queue = DispatchQueue(label: "local.sam.Still.video-compositor", qos: .userInitiated)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false
    private var textImages: [String: CIImage] = [:]
    private lazy var cursorImage = makeCursor()
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { queue.sync { renderContext = newRenderContext; cancelled = false } }
    public func cancelAllPendingVideoCompositionRequests() { queue.sync { cancelled = true }; queue.async { self.cancelled = false } }
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard !self.cancelled else { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? CaptureVideoInstruction,
                  let source = request.sourceFrame(byTrackID: instruction.screenID), let output = self.renderContext?.newPixelBuffer() else { request.finish(with: VideoError.export); return }
            let image = self.frame(source: source, camera: instruction.cameraID.flatMap { request.sourceFrame(byTrackID: $0) }, time: VideoTimeline.sourceTime(at: request.compositionTime.seconds, kept: instruction.kept), instruction: instruction)
            self.ci.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: output)
        }
    }
    private func frame(source: CVPixelBuffer, camera: CVPixelBuffer?, time: Double, instruction i: CaptureVideoInstruction) -> CIImage {
        let s = i.settings, bounds = CGRect(origin: .zero, size: i.size)
        let style = FrameStyle(rawValue: s.frame) ?? .none
        let colors = style == .none ? [NSColor.black, NSColor.black] : style.colors
        var background = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: i.size.height), "inputPoint1": CIVector(x: i.size.width, y: 0), "inputColor0": CIColor(cgColor: colors[0].cgColor), "inputColor1": CIColor(cgColor: colors[1].cgColor)])!.outputImage!.cropped(to: bounds)
        var screen = CIImage(cvPixelBuffer: source).transformed(by: i.transform)
        screen = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let padding = style == .none ? 0 : s.padding
        let scale = min((i.size.width-padding*2)/screen.extent.width, (i.size.height-padding*2)/screen.extent.height)
        let contentSize = CGSize(width: screen.extent.width*scale, height: screen.extent.height*scale)
        let origin = CGPoint(x: (i.size.width-contentSize.width)/2, y: (i.size.height-contentSize.height)/2)
        let contentRect = CGRect(origin: origin, size: contentSize)
        var zoom = 1.0, target = CGPoint(x: 0.5, y: 0.5), zoomMotion = 0.0
        for segment in s.zooms where time >= segment.start && time <= segment.end {
            let ramp = min(0.4, (segment.end-segment.start)/3)
            let raw = min(1, max(0, min((time-segment.start)/ramp, (segment.end-time)/ramp)))
            let ease = raw*raw*(3-2*raw)
            zoom = 1+(segment.scale-1)*ease; target = CGPoint(x: segment.x, y: segment.y); zoomMotion = raw < 1 ? 1-raw : 0; break
        }
        var tx = contentSize.width/2-target.x*contentSize.width*zoom, ty = contentSize.height/2-(1-target.y)*contentSize.height*zoom
        tx = min(0, max(contentSize.width*(1-zoom), tx)); ty = min(0, max(contentSize.height*(1-zoom), ty))
        screen = screen.transformed(by: CGAffineTransform(scaleX: scale*zoom, y: scale*zoom)).transformed(by: CGAffineTransform(translationX: origin.x+tx, y: origin.y+ty)).cropped(to: contentRect)
        if s.motionBlur > 0, zoomMotion > 0 { screen = screen.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: s.motionBlur*zoomMotion*12, kCIInputAngleKey: 0]).cropped(to: contentRect) }
        let radius = style == .none ? 0 : s.radius
        let mask = roundedMask(contentRect, radius: radius)
        if style != .none, s.shadow > 0 {
            let shadow = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: s.shadow]).applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.3)])
            background = shadow.transformed(by: CGAffineTransform(translationX: 0, y: -s.shadow/2)).composited(over: background)
        }
        var result = screen.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
        let mapPoint: (Double, Double) -> CGPoint = { x, y in CGPoint(x: origin.x+tx+x*contentSize.width*zoom, y: origin.y+ty+(1-y)*contentSize.height*zoom) }
        if !i.metadata.cursorIncludedInVideo, s.cursorScale > 0, let pointer = pointer(at: time, samples: i.metadata.pointer, smooth: s.smoothCursor) {
            let point = mapPoint(pointer.x, pointer.y)
            let cursorScale = s.cursorScale*max(0.7, contentSize.width/1920)*zoom
            let cursor: CIImage
            if s.cursorStyle == "dot" { cursor = ring(color: NSColor.white, filled: true) } else { cursor = cursorImage }
            let overlay = cursor.transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale)).transformed(by: CGAffineTransform(translationX: point.x, y: point.y-32*cursorScale)).cropped(to: contentRect)
            result = overlay.composited(over: result)
        }
        if s.showClicks {
            for click in i.metadata.clicks where time >= click.time && time-click.time < 0.6 {
                let age = (time-click.time)/0.6, point = mapPoint(click.x, click.y), animated = s.clickAnimated ?? true
                let scale = max(0.2, min(4, s.clickSize ?? 1))*(animated ? 0.6+age*0.7 : 1)
                let overlay = ring(color: NSColor(hex: s.clickColor), filled: s.clickStyle == "filled").transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: point.x-32*scale, y: point.y-32*scale)).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: animated ? 1-age : 0.9)]).cropped(to: contentRect)
                result = overlay.composited(over: result)
            }
        }
        if s.showKeystrokes, let key = i.metadata.keys.last(where: { $0.time <= time && time-$0.time < 1.7 }) {
            let factor = max(0.5, min(3, s.keysSize ?? 1))
            let overlay = textImage(key.text, light: s.keysStyle == "light").transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            let x = max(8, (i.size.width-overlay.extent.width)*max(0, min(1, s.keysX ?? 0.5)))
            let y = max(8, (i.size.height-overlay.extent.height)*(1-max(0, min(1, s.keysY ?? 0.97))))
            result = overlay.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: result)
        }
        if let camera, s.cameraEnabled {
            var image = CIImage(cvPixelBuffer: camera).transformed(by: i.cameraTransform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            if s.cameraMirror == true { image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.width, ty: 0)) }
            if s.cameraFullscreen == true {
                let factor = max(i.size.width/image.extent.width, i.size.height/image.extent.height)
                image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                image = image.transformed(by: CGAffineTransform(translationX: (i.size.width-image.extent.width)/2, y: (i.size.height-image.extent.height)/2))
                return image.cropped(to: bounds)
            }
            let side = min(i.size.width*s.cameraSize, i.size.height*0.8), x = max(0, min(i.size.width-side, i.size.width*s.cameraX-side)), y = max(0, min(i.size.height-side, i.size.height*(1-s.cameraY)))
            let factor = max(side/image.extent.width, side/image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            image = image.transformed(by: CGAffineTransform(translationX: x-(image.extent.width-side)/2, y: y-(image.extent.height-side)/2))
            let rect = CGRect(x: x, y: y, width: side, height: side), mask = roundedMask(rect, radius: s.cameraShape == "circle" ? side/2 : side*0.12)
            result = image.cropped(to: rect).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])
        }
        return result.cropped(to: bounds)
    }
    private func roundedMask(_ rect: CGRect, radius: Double) -> CIImage { CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": CIColor.white])!.outputImage! }
    private func pointer(at time: Double, samples: [PointerSample], smooth: Bool) -> PointerSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count
        while low < high { let mid = (low+high)/2; if samples[mid].time <= time { low = mid+1 } else { high = mid } }
        let index = max(0, low-1), a = samples[index]
        guard smooth, index+1 < samples.count else { return a }
        let b = samples[index+1], t = min(1, max(0, (time-a.time)/max(0.001, b.time-a.time)))
        return PointerSample(time: time, x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
    }
    private func makeCursor() -> CIImage {
        let ctx = CGContext(data: nil, width: 28, height: 38, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.move(to: CGPoint(x: 3, y: 35)); ctx.addLine(to: CGPoint(x: 3, y: 8)); ctx.addLine(to: CGPoint(x: 10, y: 15)); ctx.addLine(to: CGPoint(x: 15, y: 3)); ctx.addLine(to: CGPoint(x: 21, y: 6)); ctx.addLine(to: CGPoint(x: 16, y: 18)); ctx.addLine(to: CGPoint(x: 26, y: 18)); ctx.closePath()
        ctx.setFillColor(NSColor.black.cgColor); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2); ctx.drawPath(using: .fillStroke)
        return CIImage(cgImage: ctx.makeImage()!)
    }
    private func ring(color: NSColor, filled: Bool) -> CIImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(3)
        ctx.addEllipse(in: CGRect(x: 10, y: 10, width: 44, height: 44)); ctx.drawPath(using: filled ? .fill : .stroke)
        return CIImage(cgImage: ctx.makeImage()!)
    }
    private func textImage(_ text: String, light: Bool = false) -> CIImage {
        let cacheKey = "\(light):\(text)"
        if let image = textImages[cacheKey] { return image }
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: (light ? NSColor.black : NSColor.white).cgColor]))
        let width = max(80, Int(CTLineGetTypographicBounds(line, nil, nil, nil))+38), height = 52
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor((light ? NSColor.white : NSColor.black).withAlphaComponent(0.85).cgColor); ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath(); ctx.textPosition = CGPoint(x: 19, y: 16); CTLineDraw(line, ctx)
        let image = CIImage(cgImage: ctx.makeImage()!); if textImages.count > 200 { textImages.removeAll() }; textImages[cacheKey] = image; return image
    }
}
