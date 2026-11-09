import CoreGraphics

/// Window selection: the wheel steps from a whole window into the parts of it under the pointer (a browser's page
/// without its tabs and toolbar, a pane) and back out. Follows Desktop/web/shared/geometry.js (windowPartAt,
/// bandParts) and Desktop/src-tauri/src/capture.rs (useful_parts), and shares their test cases.
public enum WindowParts {
    /// Depth 0 is the whole window; each step goes one part smaller. Returns what is selected and how deep it can go.
    public static func part(of window: CGRect, parts: [CGRect], at point: CGPoint, depth: Int) -> (rect: CGRect, depth: Int, deepest: Int) {
        let under = parts.filter { $0.contains(point) }.sorted { $0.width * $0.height > $1.width * $1.height }
        let d = max(0, min(depth, under.count))
        return (d == 0 ? window : under[d - 1], d, under.count)
    }

    /// Which rectangles (from the system) are worth offering: big enough to want on their own, inside the window,
    /// not (nearly) the whole window, each only once, at most 40, largest first.
    public static func useful(_ children: [CGRect], in window: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        for child in children {
            let r = child.intersection(window)
            guard !r.isNull, r.width >= 80, r.height >= 60, r.width * r.height <= window.width * window.height * 0.95 else { continue }
            if !out.contains(where: { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }) { out.append(r) }
        }
        return Array(out.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(40))
    }

    /// Parts found from the window's picture, for when the system can't say what's inside it: the long straight lines
    /// across the whole window near its top, where a title bar, tab strip or toolbar ends and the page begins. One part
    /// per line, each the window below it, largest first. `luminance(x, y)` is 0–255; sizes are in pixels.
    public static func bands(width: Int, height: Int, luminance: (Int, Int) -> Double) -> [CGRect] {
        guard width >= 120, height >= 120 else { return [] }
        let step = max(1, width / 400)
        let columns = Array(stride(from: Int(Double(width) * 0.02), to: Int((Double(width) * 0.98).rounded(.up)), by: step))
        var lines: [Int] = []
        var y = 4
        while Double(y) < Double(height) * 0.45 && lines.count < 4 {
            let edges = columns.filter { abs(luminance($0, y) - luminance($0, y - 1)) > 18 }.count
            if Double(edges) >= Double(columns.count) * 0.9, lines.last.map({ y - $0 > 6 }) ?? true { lines.append(y) }
            y += 1
        }
        return lines.filter { Double(height - $0) >= Double(height) * 0.4 }.map { CGRect(x: 0, y: $0, width: width, height: height - $0) }
    }
}
