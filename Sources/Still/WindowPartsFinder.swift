import AppKit
import ApplicationServices
import StillCore

/// Finds the parts inside a window for window selection (a browser's page without its tabs and toolbar, a pane).
enum WindowPartsFinder {
    /// The roles that frame a part of a window someone might want on its own.
    private static let roles: Set<String> = ["AXWebArea", "AXScrollArea", "AXSplitGroup", "AXGroup", "AXTable", "AXOutline", "AXTextArea", "AXBrowser", "AXList", "AXImage"]

    /// From macOS's accessibility tree, only when Still is already allowed to read it (Privacy & Security →
    /// Accessibility); it never asks for that here. Frames are global, top-left origin, like CGWindowList's.
    static func accessibility(pid: pid_t, frame: CGRect) -> [CGRect] {
        guard pid > 0, AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: { rect(of: $0).map { abs($0.minX - frame.minX) < 4 && abs($0.minY - frame.minY) < 4 && abs($0.width - frame.width) < 4 } ?? false }) else { return [] }
        // Runs off the main thread, but still give up after a moment so a slow app doesn't keep the highlight waiting.
        let deadline = Date().addingTimeInterval(1.5)
        var found: [CGRect] = [], queue: [(AXUIElement, Int)] = [(window, 0)], visited = 0
        while !queue.isEmpty, visited < 400, Date() < deadline {
            let (element, depth) = queue.removeFirst(); visited += 1
            AXUIElementSetMessagingTimeout(element, 0.25)
            if depth > 0, let role = value(element, kAXRoleAttribute) as? String, roles.contains(role), let r = rect(of: element) { found.append(r) }
            if depth < 14, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        return found
    }

    /// From the frozen picture: the full-width lines below a title bar or toolbar (see WindowParts.bands).
    /// `region` is the window in the overlay view's points; `viewSize` maps points to the snapshot's pixels.
    static func picture(_ snapshot: CGImage, region: CGRect, viewSize: CGSize) -> [CGRect] {
        guard viewSize.width > 0, viewSize.height > 0 else { return [] }
        let sx = CGFloat(snapshot.width) / viewSize.width, sy = CGFloat(snapshot.height) / viewSize.height
        let pixels = CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy).integral
        guard let crop = snapshot.cropping(to: pixels) else { return [] }
        let (w, h) = (crop.width, crop.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The bitmap's rows run top to bottom, as the window's do.
        let bands = WindowParts.bands(width: w, height: h) { x, y in
            let i = (y * w + x) * 4
            return Double(bytes[i]) * 0.299 + Double(bytes[i + 1]) * 0.587 + Double(bytes[i + 2]) * 0.114
        }
        return bands.map { CGRect(x: region.minX + $0.minX / sx, y: region.minY + $0.minY / sy, width: $0.width / sx, height: $0.height / sy) }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private static func rect(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
