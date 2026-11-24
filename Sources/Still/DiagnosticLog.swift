import AppKit
import StillCore

/// A small record of what went wrong, kept on this Mac in ~/Library/Application Support/Still/Logs, so a problem
/// report can say more than "it didn't work". It holds error messages and facts about the Mac only: never pictures,
/// clipboard text, anything typed, or keys.
enum DiagnosticLog {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/Logs", isDirectory: true)
    static var file: URL { folder.appendingPathComponent("still.log") }
    static var olderFile: URL { folder.appendingPathComponent("still.log.1") }
    /// Writes happen one at a time, off the main thread, so logging never slows a capture down.
    private static let queue = DispatchQueue(label: "Still.DiagnosticLog", qos: .utility)

    static func log(_ message: String) {
        let line = ProblemReport.logLine(message, date: Date())
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8), manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = ((try? manager.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
        if ProblemReport.shouldRotate(currentSize: size, adding: data.count) {
            try? manager.removeItem(at: olderFile)
            try? manager.moveItem(at: file, to: olderFile)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// The latest `count` lines across both files, after anything still waiting has been written.
    static func recentLines(_ count: Int) -> [String] {
        queue.sync {
            let older = (try? String(contentsOf: olderFile, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return ProblemReport.lastLines(older + "\n" + current, count: count)
        }
    }

    // MARK: Facts about this Mac

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }
    static var macOS: String { ProcessInfo.processInfo.operatingSystemVersionString }
    /// The model identifier, such as "Mac15,3".
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    /// Each display's name, size in points, pixel scale and whether it's the main one.
    @MainActor static var displays: [String] {
        NSScreen.screens.enumerated().map { index, screen in
            let size = screen.frame.size
            let scale = screen.backingScaleFactor == screen.backingScaleFactor.rounded() ? String(Int(screen.backingScaleFactor)) : String(format: "%.2f", screen.backingScaleFactor)
            return "\(index + 1). \(screen.localizedName): \(Int(size.width))×\(Int(size.height)) points at \(scale)x\(index == 0 ? " (main)" : "")"
        }
    }

    /// Notes Still's version and this Mac's set-up as Still opens, so later errors in the log have that context.
    @MainActor static func logLaunch() {
        log("Still \(version) (build \(build)) opened on macOS \(macOS), \(model.isEmpty ? "unknown Mac" : model), screen recording \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")")
        log("Displays: \(displays.joined(separator: "; "))")
    }
}

/// Report a Problem: saves a plain-text report on the Desktop, shows it in Finder and opens a new issue page with a
/// short form to fill in. The report never leaves the Mac by itself; you choose whether to attach it.
@MainActor enum ProblemReporter {
    static let repository = "ImSammyTTV/Still"

    static func report() {
        let created = Date()
        let facts = ProblemReport.Facts(version: DiagnosticLog.version, build: DiagnosticLog.build, macOS: DiagnosticLog.macOS, model: DiagnosticLog.model,
                                        displays: DiagnosticLog.displays, screenRecordingAllowed: CGPreflightScreenCaptureAccess(), settings: settingLines(),
                                        historyCount: AppController.shared?.library.items.count ?? 0, logLines: [], created: created)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = desktop.appendingPathComponent(ProblemReport.fileName(date: created))
        let issue = ProblemReport.issueURL(repository: repository, version: facts.version, build: facts.build, macOS: facts.macOS)
        DiagnosticLog.log("Problem report requested")
        // Reading the log and writing the file happen in the background; only showing the result comes back here.
        DispatchQueue.global(qos: .userInitiated).async {
            var complete = facts
            complete.logLines = DiagnosticLog.recentLines(ProblemReport.reportLines)
            let text = ProblemReport.hidingHome(ProblemReport.text(complete), home: NSHomeDirectory())
            let failure: String?
            do { try Data(text.utf8).write(to: destination, options: .atomic); failure = nil } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failure {
                        AppController.shared?.showError("The problem report couldn’t be saved", "\(failure) You can still describe the problem on the page that opens.")
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    if let issue { NSWorkspace.shared.open(issue) }
                }
            }
        }
    }

    /// The settings most likely to explain a problem. Anything typed in (the watermark, the file name pattern) and
    /// folders that would show your user name only say whether they're set, and keys never appear.
    private static func settingLines() -> [String] {
        let p = Preferences.shared, defaults = UserDefaults.standard
        let flag: (Bool) -> String = { $0 ? "on" : "off" }
        var settings: [String: String] = [
            "appearance": p.appearance, "showMenuBar": flag(p.showMenuBar), "hideDesktop": flag(p.hideDesktop),
            "autoUpdate": flag(defaults.object(forKey: "autoUpdate") as? Bool ?? true),
            "captureOwnWindows": flag(p.captureOwnWindows), "pickPopups": flag(p.pickPopups), "freezeScreen": flag(p.freezeScreen),
            "crosshair": p.crosshair, "magnifier": flag(p.magnifier), "rememberSelection": flag(p.rememberSelection),
            "adjustAreaBeforeCapture": flag(p.adjustBeforeCapture), "includeCursor": flag(p.includeCursor), "windowShadow": flag(p.windowShadow),
            "windowBackground": flag(p.windowBackground), "exportFormat": p.exportFormat, "filenamePattern": p.filenamePattern,
            "saveAfterCapture": flag(p.saveAfterCapture), "annotateAfterCapture": flag(p.annotateAfterCapture), "pinAfterCapture": flag(p.pinAfterCapture),
            "previewPosition": p.previewPosition, "previewTimeout": String(Int(p.previewTimeout)),
            "recordingFormat": p.recordingFormat, "recordingFPS": String(p.recordingFPS), "recordingCodec": p.recordingCodec, "recordingQuality": p.recordingQuality,
            "recordingResolution": String(p.recordingResolution), "recordingCursor": flag(p.recordingCursor), "recordingClicks": flag(p.recordingClicks),
            "recordingKeys": flag(p.recordingKeys), "recordingCamera": flag(p.recordingCamera), "recordingAutomation": flag(p.recordingAutomation),
            "gifFPS": String(p.gifFPS), "gifWidth": String(p.gifWidth), "retentionDays": String(p.retentionDays), "ocrLanguage": p.ocrLanguage,
            "allowURLScheme": flag(p.allowURLScheme), "wallpaperMode": p.wallpaperMode, "watermarkKind": p.watermarkKind, "watermarkText": p.watermarkText
        ]
        if let library = AppController.shared?.library { settings["exportFolder"] = library.exportFolder }
        return ProblemReport.settingLines(settings, privateText: ["filenamePattern", "watermarkText", "exportFolder"])
    }
}
