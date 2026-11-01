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
    public static func prepare(url: URL, settings: VideoSettings, metadata: RecordingMetadata = .init(), cameraURL: URL? = nil, musicURL: URL? = nil) async throws -> PreparedVideo {
        let source = AVURLAsset(url: url)
        guard let original = try await source.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let duration = try await source.load(.duration).seconds
        let start = max(0, min(settings.start, duration)), end = settings.end > 0 ? min(settings.end, duration) : duration
        guard end-start > 0.025 else { throw VideoError.invalidRange }
        // The stretches that stay, laid end to end: cuts drop out and the rest closes up.
        let kept = VideoTimeline.kept(start: start, end: end, cuts: settings.cuts ?? [], skims: settings.skims ?? [])
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
        // A faster export squeezes every track into less time; each frame still maps back to the recording's moment.
        let speed = min(4, max(1, settings.speed ?? 1))
        // Fast-forwards squeeze their own stretches first (from the end, so earlier places stay put), then the export
        // speed squeezes the lot. Both happen before the music goes in, which is laid to the finished length.
        var placed = 0.0, places: [(VideoCut, Double)] = []
        for k in kept { places.append((k, placed)); placed += k.end - k.start }
        for (k, at) in places.reversed() where (k.rate ?? 1) > 1.001 { asset.scaleTimeRange(CMTimeRange(start: cm(at), duration: cm(k.end-k.start)), toDuration: cm(k.played)) }
        if speed > 1.001 { asset.scaleTimeRange(CMTimeRange(start: .zero, duration: cm(total)), toDuration: cm(total/speed)) }
        let squeezed = speed > 1.001 || kept.contains { ($0.rate ?? 1) > 1.001 }
        // The opening and closing fade the sound with the picture.
        let fade = VideoTransition.length(start: start, end: end)
        for input in mixInputs where fade > 0 {
            let full: Float = settings.muted ? 0 : 1
            if (settings.opening ?? "none") != "none" { input.setVolumeRamp(fromStartVolume: 0, toEndVolume: full, timeRange: CMTimeRange(start: .zero, duration: cm(fade/speed))) }
            if (settings.closing ?? "none") != "none" { input.setVolumeRamp(fromStartVolume: full, toEndVolume: 0, timeRange: CMTimeRange(start: cm(max(0, total-fade)/speed), duration: cm(fade/speed))) }
        }
        // While fast-forwarding the voice drops to a murmur, so it's there without chattering. Kept clear of the fades.
        if !settings.muted {
            let from = (settings.opening ?? "none") != "none" ? fade/speed : 0, to = (settings.closing ?? "none") != "none" ? max(0, total-fade)/speed : total/speed
            for k in kept where (k.rate ?? 1) > 1.001 {
                let a = max(from, VideoTimeline.outputTime(at: k.start, kept: kept)/speed), b = min(to, a + k.played/speed)
                guard b - a > 0.05 else { continue }
                for input in mixInputs { input.setVolumeRamp(fromStartVolume: 0.35, toEndVolume: 0.35, timeRange: CMTimeRange(start: cm(a), duration: cm(b-a))); if b < to - 0.001 { input.setVolume(1, at: cm(b)) } }
            }
        }
        // Background music: looped to the finished length at its own speed, dipping while someone speaks.
        if let music = settings.music, let musicURL, FileManager.default.fileExists(atPath: musicURL.path),
           let musicTrack = try await AVURLAsset(url: musicURL).loadTracks(withMediaType: .audio).first,
           let track = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let length = try await musicTrack.load(.timeRange).duration.seconds, finished = total/speed
            if length > 0.1 {
                var at = 0.0
                while at < finished - 0.01 {
                    let piece = min(length, finished - at)
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(piece)), of: musicTrack, at: cm(at)); at += piece
                }
                let input = AVMutableAudioMixInputParameters(track: track), volume = Float(min(1, max(0, music.volume)))
                input.setVolume(volume, at: .zero)
                if music.duck {
                    let low = volume * 0.3, ramp = 0.15
                    var after = -1.0
                    for range in music.speech {
                        let a = VideoTimeline.outputTime(at: range.start, kept: kept)/speed, b = VideoTimeline.outputTime(at: range.end, kept: kept)/speed
                        guard b - a > 0.05, a - ramp > after else { continue }
                        input.setVolumeRamp(fromStartVolume: volume, toEndVolume: low, timeRange: CMTimeRange(start: cm(max(0, a - ramp)), duration: cm(ramp)))
                        input.setVolumeRamp(fromStartVolume: low, toEndVolume: low, timeRange: CMTimeRange(start: cm(max(0, a)), duration: cm(max(0.01, b - a))))
                        input.setVolumeRamp(fromStartVolume: low, toEndVolume: volume, timeRange: CMTimeRange(start: cm(b), duration: cm(ramp)))
                        after = b + ramp
                    }
                }
                mixInputs.append(input)
            }
        }
        // The mix keeps copies of its inputs, so they go back in after the speed and fades are set.
        mix.inputParameters = mixInputs
        if squeezed { for input in mixInputs { input.audioTimePitchAlgorithm = .spectral } }
        let padding = settings.frame == "none" ? 0 : settings.padding
        var width = oriented.width+padding*2, height = oriented.height+padding*2
        if settings.aspect > 0 { if width/height < settings.aspect { width = height*settings.aspect } else { height = width/settings.aspect } }
        let limit = min(1, 4096/max(width, height)); width = max(2, floor(width*limit/2)*2); height = max(2, floor(height*limit/2)*2)
        if let chosen = settings.exportHeight, chosen > 0 { let reduced = VideoExportSize.size(width: width, height: height, limit: chosen); width = reduced.width; height = reduced.height }
        let size = CGSize(width: width, height: height)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = CaptureVideoCompositor.self
        composition.renderSize = size; composition.frameDuration = CMTime(value: 1, timescale: Int32(max(1, min(60, settings.fps))))
        let instruction = CaptureVideoInstruction(timeRange: CMTimeRange(start: .zero, duration: cm(total/speed)), kept: kept, speed: speed, screenID: video.trackID, cameraID: cameraID, settings: settings, metadata: metadata, size: size, transform: transform, cameraTransform: cameraTransform, sourceSize: oriented)
        composition.instructions = [instruction]
        return PreparedVideo(asset: asset, composition: composition, audioMix: mix, duration: total/speed, size: size, quality: VideoQuality(rawValue: settings.quality ?? "high") ?? .high, bitrate: BitratePreset.bitrate(tag: settings.quality))
    }
    public static func export(_ prepared: PreparedVideo, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if prepared.quality != .original || prepared.bitrate != nil { try await VideoEncoder.encode(prepared, to: url, quality: prepared.quality, progress: progress); return }
        guard let exporter = AVAssetExportSession(asset: prepared.asset, presetName: AVAssetExportPresetHighestQuality) else { throw VideoError.export }
        exporter.videoComposition = prepared.composition; exporter.audioMix = prepared.audioMix; exporter.shouldOptimizeForNetworkUse = true; exporter.audioTimePitchAlgorithm = .spectral
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
    /// How much faster than recorded the video plays.
    let speed: Double
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
    init(timeRange: CMTimeRange, kept: [VideoCut], speed: Double, screenID: CMPersistentTrackID, cameraID: CMPersistentTrackID?, settings: VideoSettings, metadata: RecordingMetadata, size: CGSize, transform: CGAffineTransform, cameraTransform: CGAffineTransform, sourceSize: CGSize) {
        self.timeRange = timeRange; self.kept = kept; self.speed = speed; self.screenID = screenID; self.cameraID = cameraID; self.settings = settings; self.metadata = metadata; self.size = size; self.transform = transform; self.sourceSize = sourceSize; self.cameraTransform = cameraTransform
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
            let image = self.frame(source: source, camera: instruction.cameraID.flatMap { request.sourceFrame(byTrackID: $0) }, time: VideoTimeline.sourceTime(at: request.compositionTime.seconds*instruction.speed, kept: instruction.kept), instruction: instruction)
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
        // Blur boxes, on the recording's own picture so they follow it through zooms. Core Image counts from the bottom.
        for blur in s.blurs ?? [] where time >= blur.start && time <= blur.end {
            let w = screen.extent.width, h = screen.extent.height
            let rect = CGRect(x: blur.x*w, y: (1-blur.y-blur.h)*h, width: blur.w*w, height: blur.h*h).integral
            let radius = max(6, min(rect.width, rect.height)/5)
            let soft = screen.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: rect)
            screen = soft.composited(over: screen)
        }
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
        // Callouts: arrows, boxes and spotlights on the recording's picture, so they follow it through zooms.
        let showing = (s.callouts ?? []).compactMap { c in c.alpha(at: time).map { (c, $0) } }
        if !showing.isEmpty, let ctx = CGContext(data: nil, width: Int(i.size.width), height: Int(i.size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let unit = max(1, min(contentSize.width, contentSize.height)/360)*min(2, zoom)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for (c, alpha) in showing {
                ctx.saveGState(); ctx.setAlpha(alpha)
                let color = NSColor(hex: c.color).cgColor
                ctx.setStrokeColor(color); ctx.setFillColor(color); ctx.setShadow(offset: .zero, blur: 4*unit, color: NSColor.black.withAlphaComponent(0.45).cgColor)
                if c.kind == "arrow", let x2 = c.x2, let y2 = c.y2 {
                    let tip = mapPoint(c.x, c.y), tail = mapPoint(x2, y2), angle = atan2(tip.y-tail.y, tip.x-tail.x), size = 16*unit
                    ctx.setLineWidth(5*unit); ctx.move(to: tail); ctx.addLine(to: tip); ctx.strokePath()
                    ctx.move(to: CGPoint(x: tip.x-size*cos(angle-0.5), y: tip.y-size*sin(angle-0.5))); ctx.addLine(to: tip); ctx.addLine(to: CGPoint(x: tip.x-size*cos(angle+0.5), y: tip.y-size*sin(angle+0.5))); ctx.closePath(); ctx.fillPath()
                } else if let w = c.w, let h = c.h {
                    let a = mapPoint(c.x, c.y), b = mapPoint(c.x+w, c.y+h)
                    let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
                    if c.kind == "spotlight" {
                        ctx.setShadow(offset: .zero, blur: 0, color: nil); ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                        ctx.addRect(contentRect); ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10*unit, cornerHeight: 10*unit, transform: nil)); ctx.fillPath(using: .evenOdd)
                    } else { ctx.setLineWidth(4*unit); ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8*unit, cornerHeight: 8*unit, transform: nil)); ctx.strokePath() }
                }
                ctx.restoreGState()
            }
            if let image = ctx.makeImage() { result = CIImage(cgImage: image).cropped(to: contentRect).composited(over: result) }
        }
        // Captions sit over the video area, steady through zooms.
        for caption in s.captions ?? [] {
            guard let alpha = caption.alpha(at: time) else { continue }
            let at = caption.layout(width: contentRect.width, height: contentRect.height)
            let pill = captionImage(caption.text, fontSize: at.fontSize, maxWidth: contentRect.width*0.9)
            let x = contentRect.minX+at.x-pill.extent.width/2
            let centre = min(contentRect.height-pill.extent.height/2-4, max(pill.extent.height/2+4, at.y))
            let y = contentRect.maxY-centre-pill.extent.height/2
            result = pill.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                .transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: result)
        }
        // The fast-forward badge, top right of the video, so viewers know time is skipping.
        let rate = VideoTimeline.skimRate(at: time, skims: s.skims ?? [])
        if rate > 1 {
            let unit = max(1, contentRect.width/900), badge = skimBadge(rate, unit: unit)
            result = badge.transformed(by: CGAffineTransform(translationX: contentRect.maxX-badge.extent.width-14*unit, y: contentRect.maxY-badge.extent.height-14*unit)).composited(over: result)
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
        // The opening and closing: the picture fades over its background (or black) and rises from slightly smaller.
        if let first = i.kept.first, let last = i.kept.last {
            let ends = VideoTransition.at(time, start: first.start, end: last.end, opening: s.opening ?? "none", closing: s.closing ?? "none")
            if ends.level < 0.999 || ends.scale < 0.999 {
                let centre = CGPoint(x: contentRect.midX, y: contentRect.midY)
                let layer = result.cropped(to: contentRect)
                    .transformed(by: CGAffineTransform(translationX: -centre.x, y: -centre.y).concatenating(CGAffineTransform(scaleX: ends.scale, y: ends.scale)).concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, ends.level))])
                result = layer.composited(over: background)
            }
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
    /// A caption's pill: white semibold text, up to three lines, on a dark rounded box.
    private func captionImage(_ text: String, fontSize: Double, maxWidth: Double) -> CIImage {
        let cacheKey = "caption:\(Int(fontSize)):\(Int(maxWidth)):\(text)"
        if let image = textImages[cacheKey] { return image }
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil) ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).map { CTLineCreateWithAttributedString(NSAttributedString(string: String($0), attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: NSColor.white.cgColor])) }
        let lineHeight = fontSize*1.25, padX = fontSize*0.8, padY = fontSize*0.45
        let textWidth = min(maxWidth, lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0)
        let width = Int(textWidth+padX*2), height = Int(lineHeight*Double(lines.count)+padY*2)
        guard width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let radius = min(Double(height)/2, fontSize*0.6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor); ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
        for (index, line) in lines.enumerated() {
            let lineWidth = min(textWidth, CTLineGetTypographicBounds(line, nil, nil, nil))
            // Lines from the top; Core Graphics counts from the bottom.
            let baseline = Double(height)-padY-lineHeight*Double(index+1)+lineHeight*0.3
            ctx.textPosition = CGPoint(x: (Double(width)-lineWidth)/2, y: baseline); CTLineDraw(line, ctx)
        }
        let image = CIImage(cgImage: ctx.makeImage()!); if textImages.count > 200 { textImages.removeAll() }; textImages[cacheKey] = image; return image
    }
    /// The fast-forward badge: two arrowheads and the rate on a dark pill.
    private func skimBadge(_ rate: Double, unit: Double) -> CIImage {
        let cacheKey = "skim:\(Int(rate)):\(Int(unit*10))"
        if let image = textImages[cacheKey] { return image }
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 15*unit, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(Int(rate))×", attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: NSColor.white.cgColor]))
        let h = 30*unit, pad = 10*unit, w = 34*unit+CTLineGetTypographicBounds(line, nil, nil, nil)+pad
        guard let ctx = CGContext(data: nil, width: Int(w.rounded(.up)), height: Int(h.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: h/2, cornerHeight: h/2, transform: nil)); ctx.fillPath()
        ctx.setFillColor(NSColor.white.cgColor)
        for dx in [0, 9*unit] { let ax = pad+dx; ctx.move(to: CGPoint(x: ax, y: 9*unit)); ctx.addLine(to: CGPoint(x: ax+9*unit, y: h/2)); ctx.addLine(to: CGPoint(x: ax, y: h-9*unit)); ctx.closePath(); ctx.fillPath() }
        ctx.textPosition = CGPoint(x: pad+22*unit, y: h/2-5*unit); CTLineDraw(line, ctx)
        guard let made = ctx.makeImage() else { return CIImage.empty() }
        let image = CIImage(cgImage: made); if textImages.count > 200 { textImages.removeAll() }; textImages[cacheKey] = image; return image
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
