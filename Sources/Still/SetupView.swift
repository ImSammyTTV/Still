import SwiftUI
import ScreenCaptureKit

/// Permission requests stay behind an explicit button; optional devices are requested when used.
struct SetupRootView: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @AppStorage("studioSetupComplete") private var complete = false
    var body: some View {
        if complete { MainView(library: library, recorder: recorder) }
        else { SetupView(library: library) { complete = true } }
    }
}

struct SetupView: View {
    @ObservedObject var library: Library
    let finish: () -> Void
    @State private var checking = false
    @State private var checked = false
    @State private var failed = false
    private var installed: Bool { Bundle.main.bundleURL.path == "/Applications/Still.app" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Still.").font(.system(size: 36, weight: .bold)); Spacer(); Text("LET’S GET YOU READY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            Text("Your first capture starts here.").font(Studio.heading)
            Text("One screen permission is all you need for screenshots. Camera and microphone access can wait until you use them.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card("01", "Keep Still in Applications", symbol: installed ? "checkmark.circle.fill" : "folder") {
                        Text(installed ? "Still is installed in the right place. Updates can keep using the same app." : "Move Still to Applications before granting screen access, then open it from there.")
                        if !installed { Button("Show Still in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) } }
                    }
                    card("02", "Allow screen capture", symbol: checked && !failed ? "checkmark.circle.fill" : "display") {
                        if checked && !failed { Text("Screen access is ready.").foregroundStyle(Studio.accent) }
                        else {
                            Text("Enable Still in the upper Screen & System Audio Recording list. The Audio Only list does not allow screenshots.")
                            HStack {
                                Button(checking ? "Checking…" : "Enable Screen Capture") { check(openSettingsOnFailure: true) }.buttonStyle(.borderedProminent).disabled(checking)
                                Button("Open System Settings") { AppController.shared.openPermissionSettings() }
                                Button("Check Again") { check(openSettingsOnFailure: false) }.disabled(checking)
                            }
                            if failed {
                                Text("Access is still unavailable. In System Settings, use + to add /Applications/Still.app if needed. If macOS asks you to quit and reopen Still, do that, then check again.").foregroundStyle(.secondary)
                                Button("Show the App to Add") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            }
                        }
                    }
                    card("03", "Make your first capture", symbol: "cursorarrow") {
                        Text("Choose Capture Area below, drag over the screen, then release. Hold Space to select a window. You can also use Capture from the menu bar.")
                        Text("Want ⇧⌘4? Turn off the matching macOS shortcut in Keyboard → Keyboard Shortcuts → Screenshots. You can choose another shortcut in Still’s settings.").foregroundStyle(.secondary)
                        Button("Open Keyboard Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) } }
                    }
                }
            }
            HStack {
                Button("Set Up Later") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Explore the Editor") { finish(); AppController.shared.demo() }
                Button("Capture Area") { finish(); AppController.shared.captureArea() }.buttonStyle(.borderedProminent).disabled(!checked || failed)
            }
        }.padding(.horizontal, 28).padding(.top, 42).padding(.bottom, 24)
            .font(.system(size: 12)).background(Studio.paper).tint(Studio.accent)
            .onAppear { refreshExistingAccess() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshExistingAccess() }
    }
    private func card<Content: View>(_ number: String, _ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Studio.accent).padding(.top, 3)
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
                content().fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func refreshExistingAccess() {
        if CGPreflightScreenCaptureAccess() { checked = true; failed = false; library.permissionGranted = true }
    }
    private func check(openSettingsOnFailure: Bool) {
        checking = true
        Task { @MainActor in
            do {
                guard let screen = NSScreen.main else { throw NSError(domain: "Still", code: 1, userInfo: [NSLocalizedDescriptionKey: "No connected display was found."]) }
                _ = try await ScreenCaptureAPI.image(screen: screen)
                library.permissionGranted = true; library.permissionError = nil; failed = false
            } catch {
                library.permissionGranted = false; failed = true
                let native = error as NSError
                library.permissionError = "\(native.localizedDescription) (\(native.domain) \(native.code))"
                if openSettingsOnFailure { AppController.shared.openPermissionSettings() }
            }
            checked = true; checking = false
        }
    }
}
