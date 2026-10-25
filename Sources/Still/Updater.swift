import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer Still, then downloads, verifies and installs it in place.
@MainActor final class Updater {
    static let shared = Updater()
    private let repository = "ImSammyTTV/Still"
    private var checking = false
    private var timer: Timer?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        guard UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now()+15) { self.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6*60*60, repeats: true) { _ in Task { @MainActor in self.check(manual: false) } }
    }

    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                guard let release = try await latestRelease() else { if manual { info("You’re up to date", "Still \(currentVersion) is the latest version.") }; return }
                let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                if !manual, skipped == release.version { return }
                offer(release)
            } catch { if manual { info("Couldn’t check for updates", error.localizedDescription) } }
        }
    }

    private struct Release { let version: String; let notes: String; let zip: URL; let sums: URL? }

    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]] else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(version, than: currentVersion) else { return nil }
        let url = { (match: (String) -> Bool) in assets.first(where: { match($0["name"] as? String ?? "") }).flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) } }
        guard let zip = url({ $0.hasSuffix("mac-universal.zip") }) else { return nil }
        return Release(version: version, notes: json["body"] as? String ?? "", zip: zip, sums: url({ $0 == "SHA256SUMS" }))
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (v: String) in v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) { let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0; if l != r { return l > r } }
        return false
    }

    private func offer(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Still \(release.version) is available"
        alert.informativeText = "You have \(currentVersion). Still will download the update, check it and relaunch."
        alert.addButton(withTitle: "Install and Relaunch"); alert.addButton(withTitle: "Later"); alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: "skippedVersion")
        default: break
        }
    }

    private func install(_ release: Release) {
        AppController.shared.library.toast("Downloading Still \(release.version)…")
        Task {
            do {
                let (zip, _) = try await URLSession.shared.download(from: release.zip)
                if let sums = release.sums {
                    let (sumData, _) = try await URLSession.shared.data(from: sums)
                    let expected = String(decoding: sumData, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(release.zip.lastPathComponent) })?.split(separator: " ").first.map(String.init)
                    let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                    guard expected == actual else { throw NSError(domain: "Still", code: 10, userInfo: [NSLocalizedDescriptionKey: "The download didn’t match its checksum, so nothing was installed."]) }
                }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("Still-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let app = work.appendingPathComponent("Still.app")
                guard FileManager.default.fileExists(atPath: app.path) else { throw NSError(domain: "Still", code: 11, userInfo: [NSLocalizedDescriptionKey: "The update didn’t contain Still.app."]) }
                try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                // Swap the app once this process has quit, then reopen it.
                let target = Bundle.main.bundlePath
                let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; rm -rf \"\(target)\" && ditto \"\(app.path)\" \"\(target)\" && open \"\(target)\"; rm -rf \"\(work.path)\""
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
                try process.run()
                NSApp.terminate(nil)
            } catch { info("Update failed", error.localizedDescription) }
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Still", code: 12, userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) failed while installing the update."]) }
    }

    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
}
