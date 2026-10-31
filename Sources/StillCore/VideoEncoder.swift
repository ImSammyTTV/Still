import AVFoundation

public enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case original, high, balanced, compact
    public var id: String { rawValue }
    public var title: String { switch self { case .original: return "Maximum"; case .high: return "High"; case .balanced: return "Balanced"; case .compact: return "Smaller File" } }
    public func bitrate(size: CGSize, fps: Int) -> Int {
        let factor = self == .compact ? 0.045 : self == .balanced ? 0.09 : 0.18
        return max(400_000, min(100_000_000, Int(size.width*size.height*Double(max(1, fps))*factor)))
    }
}
/// A video bitrate you name in Settings. Its `tag` goes wherever a quality name goes (`VideoSettings.quality`) and
/// carries the bitrate itself, so saved edits keep working after a preset is deleted, and builds that don't know
/// presets fall back to High.
public struct BitratePreset: Codable, Identifiable, Equatable {
    public static let megabitRange: ClosedRange<Double> = 1...100
    public var id = UUID()
    public var name: String
    public var megabits: Double
    public init(name: String, megabits: Double) { self.name = name; self.megabits = megabits }
    public var bitrate: Int { Int(min(Self.megabitRange.upperBound, max(Self.megabitRange.lowerBound, megabits))*1_000_000) }
    public var tag: String { "bitrate:\(bitrate)" }
    public var title: String { "\(name) (\(Self.label(bitrate)))" }
    public static func label(_ bitrate: Int) -> String { "\((Double(bitrate)/100_000).rounded()/10) Mbps".replacingOccurrences(of: ".0 ", with: " ") }
    public static func bitrate(tag: String?) -> Int? {
        guard let tag, tag.hasPrefix("bitrate:"), let value = Int(tag.dropFirst(8)), value > 0 else { return nil }
        return Int(min(megabitRange.upperBound, max(megabitRange.lowerBound, Double(value)/1_000_000))*1_000_000)
    }
}
private final class EncodingSession: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
    func cancel() { reader.cancelReading(); writer.cancelWriting() }
}
public enum VideoEncoder {
    public static func encode(_ video: PreparedVideo, to url: URL, quality: VideoQuality, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: video.asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let session = EncodingSession(reader: reader, writer: writer)
        let tracks = try await video.asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = video.composition; output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.export }; reader.add(output)
        let fps = max(1, Int((1/video.composition.frameDuration.seconds).rounded()))
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(video.size.width), AVVideoHeightKey: Int(video.size.height), AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: video.bitrate ?? quality.bitrate(size: video.size, fps: fps), AVVideoExpectedSourceFrameRateKey: fps, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: fps*2]]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw VideoError.export }; writer.add(input)
        let audioTracks = try await video.asset.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?, audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
            out.audioMix = video.audioMix; out.alwaysCopiesSampleData = false; out.audioTimePitchAlgorithm = .spectral
            let sink = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
            guard reader.canAdd(out), writer.canAdd(sink) else { throw VideoError.export }
            reader.add(out); writer.add(sink); audioOutput = out; audioInput = sink
        }
        let audioSource = audioOutput, audioSink = audioInput
        writer.shouldOptimizeForNetworkUse = true
        do {
            try await withTaskCancellationHandler {
                guard writer.startWriting() else { throw writer.error ?? VideoError.export }
                writer.startSession(atSourceTime: .zero)
                guard reader.startReading() else { throw reader.error ?? VideoError.export }
                async let videoResult: Void = pump(output, to: input, session: session, duration: video.duration, progress: progress)
                async let audioResult: Void = pump(audioSource, to: audioSink, session: session, duration: video.duration, progress: nil)
                try await videoResult; try await audioResult
                try Task.checkCancellation()
                if reader.status == .failed { throw reader.error ?? VideoError.export }
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? VideoError.export }
                progress(1)
            } onCancel: { session.cancel() }
        } catch { session.cancel(); try? FileManager.default.removeItem(at: url); throw error }
    }
    private static func pump(_ output: AVAssetReaderOutput?, to input: AVAssetWriterInput?, session: EncodingSession, duration: Double, progress: (@Sendable (Double) -> Void)?) async throws {
        guard let output, let input else { return }
        while true {
            try Task.checkCancellation()
            if session.writer.status == .failed { throw session.writer.error ?? VideoError.export }
            if session.reader.status == .failed { throw session.reader.error ?? VideoError.export }
            guard input.isReadyForMoreMediaData else { try await Task.sleep(for: .milliseconds(3)); continue }
            guard let buffer = output.copyNextSampleBuffer() else { input.markAsFinished(); return }
            guard input.append(buffer) else { throw session.writer.error ?? VideoError.export }
            if let progress { progress(min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(buffer).seconds/max(0.01, duration)))) }
        }
    }
}
