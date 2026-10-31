import Foundation
import CoreGraphics

/// A stretch cut out of the middle of a recording, in the recording's own time.
public struct VideoCut: Codable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Cuts and the stretches that stay. Cuts are kept sorted, inside the clip, at least `minimumCut` long, and merged
/// where they touch. Windows and Linux follow the same rules (shared/trim.js) and share the test cases.
public enum VideoTimeline {
    public static let minimumCut = 0.1

    public static func normalized(_ cuts: [VideoCut], start: Double, end: Double) -> [VideoCut] {
        let clamp = { (t: Double) in min(end, max(start, t)) }
        let sorted = cuts.map { VideoCut(start: clamp($0.start), end: clamp($0.end)) }
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end - $0.start >= minimumCut }.sorted { $0.start < $1.start }
        var out: [VideoCut] = []
        for cut in sorted { if let last = out.last, cut.start <= last.end { out[out.count-1].end = max(last.end, cut.end) } else { out.append(cut) } }
        return out
    }

    public static func adding(_ cuts: [VideoCut], from a: Double, to b: Double, start: Double, end: Double) -> [VideoCut] {
        normalized(cuts + [VideoCut(start: min(a, b), end: max(a, b))], start: start, end: end)
    }

    /// The stretches that stay, in order.
    public static func kept(start: Double, end: Double, cuts: [VideoCut]) -> [VideoCut] {
        var out: [VideoCut] = [], at = start
        for cut in normalized(cuts, start: start, end: end) { if cut.start > at { out.append(VideoCut(start: at, end: cut.start)) }; at = max(at, cut.end) }
        if end > at { out.append(VideoCut(start: at, end: end)) }
        return out
    }

    public static func length(_ kept: [VideoCut]) -> Double { kept.reduce(0) { $0 + $1.end - $1.start } }

    /// The recording's time at a moment of the finished video.
    public static func sourceTime(at time: Double, kept: [VideoCut]) -> Double {
        var left = max(0, time)
        for segment in kept { let length = segment.end - segment.start; if left <= length { return segment.start + left }; left -= length }
        return kept.last?.end ?? 0
    }

    /// The finished video's time at a moment of the recording; a time inside a cut counts from where the cut ends.
    public static func outputTime(at time: Double, kept: [VideoCut]) -> Double {
        var before = 0.0
        for segment in kept {
            if time < segment.start { return before }
            if time <= segment.end { return before + time - segment.start }
            before += segment.end - segment.start
        }
        return before
    }
}

/// An exported video's size: the shorter side brought down to `limit` (1080 for "1080p"), never up, and both sides
/// even, as video encoders need. A limit of 0 keeps the size. Windows and Linux use the same rule (geometry.js).
public enum VideoExportSize {
    public static let limits = [0, 2160, 1440, 1080, 720, 480]
    public static func title(_ limit: Int) -> String { limit == 0 ? "Original" : limit == 2160 ? "4K (2160p)" : "\(limit)p" }
    public static func size(width: Double, height: Double, limit: Int) -> CGSize {
        let k = limit > 0 ? min(1, Double(limit) / max(1, min(width, height))) : 1
        return CGSize(width: max(2, floor(width * k / 2) * 2), height: max(2, floor(height * k / 2) * 2))
    }
}

