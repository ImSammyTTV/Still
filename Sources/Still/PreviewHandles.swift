import SwiftUI
import StillCore

/// Drag handles over the video preview, so blurs and callouts are placed on the picture itself rather than with
/// sliders (the sliders stay in the inspector for fine adjustment). A drag saves as it goes, like a slider, so the
/// blur follows even if the system never reports the end of the drag; the whole drag is still one undo step. Boxes are shares of the recording's own
/// picture, which `VideoGeometry` finds inside the frame through padding and zoom.
struct PreviewHandles: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        GeometryReader { geo in
            let frame = VideoGeometry.fitted(model.outputSize, in: geo.size)
            let picture = VideoGeometry.pictureRect(output: model.outputSize, source: model.sourceSize, padding: model.settings.frame == "none" ? 0 : model.settings.padding, zooms: model.settings.zooms, time: model.playhead)
            let k = frame.width/max(1, model.outputSize.width)
            let screen = CGRect(x: frame.minX+picture.minX*k, y: frame.minY+picture.minY*k, width: picture.width*k, height: picture.height*k)
            ZStack(alignment: .topLeading) {
                Color.clear
                if model.panel == "Blur", model.outputSize.width > 0 {
                    ForEach(model.settings.blurs ?? []) { blur in
                        if model.playhead >= blur.start && model.playhead <= blur.end {
                            BoxHandles(box: blur.box(at: model.playhead), screen: screen, tint: .white, label: blur.keys == nil ? nil : "keyframed") { box in
                                model.liveEdit(); model.updateBlur(blur.id) { $0 = $0.placing(at: model.playhead, box) }
                            }
                        }
                    }
                }
                if model.panel == "Zoom", model.outputSize.width > 0,
                   let zoom = model.settings.zooms.first(where: { model.playhead >= $0.start && model.playhead <= $0.end && (model.pickedZooms.isEmpty || model.pickedZooms.contains($0.id)) }) {
                    // Where the zoom points: drag the marker, or click the picture, to choose it.
                    ZoomFocusHandle(point: CGPoint(x: zoom.x, y: zoom.y), screen: screen) { p in
                        model.liveEdit(); if let i = model.settings.zooms.firstIndex(where: { $0.id == zoom.id }) { model.settings.zooms[i].x = Double(p.x); model.settings.zooms[i].y = Double(p.y) }
                    }
                }
                if model.panel == "Text", model.outputSize.width > 0 {
                    // Captions sit on the video area itself, steady through zooms, so they use the unzoomed picture.
                    let plain = VideoGeometry.pictureRect(output: model.outputSize, source: model.sourceSize, padding: model.settings.frame == "none" ? 0 : model.settings.padding, zooms: [], time: model.playhead)
                    let area = CGRect(x: frame.minX+plain.minX*k, y: frame.minY+plain.minY*k, width: plain.width*k, height: plain.height*k)
                    ForEach(model.settings.captions ?? []) { caption in
                        if caption.alpha(at: model.playhead) != nil {
                            CaptionHandle(caption: caption, area: area) { moved in
                                model.liveEdit(); if let i = model.settings.captions?.firstIndex(where: { $0.id == caption.id }) { model.settings.captions?[i] = moved }
                            }
                        }
                    }
                }
                if model.panel == "Callouts", model.outputSize.width > 0 {
                    ForEach(model.settings.callouts ?? []) { stored in
                        if model.playhead >= stored.start && model.playhead <= stored.end {
                            // A keyed callout is shown and moved where it is at the playhead; the move becomes a keyframe.
                            let callout = stored.shape(at: model.playhead), t = model.playhead
                            if callout.kind == "arrow" {
                                ArrowHandles(tip: CGPoint(x: callout.x, y: callout.y), tail: CGPoint(x: callout.x2 ?? 0.38, y: callout.y2 ?? 0.36), screen: screen) { tip, tail in
                                    model.liveEdit(); model.updateCallout(stored.id) { $0 = $0.placing(at: t) { $0.x = tip.x; $0.y = tip.y; $0.x2 = tail.x; $0.y2 = tail.y } }
                                }
                            } else {
                                BoxHandles(box: CGRect(x: callout.x, y: callout.y, width: callout.w ?? 0.3, height: callout.h ?? 0.3), screen: screen, tint: Color(nsColor: NSColor(hex: callout.color)), label: stored.keys == nil ? nil : "keyframed") { box in
                                    model.liveEdit(); model.updateCallout(stored.id) { $0 = $0.placing(at: t) { $0.x = box.minX; $0.y = box.minY; $0.w = box.width; $0.h = box.height } }
                                }
                            }
                        }
                    }
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }
    }
}

