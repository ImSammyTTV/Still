import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer Still, then downloads, verifies and installs it in place.
@MainActor final class Updater {
    static let shared = Updater()
    private let repository = "ImSammyTTV/Still"
    private var checking = false
    private var timer: Timer?
    /// Every release is signed with the project's own certificate. An update must carry the same signature,
    /// so a tampered or substituted download is never installed (the checksum alone only proves integrity).
    static let releaseRequirement = #"identifier "local.sam.Still" and certificate root = H"1ab04d5c40093d821eb23c1655fe959439cc467b""#
    /// Only an installed Still.app updates itself; a development build run from .build never does.
    private var installedApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Read each time, so turning automatic checks off in Settings takes effect straight away.
    private var autoUpdateOn: Bool { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
    /// Where the install script notes why an update didn't go in, for the relaunched Still to say so.
    private var failedInstallFile: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/update-failed") }

    func start() {
        guard installedApp else { return }
        reportFailedInstall()
        scheduleChecks()
    }
    /// Checks shortly after launch (or after automatic checks are turned on), then every six hours.
    func scheduleChecks() {
        stop()
        guard installedApp, autoUpdateOn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now()+15) { self.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6*60*60, repeats: true) { _ in Task { @MainActor in self.check(manual: false) } }
    }
    func stop() { timer?.invalidate(); timer = nil }
    /// The last update couldn't replace Still (no permission for its folder, or a full disk), so the old version
    /// was reopened: say so once, rather than leave the same update to be offered again with no word why.
    private func reportFailedInstall() {
        let file = failedInstallFile
        guard let reason = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let text = reason.hasPrefix("copy")
            ? "Still couldn’t copy the new version into place. Check that there’s free disk space and that you can change the folder Still is in, then try again."
            : "Still couldn’t swap in the new version, so it kept the one you have. Check that you can change the folder Still is in, then try again."
        DispatchQueue.main.asyncAfter(deadline: .now()+2) { self.info("The update didn’t install", text) }
    }

    /// Set when Check for Updates is chosen while a background check is already under way, so that check reports
    /// back as if it had been chosen by hand.
    private var reportCheck = false
    func check(manual: Bool) {
        guard installedApp else { if manual { info("Updates are off for this build", "Only Still.app in Applications updates itself.") }; return }
        if manual { reportCheck = true }
        guard !checking else { return }
        guard manual || autoUpdateOn else { return }
        checking = true
        Task {
            defer { checking = false; reportCheck = false }
            do {
                let result = try await latestRelease()
                let report = reportCheck
                switch result {
                case .upToDate: if report { info("You’re up to date", "Still \(currentVersion) is the latest version.") }
                case .failed(let reason): if report { info("Couldn’t check for updates", reason) }
                case .available(let release):
                    let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                    if !report, skipped == release.version { return }
                    offer(release)
                }
            } catch { if reportCheck { info("Couldn’t check for updates", error.localizedDescription) } }
        }
    }

    private struct Release { let version: String; let notes: String; let zip: URL; let sums: URL }
    /// "Up to date" only when the newest release really is this version; a check that didn't get a clear answer
    /// says why instead.
    private enum CheckResult { case upToDate, available(Release), failed(String) }

