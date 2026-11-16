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
        else if let data = servicePictureData(pasteboard) {
            Task {
                do {
                    // Decoding and encoding a big picture happen off the main thread.
                    let made = try await Task.detached(priority: .userInitiated) { () throws -> (png: Data, width: Int, height: Int) in
                        guard let image = ImageRenderer.load(data: data, decodeNow: true) else { throw RenderError.encoding }
                        return (try ImageRenderer.libraryData(image), image.width, image.height)
                    }.value
                    openItem(try library.add(png: made.png, width: made.width, height: made.height, title: library.captureName(width: made.width, height: made.height)))
                } catch { showError("Couldn’t open image", error.localizedDescription) }
            }
        } else { failure.pointee = "No image to open"; return }
        NSApp.activate(ignoringOtherApps: true)
    }
    // "Copy Text from Image with Still": recognises text and QR codes in the selected images and copies the result.
    @objc func copyTextFromImage(_ pasteboard: NSPasteboard, userData: String?, error failure: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = serviceFileURLs(pasteboard), data = files.isEmpty ? servicePictureData(pasteboard) : nil
        guard !files.isEmpty || data != nil else { failure.pointee = "No image to read"; return }
        Task {
            let images = await serviceImages(files: files, data: data)
            guard !images.isEmpty else { showError("No image to read", "Still couldn’t open the selected file\(files.count == 1 ? "" : "s") as an image."); return }
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
        let files = serviceFileURLs(pasteboard), data = files.isEmpty ? servicePictureData(pasteboard) : nil
        guard !files.isEmpty || data != nil else { failure.pointee = "No image to pin"; return }
        Task {
            let images = await serviceImages(files: files, data: data)
            for image in images { pin(image) }
        }
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
    /// A picture another app handed over itself (not a file). The pasteboard can only be read during the request, so its
    /// bytes are taken now; decoding them waits until the work moves off the main thread.
    private func servicePictureData(_ pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return data }
        return NSImage(pasteboard: pasteboard)?.tiffRepresentation
    }
    /// The images in a service request, decoded off the main thread so a big one never stalls Still.
    private func serviceImages(files: [URL], data: Data?) async -> [CGImage] {
        await Task.detached(priority: .userInitiated) { () -> [CGImage] in
            if !files.isEmpty { return files.compactMap { ImageRenderer.load($0, decodeNow: true) } }
            return data.flatMap { ImageRenderer.load(data: $0, decodeNow: true) }.map { [$0] } ?? []
        }.value
    }
}
