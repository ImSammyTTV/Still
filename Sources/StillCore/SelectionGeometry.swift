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
    public static func snap(_ point: CGPoint, within bounds: CGRect, tolerance: Double) -> CGPoint {
        let x = abs(point.x-bounds.minX) <= tolerance ? bounds.minX : abs(point.x-bounds.maxX) <= tolerance ? bounds.maxX : point.x
        let y = abs(point.y-bounds.minY) <= tolerance ? bounds.minY : abs(point.y-bounds.maxY) <= tolerance ? bounds.maxY : point.y
        return CGPoint(x: x,y: y)
    }
}