    private func latestRelease() async throws -> CheckResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
        guard status == 200 else {
            let limited = (status == 403 || status == 429) && http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            return .failed(limited ? "Still has checked too often for now. Try again in an hour." : "The update server answered with an error (\(status)). Try again later.")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]] else { return .failed("The update server sent an answer Still couldn’t read. Try again later.") }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(version, than: currentVersion) else { return .upToDate }
        let url = { (match: (String) -> Bool) in assets.first(where: { match($0["name"] as? String ?? "") }).flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) } }
        guard let zip = url({ $0.hasSuffix("mac-universal.zip") }), let sums = url({ $0 == "SHA256SUMS" }) else { return .failed("Still \(version) is still being published. Try again in a few minutes.") }
        return .available(Release(version: version, notes: json["body"] as? String ?? "", zip: zip, sums: sums))
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (v: String) in v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) { let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0; if l != r { return l > r } }
        return false
    }

    private func offer(_ release: Release) {
        // Never over a capture or recording: the alert would sit under the overlay, and Return would install.
        if let app = AppController.shared, app.capturing || app.recorder.recording { DispatchQueue.main.asyncAfter(deadline: .now()+30) { [weak self] in MainActor.assumeIsolated { self?.offer(release) } }; return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Still \(release.version) is available"
        alert.informativeText = "You have \(currentVersion). Still will download the update, check it and relaunch."
        alert.addButton(withTitle: "Install and Restart"); alert.addButton(withTitle: "Later"); alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: "skippedVersion")
        default: break
        }
    }

    /// A verified update waiting for Still to quit; the script that swaps it in starts only once quitting is certain.
    private var pendingInstall: (app: URL, work: URL)?
    private var installing = false
    private func install(_ release: Release) {
        guard !installing else { return }
        // Replacing Still needs permission to change the folder it's in; find out now, not after quitting.
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            info("Can’t update Still", "You don’t have permission to replace Still in \(folder.path). Ask an administrator to install the update, or move Still to a folder you can change.")
            return
        }
        installing = true
        AppController.shared.library.toast("Downloading Still \(release.version)…")
        Task {
            defer { installing = false }
            do {
                let (zip, _) = try await URLSession.shared.download(from: release.zip)
                let (sumData, _) = try await URLSession.shared.data(from: release.sums)
                // Checking, unpacking and verifying the download take several seconds; they run on a background queue
                // so Still keeps responding meanwhile, and only the relaunch (or the error) comes back here.
                let name = release.zip.lastPathComponent, requirement = Self.releaseRequirement
                let (app, work) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URL), Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try Updater.verifyAndUnpack(zip: zip, sums: sumData, name: name, requirement: requirement) })
                    }
                }
                // Quitting can still be called off (a recording under way, or Keep Editing for unsaved edits). The
                // update is only handed over once it's certain, so it never installs later at a moment nobody chose.
                pendingInstall = (app, work)
                NSApp.terminate(nil)
                // Still here: quitting was called off, so nothing was installed.
                if pendingInstall != nil {
                    pendingInstall = nil; try? FileManager.default.removeItem(at: work)
                    AppController.shared.library.toast("The update wasn’t installed because Still didn’t quit. Choose Check for Updates to try again.")
                }
            } catch { info("Update failed", error.localizedDescription) }
        }
    }
    /// Called as Still quits for good: starts the script that swaps in the verified update and reopens Still. Returns
    /// false (and says why) if it couldn't start, so Still stays open rather than quitting without updating.
    func startPendingInstall() -> Bool {
        guard let pending = pendingInstall else { return true }
        let app = pending.app, work = pending.work; pendingInstall = nil
        // Once this process has quit: copy the new app next to the old one, swap them, and only then remove the old
        // copy, so a failure part-way never leaves you without Still. A failure is noted for the reopened Still to
        // report. Paths are passed as arguments, not pasted into the script.
        let script = #"""
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        ditto "$2" "$3.new" || { rm -rf "$3.new" "$4"; echo copy > "$5"; open "$3"; exit 1; }
        if mv "$3" "$3.old"; then
          if mv "$3.new" "$3"; then rm -rf "$3.old"; else mv "$3.old" "$3"; rm -rf "$3.new"; echo swap > "$5"; fi
        else rm -rf "$3.new"; echo swap > "$5"; fi
        open "$3"; rm -rf "$4"
        """#
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "still-update", String(ProcessInfo.processInfo.processIdentifier), app.path, Bundle.main.bundlePath, work.path, failedInstallFile.path]
        do { try process.run(); return true }
        catch { try? FileManager.default.removeItem(at: work); info("Update failed", error.localizedDescription); return false }
    }

    /// Checks the download against its published checksum, unpacks it and checks its signature. Returns the new app and
    /// the folder it was unpacked in. Runs off the main thread.
    nonisolated private static func verifyAndUnpack(zip: URL, sums: Data, name: String, requirement: String) throws -> (URL, URL) {
        let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(name) })?.split(separator: " ").first.map(String.init)
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else { throw NSError(domain: "Still", code: 10, userInfo: [NSLocalizedDescriptionKey: "The download didn’t match its checksum, so nothing was installed."]) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Still-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("Still.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw NSError(domain: "Still", code: 11, userInfo: [NSLocalizedDescriptionKey: "The update didn’t contain Still.app."]) }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path]) }
        catch { throw NSError(domain: "Still", code: 13, userInfo: [NSLocalizedDescriptionKey: "The update isn’t signed by the Still project, so nothing was installed."]) }
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return (app, work)
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        // Waits for the tool to finish without needing a run loop on this background thread.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run(); finished.wait()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Still", code: 12, userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) failed while installing the update."]) }
    }

    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
}
