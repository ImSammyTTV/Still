import AppKit
import CoreImage
import SwiftUI

/// A small floating card with a share link drawn as a QR code, so a phone camera can open it straight away.
@MainActor enum QRCodePanel {
    private static var panel: NSPanel?

    static func show(_ link: String) {
        panel?.close()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Open on Phone"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.level = .floating; window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: QRCodeCard(link: link, image: image(for: link)) { panel?.close(); panel = nil })
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        panel = window
    }

    /// The link as a crisp black-on-white code, scaled up in whole pixels so the modules stay sharp.
    static func image(for link: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(link.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (480 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

private struct QRCodeCard: View {
    let link: String
    let image: NSImage?
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Open on your phone").font(.system(size: 15, weight: .semibold)).padding(.top, 18)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
                if let image { Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(16) }
                else { Text("This link is too long for a QR code").font(.caption).foregroundStyle(.black) }
            }.frame(width: 240, height: 240)
            Text("Point the camera at the code").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(link).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).padding(.horizontal, 20)
            HStack {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string); copied = true }.buttonStyle(.borderedProminent)
            }.padding(.bottom, 18)
        }.frame(width: 320)
    }
}
