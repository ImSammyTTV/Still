import AppKit
import SwiftUI
import ScreenCaptureKit
import ApplicationServices
import StillCore

@MainActor final class ScrollingSession: ObservableObject {
    @Published var running = false
    @Published var autoScroll = false
    @Published var frames = 1
    @Published var dimensions = ""
    @Published var message = "Scroll slowly inside the selected area."
    @Published var axis = StitchAxis.vertical
    private var timer: Timer?
    private var panel: NSPanel?
    private var border: NSPanel?
    private var stitcher: ScrollingStitcher?
    private var display: NSScreen?
    private var rect = CGRect.zero
    private var filter: SCContentFilter?
    private var processing = false
    private var finishing = false
    private var firstImage: CGImage?
    var onComplete: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    func start(first: CGImage, screen: NSScreen, rect: CGRect) {
        self.display = screen; self.rect = rect
        firstImage = first
        do { stitcher = try ScrollingStitcher(first, axis: axis) } catch { message = error.localizedDescription; return }
        dimensions = "\(first.width) × \(first.height)"; frames = 1; running = true
        let panel = SelectionPanel(contentRect: CGRect(x: screen.visibleFrame.midX-245, y: screen.visibleFrame.minY+20, width: 490, height: 112), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ScrollingHUD(session: self)); panel.orderFrontRegardless(); self.panel = panel
        let primaryTop = NSScreen.screens[0].frame.maxY
        let frame = CGRect(x: screen.frame.minX+rect.minX, y: screen.frame.maxY-rect.maxY, width: rect.width, height: rect.height)
        let border = NSPanel(contentRect: frame.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false; border.backgroundColor = .clear; border.level = .floating; border.ignoresMouseEvents = true; border.hidesOnDeactivate = false
        border.contentView = NSHostingView(rootView: Rectangle().stroke(Color.accentColor, lineWidth: 2)); border.orderFrontRegardless(); self.border = border
        _ = primaryTop
        Task { do { filter = try await ScreenCaptureAPI.filter(screen: screen); beginTimer() } catch { message = error.localizedDescription; running = false } }
    }
    private func beginTimer() { timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } } }
    private func tick() async {
        guard running, !processing, let display, let stitcher, let filter else { return }
        processing = true
        defer { processing = false; if finishing { complete() } }
        do {
            let image = try await ScreenCaptureAPI.image(screen: display, rect: rect, filter: filter)
            let added = try await Task.detached(priority: .userInitiated) { try stitcher.append(image) }.value
            if added { let result = try stitcher.result(); frames = stitcher.frameCount; dimensions = "\(result.width) × \(result.height)"; message = "Capturing… scroll slowly, then click Done." }
            if autoScroll {
                let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: axis == .vertical ? -220 : 0, wheel2: axis == .horizontal ? -220 : 0, wheel3: 0)
                wheel?.post(tap: .cghidEventTap)
            }
        } catch { message = error.localizedDescription; autoScroll = false }
    }
    func toggleAuto() {
        if !autoScroll {
            guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else { message = "Enable Accessibility for Still to auto-scroll, or scroll manually."; return }
            if let display {
                let point = CGPoint(x: display.frame.minX+rect.midX, y: NSScreen.screens[0].frame.maxY-display.frame.maxY+rect.midY)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        autoScroll.toggle()
    }
    func setAxis(_ value: StitchAxis) { guard frames == 1, let firstImage else { return }; axis = value; do { stitcher = try ScrollingStitcher(firstImage, axis: value) } catch { message = error.localizedDescription } }
    func finish() { running = false; autoScroll = false; timer?.invalidate(); finishing = true; if !processing { complete() } }
    private func complete() {
        guard finishing else { return }; finishing = false
        do { let image = try stitcher?.result(); close(); if let image { onComplete?(image) } }
        catch { message = error.localizedDescription }
    }
    func cancel() { running = false; autoScroll = false; finishing = false; timer?.invalidate(); if processing { DispatchQueue.main.asyncAfter(deadline: .now()+0.8) { self.close(); self.onCancel?() } } else { close(); onCancel?() } }
    private func close() { timer?.invalidate(); timer = nil; panel?.close(); border?.close(); panel = nil; border = nil; stitcher = nil; filter = nil }
}
struct ScrollingHUD: View {
    @ObservedObject var session: ScrollingSession
    var body: some View {
        VStack(spacing: 12) {
            HStack { Image(systemName: "arrow.down.to.line"); Text("Scrolling Capture").fontWeight(.semibold); Picker("Direction", selection: Binding(get: { session.axis }, set: { session.setAxis($0) })) { Text("Vertical").tag(StitchAxis.vertical); Text("Horizontal").tag(StitchAxis.horizontal) }.labelsHidden().frame(width: 96).disabled(session.frames > 1); Spacer(); Text("\(session.frames) frames · \(session.dimensions)").foregroundStyle(.secondary).font(.system(size: 10)) }
            HStack { Text(session.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2); Spacer(); Button(session.autoScroll ? "Stop Auto" : "Auto Scroll") { session.toggleAuto() }; Button("Cancel") { session.cancel() }; Button("Done") { session.finish() }.buttonStyle(.borderedProminent) }
        }.padding(18).font(.system(size: 12)).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 15)).environment(\.colorScheme, .dark)
    }
}