/// A box with a handle on each corner: drag a corner to resize it from the opposite one, drag inside to move it.
struct BoxHandles: View {
    let box: CGRect, screen: CGRect, tint: Color, label: String?
    let commit: (CGRect) -> Void
    /// The box when this drag began; the gesture resets it by itself when the drag ends or is cancelled.
    @GestureState private var origin: CGRect?

    var body: some View {
        let b = box
        let r = CGRect(x: screen.minX+b.minX*screen.width, y: screen.minY+b.minY*screen.height, width: b.width*screen.width, height: b.height*screen.height)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .frame(width: max(1, r.width), height: max(1, r.height)).position(x: r.midX, y: r.midY)
                .gesture(drag("move")).onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .help(label == nil ? "Drag to move; drag a corner to resize" : "Drag to move or resize; this sets a keyframe at the playhead")
            ForEach(["nw", "ne", "sw", "se"], id: \.self) { corner in
                Circle().fill(.white).overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1)).frame(width: 12, height: 12)
                    .contentShape(Circle().inset(by: -6))
                    .position(x: corner.contains("w") ? r.minX : r.maxX, y: corner.contains("n") ? r.minY : r.maxY)
                    .gesture(drag(corner)).accessibilityLabel("Resize")
            }
        }
    }
    private func drag(_ handle: String) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($origin) { v, start, _ in
                if start == nil { start = box }
                let moved = VideoBlur.dragged(start ?? box, handle: handle, dx: Double(v.translation.width/max(1, screen.width)), dy: Double(v.translation.height/max(1, screen.height)))
                DispatchQueue.main.async { commit(moved) }
            }
    }
}

/// The point a zoom is aimed at, as a target on the picture. Drag it, or click anywhere on the picture, to move it.
/// The picture moves under it as the zoom re-aims, so a drag works from where the picture was when it began.
struct ZoomFocusHandle: View {
    let point: CGPoint, screen: CGRect
    let commit: (CGPoint) -> Void
    @GestureState private var origin: (CGPoint, CGRect)?

    var body: some View {
        let clamp = { (p: CGPoint) in CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))) }
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: screen.width, height: screen.height)
                .gesture(SpatialTapGesture().onEnded { v in commit(clamp(CGPoint(x: v.location.x/max(1, screen.width), y: v.location.y/max(1, screen.height)))) })
                .position(x: screen.midX, y: screen.midY)
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 2).frame(width: 26, height: 26)
                Circle().fill(.white).frame(width: 5, height: 5)
                Rectangle().fill(.white).frame(width: 1.5, height: 36); Rectangle().fill(.white).frame(width: 36, height: 1.5)
            }.shadow(color: .black.opacity(0.6), radius: 2).contentShape(Circle().inset(by: -8))
                .position(x: screen.minX+point.x*screen.width, y: screen.minY+point.y*screen.height)
                .gesture(DragGesture(minimumDistance: 1).updating($origin) { v, start, _ in
                    if start == nil { start = (point, screen) }
                    let (p, r) = start ?? (point, screen)
                    let moved = clamp(CGPoint(x: p.x+v.translation.width/max(1, r.width), y: p.y+v.translation.height/max(1, r.height)))
                    DispatchQueue.main.async { commit(moved) }
                })
                .help("Where the zoom points: drag this, or click the picture").accessibilityLabel("Zoom focus")
        }
    }
}

/// A caption's pill on the video: drag it to put the text anywhere (the Place menu puts it back at the top,
/// middle or bottom).
struct CaptionHandle: View {
    let caption: VideoCaption, area: CGRect
    let commit: (VideoCaption) -> Void
    @GestureState private var origin: VideoCaption?

    var body: some View {
        let at = caption.layout(width: Double(area.width), height: Double(area.height)), size = pillSize(at.fontSize)
        let c = VideoCaption.centre(x: at.x, y: at.y, boxWidth: Double(size.width), boxHeight: Double(size.height), width: Double(area.width), height: Double(area.height))
        let radius = CGFloat(min(Double(size.height)/2, at.fontSize*0.6))
        RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.001))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .frame(width: size.width, height: size.height).position(x: area.minX+CGFloat(c.x), y: area.minY+CGFloat(c.y))
            .gesture(DragGesture(minimumDistance: 1).updating($origin) { v, start, _ in
                if start == nil { start = caption }
                let moved = (start ?? caption).moved(dx: Double(v.translation.width/max(1, area.width)), dy: Double(v.translation.height/max(1, area.height)), width: Double(area.width), height: Double(area.height))
                DispatchQueue.main.async { commit(moved) }
            })
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .help("Drag to move the text").accessibilityLabel("Move text")
    }
    /// The pill's size, worked out the same way as the Windows and Linux editor's.
    private func pillSize(_ fontSize: Double) -> CGSize {
        let lines = caption.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).map(String.init)
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        let widest = lines.map { Double(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let text = min(Double(area.width)*0.9, widest)
        return CGSize(width: text+fontSize*1.6, height: fontSize*1.25*Double(max(1, lines.count))+fontSize*0.9)
    }
}

