import CoreGraphics

public enum SelectionGeometry {
    public static func move(_ rect: CGRect, within bounds: CGRect, dx: Double, dy: Double, resize: Bool = false, aspect: Double = 0) -> CGRect {
        var result = rect.standardized
        if resize {
            result.size.width = max(2, min(bounds.maxX-result.minX, result.width+dx))
            result.size.height = max(2, min(bounds.maxY-result.minY, result.height+dy))
            if aspect > 0 {
                if dx != 0 { result.size.height = result.width/aspect } else { result.size.width = result.height*aspect }
                let scale = min(1,(bounds.maxX-result.minX)/result.width,(bounds.maxY-result.minY)/result.height)
                result.size.width *= scale; result.size.height *= scale
            }
        } else {
            result.size.width = min(bounds.width,result.width); result.size.height = min(bounds.height,result.height)
            result.origin.x = min(bounds.maxX-result.width,max(bounds.minX,result.minX+dx))
            result.origin.y = min(bounds.maxY-result.height,max(bounds.minY,result.minY+dy))
        }
        return result.intersection(bounds)
    }
    /// The capture magnifier's zoom steps (on-screen points per screen pixel). The box grows with the zoom, so zooming
    /// in shows more detail without the picture getting cramped. The same numbers are in Desktop/web/shared/geometry.js.
    public static let magnifierZooms: [Double] = [2, 3, 4, 6, 8, 12, 16]
    public static func magnifierSize(zoom: Double) -> Double { 80 + 16 * Double(magnifierZooms.firstIndex(of: zoom) ?? 0) }
    /// Up and to the right of the pointer (y grows downwards), moving to the left or below wherever that side would run
    /// off the screen, so the box never comes to rest under the pointer. `below` is room kept for the colour chip.
    public static func magnifierFrame(pointer: CGPoint, size: Double, within bounds: CGRect, gap: Double = 24, margin: Double = 10, below: Double = 26) -> CGRect {
        var x = pointer.x + gap, y = pointer.y - gap - size
        if x + size > bounds.maxX - margin { x = pointer.x - gap - size }
        if y < bounds.minY + margin { y = pointer.y + gap }
        x = max(bounds.minX + margin, min(bounds.maxX - size - margin, x))
        y = max(bounds.minY + margin, min(bounds.maxY - size - below - margin, y))
        return CGRect(x: x, y: y, width: size, height: size)
    }
    public static func snap(_ point: CGPoint, within bounds: CGRect, tolerance: Double) -> CGPoint {
        let x = abs(point.x-bounds.minX) <= tolerance ? bounds.minX : abs(point.x-bounds.maxX) <= tolerance ? bounds.maxX : point.x
        let y = abs(point.y-bounds.minY) <= tolerance ? bounds.minY : abs(point.y-bounds.maxY) <= tolerance ? bounds.maxY : point.y
        return CGPoint(x: x,y: y)
    }
}
