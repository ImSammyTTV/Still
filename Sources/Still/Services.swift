import AppKit
import StillCore

// macOS Services. The NSServices entries in Resources/Info.plist route here, so Still's image actions show up in the
// Services submenu of the right-click menu for image files in Finder and for selected images in other apps.
// Only actions that need the user's selection are offered: any local app can call NSPerformService, so services
// that capture or record without interaction would bypass the Screen Recording consent the user gave Still.
extension AppController {
    // "Open in Still": image files, .stillshot projects, or image data on the pasteboard.
    @objc func openInStill(_ pasteboard: NSPasteboard, userData: String?, error failure: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = serviceFileURLs(pasteboard)
        if !urls.isEmpty { for url in urls { importURL(url) } }
        else if let image = serviceImages(pasteboard).first {
            do { openItem(try library.add(image: image, title: library.captureName(width: image.width, height: image.height))) }
            catch { let text = error.localizedDescription; DispatchQueue.main.async { self.showError("Couldn’t open image", text) }; return }
        } else { failure.pointee = "No image to open"; return }
        NSApp.activate(ignoringOtherApps: true)
    }
    // "Copy Text from Image with Still": recognises text and QR codes in the selected images and copies the result.
    @objc func copyTextFromImage(_ pasteboard: NSPasteboard, userData: String?, error failure: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let images = serviceImages(pasteboard)
        guard !images.isEmpty else { failure.pointee = "No image to read"; return }
        Task {
            do {
                var parts: [String] = []
                for image in images { let text = try await recognizeText(in: image); if !text.isEmpty { parts.append(text) } }
                let output = parts.joined(separator: "\n\n")
                if output.isEmpty { showError("No text found", "Still couldn’t find any text in the selected image\(images.count == 1 ? "" : "s").") }
                else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string); showCopyToast("Text copied to clipboard") }
            } catch { showError("Text recognition failed", error.localizedDescription) }
        }
    }
    // "Pin Image with Still": floats the selected images above other windows.
    @objc func pinImage(_ pasteboard: NSPasteboard, userData: String?, error failure: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let images = serviceImages(pasteboard)
        guard !images.isEmpty else { failure.pointee = "No image to pin"; return }
        for image in images { pin(image) }
    }

    /// Text and QR codes found in an image, following the OCR settings. Shared with Capture Text.
    func recognizeText(in image: CGImage) async throws -> String {
        let language = Preferences.shared.ocrLanguage, keepLines = Preferences.shared.ocrLineBreaks
        let text = try await Task.detached(priority: .userInitiated) { try TextRecognition.recognize(image, language: language == "auto" ? nil : language, keepLineBreaks: keepLines) }.value
        let codes = try await Task.detached { try TextRecognition.codes(image) }.value
        return [text, codes.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func serviceFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func serviceImages(_ pasteboard: NSPasteboard) -> [CGImage] {
        let files = serviceFileURLs(pasteboard).compactMap { ImageRenderer.load($0) }
        if !files.isEmpty { return files }
        guard let image = NSImage(pasteboard: pasteboard), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return [cgImage]
    }
}
