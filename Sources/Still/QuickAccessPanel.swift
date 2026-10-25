import AppKit
import SwiftUI

final class QuickAccessPanel: NSPanel {
    var gesture: ((Bool) -> Void)?
    var copyCapture: (() -> Void)?
    var openCapture: (() -> Void)?
    var dismissCapture: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismissCapture?(); return }
        if event.keyCode == 36 { openCapture?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyCapture?(); return }
        super.keyDown(with: event)
    }
}
final class QuickAccessHostingView: NSHostingView<PreviewView> {
    var gesture: ((Bool) -> Void)?
    private var distance: CGFloat = 0
    private var triggered = false
    override func swipe(with event: NSEvent) { if abs(event.deltaX) > abs(event.deltaY), event.deltaX != 0 { gesture?(event.deltaX < 0) } else { super.swipe(with: event) } }
    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) { distance = 0; triggered = false }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        distance += event.scrollingDeltaX
        if !triggered, abs(distance) > 85 { triggered = true; gesture?(distance < 0) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { distance = 0; triggered = false }
    }
}
