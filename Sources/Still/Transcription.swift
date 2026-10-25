import Foundation
import Speech

@MainActor final class Transcription: ObservableObject {
    @Published private(set) var running = false
    private var recognition: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var timeout: Task<Void, Never>?
    func transcribe(_ url: URL) async throws -> (String, String) {
        guard !running else { throw failure("Transcription is already running.") }
        let permission = await withCheckedContinuation { completion in SFSpeechRecognizer.requestAuthorization { completion.resume(returning: $0) } }
        guard permission == .authorized else { throw failure("Enable Speech Recognition for Still in System Settings to transcribe recordings.") }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw failure("On-device transcription isn’t available for this language. Install the language’s speech assets in macOS settings, then try again.") }
        running = true
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false; request.addsPunctuation = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                continuation = completion
                recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result, result.isFinal {
                            let words = result.bestTranscription.segments
                            var cues: [String] = []
                            for index in stride(from: 0, to: words.count, by: 10) {
                                let group = Array(words[index..<min(index+10, words.count)])
                                guard let first = group.first, let last = group.last else { continue }
                                cues.append("\(cues.count+1)\n\(Self.timestamp(first.timestamp)) --> \(Self.timestamp(last.timestamp+last.duration))\n\(group.map(\.substring).joined(separator: " "))\n")
                            }
                            self.finish(.success((result.bestTranscription.formattedString, cues.joined(separator: "\n"))))
                        } else if let error { self.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(self?.failure("Transcription timed out. Try a shorter recording.") ?? CancellationError()))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<(String, String), Error>) {
        guard let completion = continuation else { return }
        continuation = nil; timeout?.cancel(); timeout = nil; recognition?.cancel(); recognition = nil; running = false
        completion.resume(with: result)
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "Still.Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func timestamp(_ seconds: Double) -> String {
        let ms = max(0, Int(seconds*1000))
        return String(format: "%02d:%02d:%02d,%03d", ms/3_600_000, ms/60_000%60, ms/1000%60, ms%1000)
    }
}
