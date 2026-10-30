import AppKit
import SwiftUI
import StillCore

struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> MarkCanvas { MarkCanvas(model: model) }
    func updateNSView(_ view: MarkCanvas, context: Context) { view.model = model; view.needsDisplay = true; view.window?.invalidateCursorRects(for: view) }
}

@MainActor
final class MarkCanvas: NSView {
    var model: EditorModel
    private var draft: Mark?
    private var start = CGPoint.zero
    private var tracking: NSTrackingArea?
    private var movingMark: Mark?
    private var resizing = false
    private var movingControl = false
    private var resizeAnchor = CGPoint.zero
    private var resizeCorner = CGPoint.zero
    private let previewCache = PreviewCache()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: EditorModel) { self.model = model; super.init(frame: .zero); setAccessibilityLabel("Annotation canvas. Choose a tool, then drag on the image. Text and step tools use a click.") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: model.tool == .select ? .arrow : model.tool == .text ? .iBeam : .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var marks = model.marks
        if let draft, draft.tool != .crop { marks.append(draft) }
        do {
            let rendered = try ImageRenderer.preview(model.source, marks: marks, cache: previewCache)
            NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height)).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } catch {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
        }
        if let draft, draft.tool == .crop {
            let ratio = bounds.width/CGFloat(model.source.width)
            let rect = CGRect(x: draft.rect.minX*ratio, y: draft.rect.minY*ratio, width: draft.rect.width*ratio, height: draft.rect.height*ratio)
            let veil = NSBezierPath(rect: bounds); veil.append(NSBezierPath(rect: rect)); veil.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.38).setFill(); veil.fill()
            NSColor.white.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 1.5; path.setLineDash([6, 4], count: 2, phase: 0); path.stroke()
            let label = "\(Int(draft.rect.width)) × \(Int(draft.rect.height))"
            (label as NSString).draw(at: CGPoint(x: rect.minX+7, y: max(rect.minY+7, 7)), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)])
        }
        if model.tool == .select, let selected = model.selectedMark {
            let scale = bounds.width/CGFloat(model.source.width)
            let box = selected.bounds
            let rect = CGRect(x: box.minX*scale, y: box.minY*scale, width: box.width*scale, height: box.height*scale)
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
            if selected.tool == .arrow, selected.style == "curved" {
                let control = selected.curveControl
                let handle = NSBezierPath(ovalIn: CGRect(x: control.x*scale-5, y: control.y*scale-5, width: 10, height: 10))
                NSColor.controlAccentColor.setFill(); handle.fill(); NSColor.white.setStroke(); handle.stroke()
            }
            for point in [rect.origin, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                let handle = NSBezierPath(roundedRect: CGRect(x: point.x-4, y: point.y-4, width: 8, height: 8), xRadius: 2, yRadius: 2)
                NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke(); handle.stroke()
            }
        }
    }
    private func pixel(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(CGFloat(model.source.width), point.x/bounds.width*CGFloat(model.source.width))),
                       y: max(0, min(CGFloat(model.source.height), point.y/bounds.height*CGFloat(model.source.height))))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); start = pixel(event)
        if model.tool == .crop { start = SelectionGeometry.snap(start, within: CGRect(x: 0,y: 0,width: model.source.width,height: model.source.height), tolerance: 8*CGFloat(model.source.width)/max(1,bounds.width)) }
        if model.tool == .select {
            movingControl = false
            if let selected = model.selectedMark {
                if selected.tool == .arrow, selected.style == "curved" {
                    let control = selected.curveControl
                    movingControl = hypot(start.x-control.x, start.y-control.y) < 12*CGFloat(model.source.width)/bounds.width
                }
                let box = selected.bounds
                let corners = [box.origin, CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
                if let corner = corners.first(where: { hypot(start.x-$0.x, start.y-$0.y) < 10*CGFloat(model.source.width)/bounds.width }) {
                    resizing = true; resizeCorner = corner
                    resizeAnchor = CGPoint(x: corner.x == box.minX ? box.maxX : box.minX, y: corner.y == box.minY ? box.maxY : box.minY)
                } else { resizing = false }
            }
            if !resizing && !movingControl { model.select(model.marks.reversed().first { $0.bounds.contains(start) }) }
            movingMark = model.selectedMark
            if movingMark != nil { model.beginChange() }
            if event.clickCount == 2, let mark = movingMark, mark.tool == .text { model.textPoint = mark.points.first?.cg ?? start; model.textInput = mark.text; model.showTextSheet = true }
            needsDisplay = true; return
        }
        model.selectedID = nil
        if model.tool == .text {
            model.textPoint = start; model.textInput = ""; model.showTextSheet = true; return
        }
        if model.tool == .number {
            var mark = Mark(tool: .number, points: [PixelPoint(start)], color: model.color, width: model.lineWidth, text: "\(model.nextNumber)"); mark.style = model.markStyle
            model.commit(mark); return
        }
        draft = Mark(tool: model.tool, points: [PixelPoint(start), PixelPoint(start)], color: model.color, width: model.lineWidth)
        draft?.style = model.markStyle
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if model.tool == .select, let original = movingMark {
            let end = pixel(event)
            if movingControl {
                var changed = original; changed.control = PixelPoint(end); model.replace(changed)
            } else if resizing {
                var scaled = original
                let dx = resizeCorner.x-resizeAnchor.x, dy = resizeCorner.y-resizeAnchor.y
                var sx = abs(dx) > 0.1 ? max(0.1, (end.x-resizeAnchor.x)/dx) : 1
                var sy = abs(dy) > 0.1 ? max(0.1, (end.y-resizeAnchor.y)/dy) : 1
                if event.modifierFlags.contains(.shift) { sx = max(sx, sy); sy = sx }
                scaled.points = original.points.map { PixelPoint(x: resizeAnchor.x+($0.x-resizeAnchor.x)*sx, y: resizeAnchor.y+($0.y-resizeAnchor.y)*sy) }
                if let control = original.control { scaled.control = PixelPoint(x: resizeAnchor.x+(control.x-resizeAnchor.x)*sx, y: resizeAnchor.y+(control.y-resizeAnchor.y)*sy) }
                if original.tool == .text || original.tool == .number { scaled.width = max(2, original.width*Double(min(sx, sy))) }
                model.replace(scaled)
            } else { model.replace(original.moved(dx: end.x-start.x, dy: end.y-start.y)) }
            needsDisplay = true; return
        }
        guard var mark = draft else { return }
        var end = pixel(event)
        if mark.tool == .crop, let aspect = model.cropAspect {
            let width = abs(end.x-start.x)
            end.y = start.y+(end.y >= start.y ? width/aspect : -width/aspect)
        }
        if event.modifierFlags.contains(.shift), mark.tool != .pen {
            if mark.tool == .arrow {
                let dx = end.x-start.x, dy = end.y-start.y, distance = hypot(dx, dy)
                let angle = (atan2(dy, dx)/(.pi/4)).rounded() * (.pi/4)
                end = CGPoint(x: start.x+distance*cos(angle), y: start.y+distance*sin(angle))
            } else {
                let size = max(abs(end.x-start.x), abs(end.y-start.y))
                end = CGPoint(x: start.x+(end.x >= start.x ? size : -size), y: start.y+(end.y >= start.y ? size : -size))
            }
        }
        if mark.tool == .crop, model.cropAspect == nil { end = SelectionGeometry.snap(end,within: CGRect(x: 0,y: 0,width: model.source.width,height: model.source.height),tolerance: 8*CGFloat(model.source.width)/max(1,bounds.width)) }
        if mark.tool == .pen { mark.points.append(PixelPoint(end)) }
        else if mark.tool == .highlight, !event.modifierFlags.contains(.option), let snapped = model.smartHighlight(from: start, to: end) { mark.points = [PixelPoint(snapped.0), PixelPoint(snapped.1)] }
        else { mark.points = [PixelPoint(start), PixelPoint(end)] }
        draft = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if movingMark != nil { movingMark = nil; resizing = false; movingControl = false; needsDisplay = true; return }
        guard let mark = draft else { return }
        draft = nil
        if mark.tool == .crop { if mark.rect.width > 3, mark.rect.height > 3 { model.crop(mark.rect) } }
        else if mark.tool == .pen || (mark.rect.width > 2 || mark.rect.height > 2) { model.commit(mark) }
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { draft = nil; model.selectedID = nil; needsDisplay = true; return }
        if event.keyCode == 51 || event.keyCode == 117 { model.removeSelected(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "d" { model.duplicateSelected(); return }
        if [123, 124, 125, 126].contains(event.keyCode), let mark = model.selectedMark {
            let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: Double = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: Double = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            model.beginChange(); model.replace(mark.moved(dx: dx, dy: dy)); return
        }
        if !event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(), let tool = MarkTool.allCases.first(where: { $0.key == key }) {
            model.tool = tool; window?.invalidateCursorRects(for: self); return
        }
        super.keyDown(with: event)
    }
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
}