/// Text shown over a video for a stretch of the recording (in its own time), in a dark rounded pill near the top,
/// middle or bottom, fading in and out over a quarter of a second. Windows and Linux follow the same rules
/// (shared/captions.js) and share the test cases.
public struct VideoCaption: Codable, Equatable, Hashable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public var position: String
    public var size: String
    public init(start: Double, end: Double, text: String = "Your text", position: String = "bottom", size: String = "medium") {
        self.start = start; self.end = end; self.text = text; self.position = position; self.size = size
    }
    public static let sizes: [String: Double] = ["small": 0.045, "medium": 0.06, "large": 0.08]
    public static let places: [String: Double] = ["top": 0.1, "middle": 0.5, "bottom": 0.88]

    /// A new caption at `time`, three seconds long and kept inside the clip.
    public static func new(at time: Double, start: Double, end: Double) -> VideoCaption { VideoCaption(start: max(start, time), end: min(end, time + 3)) }

    /// How opaque it is at `time` (0 to 1), or nil when it isn't showing.
    public func alpha(at time: Double) -> Double? {
        guard !text.isEmpty, time >= start, time <= end else { return nil }
        let ramp = min(0.25, (end - start) / 3)
        return ramp > 0 ? min(1, (time - start) / ramp, (end - time) / ramp) : 1
    }

    /// Font size and the point the pill is centred on (from the top left) in a video area `width` × `height`.
    public func layout(width: Double, height: Double) -> (fontSize: Double, x: Double, y: Double) {
        ((max(12, min(width, height) * (Self.sizes[size] ?? 0.06))).rounded(), width / 2, height * (Self.places[position] ?? 0.88))
    }
}

/// How a video opens and closes: "fade" eases the picture and sound in from nothing and out again, and "rise" does
/// the same while the picture grows gently out of its background (and settles back at the end). Times are the
/// recording's own. Windows and Linux follow the same rules (shared/transitions.js) and share the test cases.
public enum VideoTransition {
    public static let styles = ["none", "fade", "rise"]
    public static let duration = 0.6
    public static let rise = 0.08
    private static func ease(_ x: Double) -> Double { let v = min(1, max(0, x)); return v*v*(3-2*v) }
    public static func length(start: Double, end: Double) -> Double { min(duration, max(0, end-start)/3) }

    /// Level 0 to 1 for the picture's opacity and the sound's volume, and the picture's scale, at `time`.
    public static func at(_ time: Double, start: Double, end: Double, opening: String, closing: String) -> (level: Double, scale: Double) {
        let d = length(start: start, end: end)
        let inside = opening != "none" && styles.contains(opening) && d > 0 ? ease((time-start)/d) : 1
        let outside = closing != "none" && styles.contains(closing) && d > 0 ? ease((end-time)/d) : 1
        let level = min(inside, outside), style = inside <= outside ? opening : closing
        return (level, style == "rise" ? 1-rise*(1-level) : 1)
    }
}

/// Tighten Pauses: long silences found in a recording's sound, as cuts. A stretch is silent when it's well under the
/// speaking level (25 dB below the loud end, between -60 and -30 dB); one longer than `minimum` seconds becomes a cut
/// that leaves `keep` seconds of quiet each side, so speech isn't clipped. Windows and Linux follow the same rules
/// (shared/trim.js `pauses`) and share the test cases.
public enum AudioPauses {
    public static func find(levels: [Double], step: Double, start: Double, end: Double, minimum: Double = 1, keep: Double = 0.3) -> [VideoCut] {
        let loud = levels.filter(\.isFinite).sorted()
        guard !loud.isEmpty else { return [] }
        let speaking = loud[Int(Double(loud.count) * 0.9)]
        let threshold = min(-30, max(-60, speaking - 25))
        var found: [VideoCut] = [], begin: Int?
        for (index, level) in levels.enumerated() {
            let quiet = !(level > threshold)
            if quiet, begin == nil { begin = index }
            if (!quiet || index == levels.count - 1), let from = begin {
                let to = quiet ? index + 1 : index
                let a = Double(from) * step, b = Double(to) * step
                if b - a >= minimum { found.append(VideoCut(start: a + keep, end: b - keep)) }
                begin = nil
            }
        }
        return VideoTimeline.normalized(found, start: start, end: end)
    }

    /// Loudness in decibels for each `step` seconds of mono samples.
    public static func levels(_ samples: [Float], rate: Double, step: Double = 0.05) -> [Double] {
        let size = max(1, Int((rate * step).rounded()))
        return stride(from: 0, to: samples.count, by: size).map { at in
            let end = min(samples.count, at + size)
            let sum = samples[at..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (sum / Double(max(1, end - at))).squareRoot()
            return rms > 0 ? 20 * log10(rms) : -120
        }
    }
}
