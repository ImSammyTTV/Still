import Foundation

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
