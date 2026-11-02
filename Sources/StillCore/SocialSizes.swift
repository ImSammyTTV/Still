import CoreGraphics

/// Sizes for social media: picking one in the crop tool locks the crop to its shape, and the crop is then scaled to
/// exactly that many pixels. A size can name a safe area, the middle part every device shows (a YouTube banner is cut
/// down to a strip on phones). Follows the same list and rules as Desktop/web/shared/sizes.js, and shares its tests.
public enum SocialSizes {
    public struct Size: Hashable, Identifiable {
        public let id: String, group: String, name: String, width: Int, height: Int
        public var safe: CGSize?
        public var aspect: Double { Double(width)/Double(height) }
        public var title: String { "\(group) \(name)" }
        public static func == (a: Size, b: Size) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    public static let all: [Size] = [
        Size(id: "yt-thumb", group: "YouTube", name: "Thumbnail", width: 1280, height: 720),
        Size(id: "yt-banner", group: "YouTube", name: "Channel Banner", width: 2560, height: 1440, safe: CGSize(width: 1546, height: 423)),
        Size(id: "ig-square", group: "Instagram", name: "Square Post", width: 1080, height: 1080),
        Size(id: "ig-portrait", group: "Instagram", name: "Portrait Post", width: 1080, height: 1350),
        Size(id: "ig-story", group: "Instagram", name: "Story or Reel", width: 1080, height: 1920),
        Size(id: "tiktok", group: "TikTok", name: "Video Cover", width: 1080, height: 1920),
        Size(id: "x-post", group: "X", name: "Post", width: 1600, height: 900),
        Size(id: "x-header", group: "X", name: "Header", width: 1500, height: 500),
        Size(id: "fb-post", group: "Facebook", name: "Link Post", width: 1200, height: 630),
        Size(id: "fb-cover", group: "Facebook", name: "Cover", width: 851, height: 315),
        Size(id: "li-post", group: "LinkedIn", name: "Post", width: 1200, height: 627),
        Size(id: "li-banner", group: "LinkedIn", name: "Banner", width: 1584, height: 396),
        Size(id: "twitch", group: "Twitch", name: "Profile Banner", width: 1200, height: 480),
        Size(id: "discord", group: "Discord", name: "Server Banner", width: 960, height: 540),
        Size(id: "pinterest", group: "Pinterest", name: "Pin", width: 1000, height: 1500),
    ]
    /// The groups in list order, for menus.
    public static var groups: [String] { all.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }
    public static func size(id: String) -> Size? { all.first { $0.id == id } }

    /// The largest rectangle of this shape (width / height) that fits `bounds`, in its middle.
    public static func centered(in bounds: CGRect, aspect: Double) -> CGRect {
        var w = Double(bounds.width), h = w/aspect
        if h > Double(bounds.height) { h = Double(bounds.height); w = h*aspect }
        return CGRect(x: Double(bounds.minX)+(Double(bounds.width)-w)/2, y: Double(bounds.minY)+(Double(bounds.height)-h)/2, width: w, height: h)
    }
    /// A rectangle of this shape dragged from `from` towards `to`. Its far corner follows the pointer along the shape's
    /// diagonal (the nearest point on it), so moving either way grows or shrinks it, and it never goes past `bounds`.
    public static func dragged(from: CGPoint, to: CGPoint, aspect: Double, within bounds: CGRect) -> CGRect {
        let right = to.x >= from.x, down = to.y >= from.y
        let roomX = Double(right ? bounds.maxX-from.x : from.x-bounds.minX), roomY = Double(down ? bounds.maxY-from.y : from.y-bounds.minY)
        var w = aspect*(abs(Double(to.x-from.x))*aspect+abs(Double(to.y-from.y)))/(aspect*aspect+1)
        w = min(w, roomX, roomY*aspect)
        let h = w/aspect
        return CGRect(x: right ? Double(from.x) : Double(from.x)-w, y: down ? Double(from.y) : Double(from.y)-h, width: w, height: h)
    }
    /// Where a size's safe area falls inside a crop of its shape.
    public static func safeArea(in crop: CGRect, size: Size) -> CGRect? {
        guard let safe = size.safe else { return nil }
        let w = crop.width*safe.width/CGFloat(size.width), h = crop.height*safe.height/CGFloat(size.height)
        return CGRect(x: crop.midX-w/2, y: crop.midY-h/2, width: w, height: h)
    }
    /// A short note: the size the picture comes out at, and whether it has to grow to get there.
    public static func note(crop: CGRect, size: Size) -> String {
        "\(size.width) × \(size.height)" + (crop.width+0.5 < CGFloat(size.width) ? " · enlarged, may look soft" : "")
    }
}
