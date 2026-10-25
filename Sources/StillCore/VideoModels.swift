import Foundation
import CoreGraphics

public struct PointerSample: Codable { public var time: Double; public var x: Double; public var y: Double; public init(time: Double, x: Double, y: Double) { self.time = time; self.x = x; self.y = y } }
public struct ClickSample: Codable { public var time: Double; public var x: Double; public var y: Double; public init(time: Double, x: Double, y: Double) { self.time = time; self.x = x; self.y = y } }
public struct KeySample: Codable { public var time: Double; public var text: String; public init(time: Double, text: String) { self.time = time; self.text = text } }
public struct RecordingMetadata: Codable {
    public var pointer: [PointerSample] = []
    public var clicks: [ClickSample] = []
    public var keys: [KeySample] = []
    public var cursorIncludedInVideo = true
    public var defaultShowCursor = true
    public var defaultShowClicks = false
    public var defaultShowKeystrokes = false
    public var cameraFilename: String?
    public var cameraOffset: Double = 0
    public var transcript: String?
    public var captions: String?
    public var presentation: VideoSettings?
    public init() {}
    private enum CodingKeys: String, CodingKey { case pointer, clicks, keys, cursorIncludedInVideo, defaultShowCursor, defaultShowClicks, defaultShowKeystrokes, cameraFilename, cameraOffset, transcript, captions, presentation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pointer = try c.decodeIfPresent([PointerSample].self, forKey: .pointer) ?? []
        clicks = try c.decodeIfPresent([ClickSample].self, forKey: .clicks) ?? []
        keys = try c.decodeIfPresent([KeySample].self, forKey: .keys) ?? []
        cursorIncludedInVideo = try c.decodeIfPresent(Bool.self, forKey: .cursorIncludedInVideo) ?? true
        defaultShowCursor = try c.decodeIfPresent(Bool.self, forKey: .defaultShowCursor) ?? true
        defaultShowClicks = try c.decodeIfPresent(Bool.self, forKey: .defaultShowClicks) ?? false
        defaultShowKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .defaultShowKeystrokes) ?? false
        cameraFilename = try c.decodeIfPresent(String.self, forKey: .cameraFilename)
        cameraOffset = try c.decodeIfPresent(Double.self, forKey: .cameraOffset) ?? 0
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        captions = try c.decodeIfPresent(String.self, forKey: .captions)
        presentation = try c.decodeIfPresent(VideoSettings.self, forKey: .presentation)
    }
}
public struct ZoomSegment: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var scale: Double
    public var x: Double
    public var y: Double
    public init(start: Double, end: Double, scale: Double = 1.7, x: Double = 0.5, y: Double = 0.5) { self.start = start; self.end = end; self.scale = scale; self.x = x; self.y = y }
}
public struct VideoSettings: Codable, Equatable {
    public var start: Double = 0
    public var end: Double = 0
    public var frame = "none"
    public var padding: Double = 64
    public var radius: Double = 18
    public var shadow: Double = 24
    public var aspect: Double = 0
    public var muted = false
    public var cursorScale: Double = 1
    public var cursorStyle = "arrow"
    public var smoothCursor = true
    public var showClicks = true
    public var clickColor = "FF485E"
    public var showKeystrokes = true
    public var cameraEnabled = true
    public var cameraSize: Double = 0.22
    public var cameraShape = "circle"
    public var cameraX: Double = 0.97
    public var cameraY: Double = 0.97
    public var motionBlur: Double = 0
    public var clickSize: Double?
    public var clickStyle: String?
    public var clickAnimated: Bool?
    public var keysSize: Double?
    public var keysStyle: String?
    public var keysX: Double?
    public var keysY: Double?
    public var cameraFullscreen: Bool?
    public var cameraMirror: Bool?
    public var quality: String?
    public var fps = 30
    public var zooms: [ZoomSegment] = []
    public init() {}
}
