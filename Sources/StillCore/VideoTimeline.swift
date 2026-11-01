import Foundation
import CoreGraphics

/// A stretch cut out of the middle of a recording, in the recording's own time.
public struct VideoCut: Codable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    /// For a fast-forward, or a kept stretch inside one: how many times faster it plays (2, 4 or 8); nil plays as recorded.
    public var rate: Double?
    public init(start: Double, end: Double, rate: Double? = nil) { self.start = start; self.end = end; self.rate = rate }
    /// How long it lasts in the finished video.
    public var played: Double { (end - start) / (rate ?? 1) }
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

    // Fast-forwards: stretches that play 2, 4 or 8 times faster. Kept sorted, inside the clip, at least `minimumSkim`
    // long, never overlapping (a later one starts where an earlier one ends). Same rules as shared/trim.js.
    public static let minimumSkim = 0.5, skimRates: [Double] = [2, 4, 8]

    public static func normalizedSkims(_ skims: [VideoCut], start: Double, end: Double) -> [VideoCut] {
        let clamp = { (t: Double) in min(end, max(start, t)) }
        let sorted = skims.map { VideoCut(start: clamp($0.start), end: clamp($0.end), rate: skimRates.contains($0.rate ?? 0) ? $0.rate : 4) }
            .filter { $0.start.isFinite && $0.end.isFinite }.sorted { $0.start < $1.start }
        var out: [VideoCut] = []
        for var skim in sorted { if let last = out.last, skim.start < last.end { skim.start = last.end }; if skim.end - skim.start >= minimumSkim { out.append(skim) } }
        return out
    }

    /// A new fast-forward from `time`, five seconds long or to the end of the clip or the next one.
    public static func addingSkim(_ skims: [VideoCut], at time: Double, start: Double, end: Double, rate: Double = 4) -> [VideoCut] {
        let list = normalizedSkims(skims, start: start, end: end)
        if list.contains(where: { time >= $0.start && time < $0.end }) { return list }
        let next = list.first { $0.start > time }?.start ?? .infinity
        return normalizedSkims(list + [VideoCut(start: time, end: min(end, time + 5, next), rate: rate)], start: start, end: end)
    }

    public static func skimRate(at time: Double, skims: [VideoCut]) -> Double {
        skims.first { time >= $0.start && time < $0.end }?.rate ?? 1
    }

    /// The stretches that stay, in order. With fast-forwards they're split where one starts or ends, and the parts
    /// inside one carry its rate.
    public static func kept(start: Double, end: Double, cuts: [VideoCut], skims: [VideoCut] = []) -> [VideoCut] {
        var out: [VideoCut] = [], at = start
        for cut in normalized(cuts, start: start, end: end) { if cut.start > at { out.append(VideoCut(start: at, end: cut.start)) }; at = max(at, cut.end) }
        if end > at { out.append(VideoCut(start: at, end: end)) }
        let fast = normalizedSkims(skims, start: start, end: end)
        guard !fast.isEmpty else { return out }
        var split: [VideoCut] = []
        for k in out {
            var from = k.start
            for f in fast where f.end > from && f.start < k.end {
                if f.start > from { split.append(VideoCut(start: from, end: f.start)) }
                let stop = min(k.end, f.end); split.append(VideoCut(start: max(from, f.start), end: stop, rate: f.rate)); from = stop
            }
            if k.end - from > 1e-9 { split.append(VideoCut(start: from, end: k.end)) }
        }
        return split
    }

    public static func length(_ kept: [VideoCut]) -> Double { kept.reduce(0) { $0 + $1.played } }

    /// The recording's time at a moment of the finished video.
    public static func sourceTime(at time: Double, kept: [VideoCut]) -> Double {
        var left = max(0, time)
        for segment in kept { let length = segment.played; if left <= length { return segment.start + left * (segment.rate ?? 1) }; left -= length }
        return kept.last?.end ?? 0
    }

    /// The finished video's time at a moment of the recording; a time inside a cut counts from where the cut ends.
    public static func outputTime(at time: Double, kept: [VideoCut]) -> Double {
        var before = 0.0
        for segment in kept {
            if time < segment.start { return before }
            if time <= segment.end { return before + (time - segment.start) / (segment.rate ?? 1) }
            before += segment.played
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

    /// Where someone is speaking: stretches above the speaking threshold, joined across gaps shorter than `gap` and
    /// padded by `pad` each side. Windows and Linux use the same rule (shared/trim.js `speech`).
    public static func speech(levels: [Double], step: Double, gap: Double = 0.4, pad: Double = 0.2) -> [VideoCut] {
        let loud = levels.filter(\.isFinite).sorted()
        guard !loud.isEmpty else { return [] }
        let threshold = min(-30, max(-60, loud[Int(Double(loud.count) * 0.9)] - 25))
        var out: [VideoCut] = [], begin: Int?
        for (index, level) in levels.enumerated() {
            let talking = level > threshold
            if talking, begin == nil { begin = index }
            if (!talking || index == levels.count - 1), let from = begin {
                let start = max(0, Double(from) * step - pad), end = Double(talking ? index + 1 : index) * step + pad
                if let last = out.last, start - last.end < gap { out[out.count-1].end = end } else { out.append(VideoCut(start: start, end: end)) }
                begin = nil
            }
        }
        return out
    }
    /// The music's share of its volume at `time`: `low` while someone speaks, easing over `ramp` seconds either side.
    public static func duck(_ time: Double, ranges: [VideoCut], low: Double = 0.3, ramp: Double = 0.15) -> Double {
        var level = 1.0
        for r in ranges {
            let into = min(time - (r.start - ramp), (r.end + ramp) - time)
            guard into > 0 else { continue }
            level = min(level, into >= ramp ? low : 1 - (1 - low) * (into / ramp))
        }
        return level
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

/// A part of a video's picture blurred for a stretch of the recording (in its own time). The box is kept as shares of
/// the video (0 to 1, from the top left) so it fits any export size and follows the picture through zooms. Windows
/// and Linux follow the same rules (shared/blurs.js) and share the test cases.
public struct VideoBlur: Codable, Equatable, Hashable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var x: Double, y: Double, w: Double, h: Double
    public init(start: Double, end: Double, x: Double = 0.35, y: Double = 0.42, w: Double = 0.3, h: Double = 0.16) {
        self.start = start; self.end = end
        let fitted = Self.fit(x: x, y: y, w: w, h: h); self.x = fitted.x; self.y = fitted.y; self.w = fitted.w; self.h = fitted.h
    }
    /// A box kept inside the picture and at least 1% each way.
    public static func fit(x: Double, y: Double, w: Double, h: Double) -> (x: Double, y: Double, w: Double, h: Double) {
        let fw = min(1, max(0.01, abs(w))), fh = min(1, max(0.01, abs(h)))
        return (min(1-fw, max(0, w < 0 ? x+w : x)), min(1-fh, max(0, h < 0 ? y+h : y)), fw, fh)
    }
    /// A new box at `time`, three seconds long and kept inside the clip.
    public static func new(at time: Double, start: Double, end: Double) -> VideoBlur { VideoBlur(start: max(start, time), end: min(end, time+3)) }
    /// A box in the video's pixels (from the top left), as shares, with a little room around it.
    public static func fromPixels(_ box: CGRect, width: Double, height: Double, at time: Double, start: Double, end: Double, pad: Double = 4) -> VideoBlur {
        VideoBlur(start: max(start, time), end: min(end, time+3), x: (box.minX-pad)/width, y: (box.minY-pad)/height, w: (box.width+pad*2)/width, h: (box.height+pad*2)/height)
    }
}

/// A named marker on a recording, at a moment of its own time.
public struct VideoChapter: Codable, Equatable, Hashable, Identifiable {
    public var id = UUID()
    public var time: Double
    public var title: String
    public init(time: Double, title: String) { self.time = time; self.title = title }
}

/// Chapters and the list they make for a video's description ("0:00 Intro", "1:23 Setting up"), timed to the finished
/// video after trimming, cuts and export speed, and starting at 0:00 as video sites expect. Windows and Linux follow
/// the same rules (shared/chapters.js) and share the test cases.
public enum VideoChapters {
    public static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int((seconds + 1e-6).rounded(.down))), h = s/3600, m = s/60 % 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
    public static func list(_ chapters: [VideoChapter], start: Double, end: Double, cuts: [VideoCut], speed: Double = 1, skims: [VideoCut] = []) -> String {
        let kept = VideoTimeline.kept(start: start, end: end, cuts: cuts, skims: skims)
        var rows: [(at: Int, title: String)] = []
        for chapter in chapters.sorted(by: { $0.time < $1.time }) {
            guard chapter.time >= start, chapter.time <= end, !cuts.contains(where: { chapter.time >= $0.start && chapter.time < $0.end }) else { continue }
            let at = Int((VideoTimeline.outputTime(at: chapter.time, kept: kept) / max(1, speed) + 1e-6).rounded(.down))
            let words = chapter.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let title = words.isEmpty ? "Chapter" : words
            if let last = rows.last, last.at == at { rows[rows.count-1].title = title } else { rows.append((at, title)) }
        }
        guard !rows.isEmpty else { return "" }
        if rows[0].at > 0 { rows.insert((0, "Intro"), at: 0) }
        return rows.map { "\(stamp(Double($0.at))) \($0.title)" }.joined(separator: "\n")
    }

    // Find Chapters: where the screen changes, named from what it says. Same rules as shared/chapters.js.

    /// How different two small greyscale pictures are, 0 (the same) to 1 (black to white everywhere).
    public static func difference(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var sum = 0.0; for i in 0..<n { sum += abs(a[i] - b[i]) }
        return sum / Double(n) / 255
    }

    /// The moments the picture changes a lot: `changes[i]` is the difference between the pictures at start + i*step
    /// and start + (i+1)*step. A change counts when it stands six median deviations above the median (and at least
    /// `floor`); of changes closer than `gap` seconds the bigger one wins; nothing in the first two seconds.
    public static func scenes(_ changes: [Double], step: Double, gap: Double = 10, floor: Double = 0.08, start: Double = 0) -> [Double] {
        let values = changes.filter { $0.isFinite }
        guard !values.isEmpty else { return [] }
        let middle = { (list: [Double]) in list.sorted()[list.count / 2] }
        let median = middle(values), spread = middle(values.map { abs($0 - median) })
        let threshold = max(floor, median + 6 * spread)
        var peaks: [(time: Double, v: Double)] = []
        for (i, v) in changes.enumerated() {
            let before = i > 0 ? changes[i-1] : 0, after = i + 1 < changes.count ? changes[i+1] : 0
            guard v >= threshold, v >= before, v >= after else { continue }
            let time = start + Double(i + 1) * step
            if time - start >= 2 { peaks.append((time, v)) }
        }
        var kept: [Double] = []
        for p in peaks.sorted(by: { $0.v != $1.v ? $0.v > $1.v : $0.time < $1.time }) where kept.allSatisfy({ abs($0 - p.time) >= gap }) { kept.append(p.time) }
        return kept.sorted()
    }

    /// A chapter's name from the lines of text on screen: the line in the largest type that reads like a title
    /// (three letters or more, mostly letters, up to 60 characters), the higher one on a tie, without trailing
    /// separators and shortened at a word past 40 characters. "" when nothing fits.
    public static func pickTitle(_ rows: [(text: String, top: Double, height: Double)]) -> String {
        let separators: Set<Character> = [" ", ":", "|", "•", "·", "–", "—", "-"]
        let fits = rows.compactMap { row -> (text: String, top: Double, height: Double)? in
            var text = row.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            while let last = text.last, separators.contains(last) { text.removeLast() }
            let letters = text.filter(\.isLetter).count
            guard letters >= 3, Double(letters) / Double(max(1, text.count)) >= 0.5, text.count <= 60 else { return nil }
            return (text, row.top, row.height)
        }
        guard let best = fits.sorted(by: { $0.height != $1.height ? $0.height > $1.height : $0.top < $1.top }).first?.text else { return "" }
        guard best.count > 40 else { return best }
        let cut = String(best.prefix(40))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 20 { return String(cut[..<space]).trimmingCharacters(in: .whitespaces) + "…" }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Background music for a recording: a file copied in beside it, its volume (0 to 1), whether it dips while someone
/// speaks, and where the speech is (in the recording's own time, found once when the music is added).
public struct VideoMusic: Codable, Equatable, Hashable {
    public var filename: String
    public var name: String
    public var volume: Double
    public var duck: Bool
    public var speech: [VideoCut]
    public init(filename: String, name: String, volume: Double = 0.3, duck: Bool = true, speech: [VideoCut] = []) {
        self.filename = filename; self.name = name; self.volume = volume; self.duck = duck; self.speech = speech
    }
}

/// An arrow, a box or a spotlight shown over a video for a stretch of the recording (in its own time). Places are
/// shares of the video (0 to 1, from the top left); an arrow's tip is (x, y) and its tail (x2, y2). Windows and Linux
/// follow the same rules (shared/callouts.js) and share the test cases.
public struct VideoCallout: Codable, Equatable, Hashable, Identifiable {
    public var id = UUID()
    public var kind: String
    public var start: Double
    public var end: Double
    public var color: String
    public var x: Double, y: Double
    public var x2: Double?, y2: Double?
    public var w: Double?, h: Double?
    public static let kinds = ["arrow", "box", "spotlight"]
    public static let colors = ["FF453A", "FFD60A", "32D74B", "0A84FF", "FFFFFF"]

    /// A new callout at `time`, three seconds long, in the middle until it's placed somewhere else.
    public static func new(_ kind: String, at time: Double, start: Double, end: Double) -> VideoCallout {
        kind == "arrow"
            ? VideoCallout(kind: kind, start: max(start, time), end: min(end, time + 3), color: colors[0], x: 0.5, y: 0.5, x2: 0.38, y2: 0.36)
            : VideoCallout(kind: kind, start: max(start, time), end: min(end, time + 3), color: colors[0], x: 0.35, y: 0.35, w: 0.3, h: 0.3)
    }
    /// How opaque it is at `time` (0 to 1), or nil when it isn't showing; it fades in and out over 0.2 s.
    public func alpha(at time: Double) -> Double? {
        guard time >= start, time <= end else { return nil }
        let ramp = min(0.2, (end - start) / 3)
        return ramp > 0 ? min(1, (time - start) / ramp, (end - time) / ramp) : 1
    }
    /// An arrow for each recorded click inside the clip: from 0.4 s before it to 1.2 s after, its tail up and to the
    /// left (or wherever there's room). Clicks within a second of the last are skipped.
    public static func fromClicks(_ clicks: [ClickSample], start: Double, end: Double) -> [VideoCallout] {
        var out: [VideoCallout] = [], last = -Double.infinity
        let clamp = { (v: Double) in min(1, max(0, v)) }
        for click in clicks where click.time >= start && click.time <= end && click.time - last >= 1 {
            last = click.time
            let dx = click.x > 0.2 ? -0.12 : 0.12, dy = click.y > 0.2 ? -0.12 : 0.12
            out.append(VideoCallout(kind: "arrow", start: max(start, click.time - 0.4), end: min(end, click.time + 1.2), color: colors[0], x: clamp(click.x), y: clamp(click.y), x2: clamp(click.x + dx), y2: clamp(click.y + dy)))
        }
        return out
    }
}

/// Storyboard: one picture of a whole video, a grid of frames each labelled with its time in the finished video (and
/// its chapter's name when there are chapters). Windows and Linux follow the same rules (shared/storyboard.js) and
/// share the test cases.
public enum VideoStoryboard {
    public struct Frame: Equatable { public var time: Double; public var label: String }
    public struct Layout: Equatable { public var cols, rows: Int; public var tileWidth, tileHeight, strip, gap, width, height: Double }

    /// 0:03.4: tenths, for short videos where whole seconds would repeat.
    public static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    public static func frames(start: Double, end: Double, cuts: [VideoCut], chapters: [VideoChapter], count: Int = 12, max limit: Int = 24, speed: Double = 1, skims: [VideoCut] = []) -> [Frame] {
        let kept = VideoTimeline.kept(start: start, end: end, cuts: cuts, skims: skims), total = VideoTimeline.length(kept)
        guard total > 0 else { return [] }
        let time = { (t: Double) -> String in
            let at = VideoTimeline.outputTime(at: t, kept: kept) / max(1, speed)
            return total / max(1, speed) < 20 ? clock(at) : VideoChapters.stamp(at)
        }
        let inside = chapters.filter { c in c.time >= start && c.time <= end && !cuts.contains { c.time >= $0.start && c.time < $0.end } }.sorted { $0.time < $1.time }
        if !inside.isEmpty {
            return inside.prefix(limit).map { c in
                let name = c.title.trimmingCharacters(in: .whitespaces)
                return Frame(time: min(end - 0.05, c.time + 0.05), label: name.isEmpty ? time(c.time) : "\(time(c.time))  \(name)")
            }
        }
        let n = Swift.max(1, Swift.min(limit, count))
        return (0..<n).map { i in let t = VideoTimeline.sourceTime(at: total * (Double(i) + 0.5) / Double(n), kept: kept); return Frame(time: t, label: time(t)) }
    }

    public static func layout(_ n: Int, width: Double, height: Double, tile: Double = 480, columns: Int = 4, gap: Double = 16, strip: Double = 34) -> Layout {
        let cols = max(1, min(columns, n)), rows = Int((Double(n) / Double(cols)).rounded(.up))
        let th = (tile * height / max(1, width)).rounded()
        return Layout(cols: cols, rows: rows, tileWidth: tile, tileHeight: th, strip: strip, gap: gap, width: Double(cols) * tile + Double(cols + 1) * gap, height: Double(rows) * (th + strip) + Double(rows + 1) * gap)
    }
}