/// An arrow's two ends: drag the tip or the tail, or the line between them to move the whole arrow.
struct ArrowHandles: View {
    let tip: CGPoint, tail: CGPoint, screen: CGRect
    let commit: (CGPoint, CGPoint) -> Void
    @GestureState private var origin: [CGPoint]?

    var body: some View {
        let (t, s) = (tip, tail)
        let view = { (p: CGPoint) in CGPoint(x: screen.minX+p.x*screen.width, y: screen.minY+p.y*screen.height) }
        let a = view(t), b = view(s)
        ZStack(alignment: .topLeading) {
            Path { $0.move(to: a); $0.addLine(to: b) }.stroke(Color.white.opacity(0.001), lineWidth: 16).contentShape(Path { $0.move(to: a); $0.addLine(to: b) }.strokedPath(StrokeStyle(lineWidth: 16)))
                .gesture(drag { o, d in (moved(o[0], d), moved(o[1], d)) })
            Path { $0.move(to: a); $0.addLine(to: b) }.stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).allowsHitTesting(false)
            dot(at: a).gesture(drag { o, d in (moved(o[0], d), o[1]) }).accessibilityLabel("Arrow tip")
            dot(at: b).gesture(drag { o, d in (o[0], moved(o[1], d)) }).accessibilityLabel("Arrow tail")
        }
    }
    private func dot(at p: CGPoint) -> some View {
        Circle().fill(.white).overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1)).frame(width: 12, height: 12).contentShape(Circle().inset(by: -6)).position(p)
    }
    private func moved(_ p: CGPoint, _ d: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x+d.width/max(1, screen.width))), y: min(1, max(0, p.y+d.height/max(1, screen.height))))
    }
    private func drag(_ update: @escaping ([CGPoint], CGSize) -> (CGPoint, CGPoint)) -> some Gesture {
        DragGesture(minimumDistance: 1).updating($origin) { v, start, _ in
            if start == nil { start = [tip, tail] }
            let (a, b) = update(start ?? [tip, tail], v.translation)
            DispatchQueue.main.async { commit(a, b) }
        }
    }
}

/// Blur bars along the top of the timeline: drag either end to change when a blur starts or stops; diamonds are
/// its keyframes. A click on a bar moves the playhead into it.
struct BlurLane: View {
    @ObservedObject var model: VideoEditorModel
    let width: CGFloat, total: Double
    /// The blur as it was when this drag began; reset by the gesture itself.
    @GestureState private var origin: VideoBlur?

    var body: some View {
        let x = { (t: Double) in CGFloat(t/total)*width }
        ZStack(alignment: .topLeading) {
            ForEach(model.settings.blurs ?? []) { stored in
                let blur = stored
                let left = x(blur.start), w = max(8, x(blur.end)-x(blur.start))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.red.opacity(model.panel == "Blur" ? 0.75 : 0.45)).frame(width: w, height: 10)
                        .onTapGesture { model.panel = "Blur"; model.seek(blur.start+min(0.5, (blur.end-blur.start)/2)) }
                    ForEach(blur.keys ?? [], id: \.t) { key in
                        Rectangle().fill(.white).frame(width: 6, height: 6).rotationEffect(.degrees(45)).offset(x: x(key.t)-left-3).allowsHitTesting(false)
                    }
                    grip(blur, start: true).offset(x: -5)
                    grip(blur, start: false).offset(x: w-5)
                }.offset(x: left).help("Blur \(String(format: "%.2f", blur.start))–\(String(format: "%.2f", blur.end)) s: drag an end to retime it")
            }
        }.frame(width: width, alignment: .leading)
    }
    private func grip(_ blur: VideoBlur, start: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 10, height: 16)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 10))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0).updating($origin) { v, first, _ in
                if first == nil { first = blur }
                let base = first ?? blur, edge = start ? base.start : base.end
                let moved = base.retimed(start: start, to: edge+Double(v.translation.width/max(1, width))*total, clipStart: model.settings.start, clipEnd: model.settings.end)
                DispatchQueue.main.async { model.liveEdit(); model.updateBlur(moved.id) { $0.start = moved.start; $0.end = moved.end }; model.seek(start ? moved.start : moved.end) }
            })
            .accessibilityLabel(start ? "Blur start" : "Blur end")
    }
}
