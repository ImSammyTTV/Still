import AppKit
import SwiftUI

/// A small guide that stays on screen beside System Settings while you turn off macOS's own ⇧⌘4 screenshot shortcut,
/// so the steps don't vanish the moment Settings opens. It watches the setting and closes itself once it's off.
@MainActor enum ShortcutGuide {
    private static var panel: NSPanel?
    private static var timer: Timer?

    /// Whether macOS's "Save picture of selected area as a file" (⇧⌘4, symbolic hotkey 30) is still on.
    static var systemShortcutOn: Bool {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        let entry = hotkeys?["30"] as? [String: Any]
        return (entry?["enabled"] as? Bool) ?? ((entry?["enabled"] as? NSNumber)?.boolValue ?? true)
    }

    /// Opens Keyboard settings and shows the guide next to them.
    static func show() {
        // The plain Keyboard page: a deep link to its Shortcuts sheet isn't honoured by every macOS version and can
        // leave Settings on whatever page it last showed.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
        panel?.close()
        let state = GuideState()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 360), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Turn Off ⇧⌘4 in macOS"; window.titlebarAppearsTransparent = true
        window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: GuideView(state: state) { close() })
        // Top right of the screen, clear of System Settings, which opens near the middle.
        if let screen = NSScreen.main?.visibleFrame { window.setFrameOrigin(NSPoint(x: screen.maxX-350, y: screen.maxY-380)) }
        window.orderFrontRegardless(); panel = window
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard !state.done, !systemShortcutOn else { return }
                state.done = true
                DispatchQueue.main.asyncAfter(deadline: .now()+4) { close() }
            }
        }
    }
    static func close() { timer?.invalidate(); timer = nil; panel?.close(); panel = nil }
}

@MainActor private final class GuideState: ObservableObject { @Published var done = false }

private struct GuideView: View {
    @ObservedObject var state: GuideState
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.done {
                Label("Done. ⇧⌘4 now opens Still.", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                Text("You can close System Settings. Hold Space while choosing an area to capture a window.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Turn off macOS’s ⇧⌘4").font(.system(size: 15, weight: .semibold))
                Text("System Settings is open on Keyboard. This guide stays here while you follow it.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                step(1, "Click **Keyboard Shortcuts…** (in the Shortcuts section).")
                step(2, "Choose **Screenshots** in the list on the left.")
                step(3, "Untick **Save picture of selected area as a file** (⇧⌘4).")
                step(4, "Click **Done**.")
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Still notices when it’s off.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            HStack {
                if !state.done { Button("Open Keyboard Settings Again") { if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) } } }
                Spacer()
                Button(state.done ? "Close" : "Not Now", action: close).keyboardShortcut(.cancelAction)
            }.controlSize(.small)
        }.padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 18).frame(width: 330, alignment: .leading)
    }
    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22).background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
