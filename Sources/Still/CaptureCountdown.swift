import AppKit
import SwiftUI

/// The countdown before a timed capture: a large number in the middle of the screen the pointer is on, so it's clear
/// the capture is coming and when. Clicking it calls the capture off. It closes before the screen is grabbed, so it
/// is never in the picture.
@MainActor final class CaptureCountdown: ObservableObject {
    @Published private(set) var remaining: Int
    private var panel: NSPanel?
    private var cancelled = false

    private init(seconds: Int) { remaining = seconds }

    /// Counts down `seconds` and answers whether it ran to the end (false when it was clicked away).
    static func run(seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        let countdown = CaptureCountdown(seconds: seconds)
        countdown.show()
        while countdown.remaining > 0, !countdown.cancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !countdown.cancelled { countdown.remaining -= 1 }
        }
        countdown.panel?.close(); countdown.panel = nil
        // Give the window server a moment to take the panel off the screen before it's grabbed.
        if !countdown.cancelled { try? await Task.sleep(nanoseconds: 150_000_000) }
        return !countdown.cancelled
    }

    private func show() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        let size = CGSize(width: 168, height: 168)
        let panel = NSPanel(contentRect: CGRect(x: screen.frame.midX - size.width/2, y: screen.frame.midY - size.height/2, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CountdownView(countdown: self) { [weak self] in self?.cancel() })
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func cancel() { cancelled = true; panel?.close(); panel = nil }

    private struct CountdownView: View {
        @ObservedObject var countdown: CaptureCountdown
        let cancel: () -> Void
        var body: some View {
            VStack(spacing: 4) {
                Text("\(countdown.remaining)").font(.system(size: 76, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true)).animation(.easeOut(duration: 0.25), value: countdown.remaining)
                Text("Click to cancel").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 168, height: 168)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .contentShape(Rectangle()).onTapGesture(perform: cancel)
            .accessibilityElement(children: .combine).accessibilityLabel("Capture in \(countdown.remaining) seconds. Click to cancel.")
        }
    }
}
