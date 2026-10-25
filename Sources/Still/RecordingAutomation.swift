import Foundation

@MainActor final class RecordingAutomation {
    static let shared = RecordingAutomation()
    private var active = false
    private var pending: Task<Void, Never>?
    func update(recording: Bool, notify: @escaping (String) -> Void) {
        guard recording != active else { return }
        let wasActive = active; active = recording
        guard Preferences.shared.recordingAutomation || wasActive else { return }
        let name = recording ? Preferences.shared.recordingStartShortcut : Preferences.shared.recordingEndShortcut
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previous = pending
        pending = Task {
            await previous?.value
            do { try await Self.run(name) }
            catch { notify("Recording automation failed. Check the shortcut named “\(name)” in Shortcuts.") }
        }
    }
    private static func run(_ name: String) async throws {
        try await withCheckedThrowingContinuation { completion in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); process.arguments = ["run",name]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { value in if value.terminationStatus == 0 { completion.resume() } else { completion.resume(throwing: CocoaError(.executableRuntimeMismatch)) } }
            do { try process.run() } catch { process.terminationHandler = nil; completion.resume(throwing: error) }
        }
    }
}
