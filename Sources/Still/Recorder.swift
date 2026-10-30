import AppKit
import ScreenCaptureKit
import AVFoundation
import ApplicationServices
import Carbon
import StillCore

@MainActor final class Recorder: NSObject, ObservableObject, SCContentSharingPickerObserver, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published var recording = false
    @Published var choosing = false
    @Published var stopping = false
    @Published var paused = false
    @Published var pausing = false
    @Published var startedAt: Date?
    @Published var elapsed: Double = 0
    @Published var cameraSession: AVCaptureSession?
    var systemAudio = false
    var microphone = false
    var onComplete: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var completedMetadata = RecordingMetadata()
    private(set) var completedCameraURL: URL?
    private var metadata = RecordingMetadata()
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var filter: SCContentFilter?
    private var starting = false
    private var captureRegion: CGRect?
    private var targetRect = CGRect.zero
    private var segments: [URL] = []
    private var cameraSegments: [URL] = []
    private var camera: CameraRecorder?
    private var segmentCameraOffset: Double = 0
    private var cameraFailed = false
    private var timer: Timer?
    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var segmentStartedAt: Date?
    private var completedDuration: Double = 0
    private var finalizing = false
    func recordArea(screen: NSScreen, rect: CGRect) {
        guard !recording, !choosing, !stopping else { return }
        newSession(); captureRegion = rect; choosing = true; starting = true
        targetRect = CGRect(x: screen.frame.minX+rect.minX, y: NSScreen.screens[0].frame.maxY-screen.frame.maxY+rect.minY, width: rect.width, height: rect.height)
        Task { do { let filter = try await ScreenCaptureAPI.filter(screen: screen); await start(filter) } catch { fail(error) } }
    }
    func choose() {
        guard !recording, !choosing, !stopping else { return }
        newSession(); choosing = true; captureRegion = nil
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration(); config.allowedPickerModes = [.singleDisplay, .singleWindow]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.sam.Still"]; config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config; picker.add(self); picker.isActive = true; picker.present()
        // If the picker never answers, don't stay stuck in "choosing" (that blocks every later recording).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if self.choosing, !self.starting, !self.recording { self.choosing = false; self.deactivatePicker(); self.onCancel?() }
        }
    }
    private func newSession() {
        metadata = RecordingMetadata(); metadata.cursorIncludedInVideo = false; metadata.presentation = Preferences.shared.recordingPresentation
        metadata.defaultShowCursor = Preferences.shared.recordingCursor; metadata.defaultShowClicks = Preferences.shared.recordingClicks; metadata.defaultShowKeystrokes = Preferences.shared.recordingKeys
        cameraFailed = false; segments = []; cameraSegments = []; completedDuration = 0; elapsed = 0; paused = false; pausing = false; finalizing = false; completedCameraURL = nil
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { Task { @MainActor in self.choosing = false; self.deactivatePicker(); self.onCancel?() } }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.choosing, !self.starting else { return }; self.starting = true
            if #available(macOS 15.2, *) {
                if filter.style == .window, let window = filter.includedWindows.first { self.targetRect = window.frame }
                else if let display = filter.includedDisplays.first { self.targetRect = CGDisplayBounds(display.displayID) }
            }
            if self.targetRect.isEmpty { self.targetRect = CGDisplayBounds(CGMainDisplayID()) }
            await self.start(filter)
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) { Task { @MainActor in self.fail(error) } }
    private func start(_ filter: SCContentFilter) async {
        do {
            self.filter = filter
            if microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NSError(domain: "Still", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enable microphone access in System Settings or turn off microphone recording."]) }
            }
            if Preferences.shared.recordingKeys, !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            if Preferences.shared.recordingCamera && !cameraFailed {
                let camera = self.camera ?? CameraRecorder(); self.camera = camera
                try await camera.start(deviceID: Preferences.shared.recordingCameraID); cameraSession = camera.session
            }
            let scale = Double(filter.pointPixelScale), config = SCStreamConfiguration()
            let originalWidth = max(2, Double(captureRegion?.width ?? filter.contentRect.width)*scale), originalHeight = max(2, Double(captureRegion?.height ?? filter.contentRect.height)*scale)
            let maxSize = Preferences.shared.recordingResolution, ratio = maxSize == 0 ? 1 : min(1, Double(maxSize)/max(originalWidth, originalHeight))
            config.width = max(2, Int(originalWidth*ratio)/2*2); config.height = max(2, Int(originalHeight*ratio)/2*2)
            metadata.presentation?.cameraSize = min(0.6, max(0.05, Preferences.shared.recordingCameraSize*scale/Double(config.width)))
            if let captureRegion { config.sourceRect = captureRegion }
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(Preferences.shared.recordingFPS))
            // The cursor is recorded separately so its size, motion and click effects remain editable.
            config.microphoneCaptureDeviceID = Preferences.shared.recordingMicrophoneID.isEmpty ? nil : Preferences.shared.recordingMicrophoneID
            config.showsCursor = false; config.capturesAudio = systemAudio; config.captureMicrophone = microphone; config.excludesCurrentProcessAudio = true; config.queueDepth = 5
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-\(UUID()).mp4"); outputURL = url
            let recordingConfig = SCRecordingOutputConfiguration(); recordingConfig.outputURL = url; recordingConfig.outputFileType = .mp4; recordingConfig.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: recordingConfig, delegate: self), stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream; self.output = output; try stream.addRecordingOutput(output); try await stream.startCapture()
        } catch { fail(error) }
    }
    func togglePause() {
        guard recording, !stopping, !pausing else { return }
        if paused { guard let filter else { return }; starting = true; paused = false; Task { await start(filter) } }
        else { pausing = true; stopMonitoring(); Task { do { try await stream?.stopCapture() } catch { fail(error) } } }
    }
    /// Stop was pressed while a resumed segment was still starting; stop as soon as it has.
    private var stopWhenStarted = false
    func stop() {
        guard recording, !stopping, !pausing else { return }
        if starting { stopWhenStarted = true; return }
        stopping = true; stopMonitoring()
        if paused { Task { await finishAll() } }
        else { Task { do { try await stream?.stopCapture() } catch { fail(error) } } }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard recordingOutput === self.output else { return }
            self.choosing = false; self.starting = false; self.recording = true; self.paused = false
            if self.stopWhenStarted { self.stopWhenStarted = false; DispatchQueue.main.async { self.stop() } }
            if self.startedAt == nil { self.startedAt = Date() }
            self.segmentStartedAt = Date()
            if let cameraDate = self.camera?.startedAt { self.segmentCameraOffset = max(0, Date().timeIntervalSince(cameraDate)); self.metadata.cameraOffset = 0 }
            self.startMonitoring()
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let duration = recordingOutput.recordedDuration.seconds
        Task { @MainActor in
            guard recordingOutput === self.output, let url = self.outputURL, !self.finalizing else { return }
            self.outputURL = nil; self.segments.append(url); self.completedDuration += duration.isFinite ? duration : 0; self.elapsed = self.completedDuration
            self.stopMonitoring(); self.stream = nil; self.output = nil
            do {
                if let cameraURL = try await self.camera?.stop() {
                    defer { try? FileManager.default.removeItem(at: cameraURL) }
                    let aligned = FileManager.default.temporaryDirectory.appendingPathComponent("Still-camera-aligned-\(UUID()).mp4")
                    try await VideoEngine.trim(cameraURL, start: self.segmentCameraOffset, duration: duration, to: aligned)
                    self.cameraSegments.append(aligned)
                }
            }
            catch {
                self.cameraFailed = true
                for file in self.cameraSegments { try? FileManager.default.removeItem(at: file) }
                self.cameraSegments = []
                self.onWarning?("Camera processing failed. The screen recording is being preserved without the camera: \(error.localizedDescription)")
            }
            self.cameraSession = nil
            if self.pausing { self.pausing = false; self.paused = true; self.segmentStartedAt = nil }
            else { self.stopping = true; await self.finishAll() }
        }
    }
    private func finishAll() async {
        guard !finalizing else { return }; finalizing = true
        do {
            guard !segments.isEmpty else { throw VideoError.noVideo }
            let result: URL
            if segments.count == 1 { result = segments[0] }
            else { result = FileManager.default.temporaryDirectory.appendingPathComponent("Still-recording-\(UUID()).mp4"); try await VideoEngine.concatenate(segments, to: result); for url in segments { try? FileManager.default.removeItem(at: url) } }
            if cameraSegments.count == 1 { completedCameraURL = cameraSegments[0] }
            else if !cameraSegments.isEmpty { let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-camera-\(UUID()).mp4"); try await VideoEngine.concatenate(cameraSegments, to: url); completedCameraURL = url; for file in cameraSegments { try? FileManager.default.removeItem(at: file) } }
            completedMetadata = metadata; reset(); onComplete?(result)
        } catch { fail(error) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { Task { @MainActor in guard recordingOutput === self.output else { return }; self.fail(error) } }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) { Task { @MainActor in if stream === self.stream, !self.stopping && !self.pausing { self.fail(error) } } }
    private var currentTime: Double { completedDuration+(segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    private func pointer() -> CGPoint {
        let mouse = NSEvent.mouseLocation, top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: (mouse.x-targetRect.minX)/max(1, targetRect.width), y: (top-mouse.y-targetRect.minY)/max(1, targetRect.height))
    }
    private func startMonitoring() {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.recording, !self.paused else { return }
            let p = self.pointer(), time = self.currentTime
            // Published, so only when the whole seconds shown change: 60 updates a second redraw every observer.
            if Int(time) != Int(self.elapsed) { self.elapsed = time }
            self.metadata.pointer.append(PointerSample(time: time, x: p.x, y: p.y))
        } }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in Task { @MainActor in guard let self, self.recording, !self.paused else { return }; let p = self.pointer(); if p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1 { self.metadata.clicks.append(ClickSample(time: self.currentTime, x: p.x, y: p.y)) } } }
        if Preferences.shared.recordingKeys {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let flags = event.modifierFlags, characters = event.charactersIgnoringModifiers ?? ""
                Task { @MainActor in
                    guard let self, self.recording, !self.paused else { return }
                    // Never record what is typed into a password field.
                    if IsSecureEventInputEnabled() { return }
                    if Preferences.shared.recordingCommandKeysOnly && !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) { return }
                    var text = ""; if flags.contains(.control) { text += "⌃" }; if flags.contains(.option) { text += "⌥" }; if flags.contains(.shift) { text += "⇧" }; if flags.contains(.command) { text += "⌘" }
                    text += characters.uppercased(); self.metadata.keys.append(KeySample(time: self.currentTime, text: String(text.prefix(50))))
                }
            }
        }
    }
    private func stopMonitoring() { timer?.invalidate(); timer = nil; if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil } }
    private func deactivatePicker() { SCContentSharingPicker.shared.remove(self); SCContentSharingPicker.shared.isActive = false }
    private func reset() { stopMonitoring(); stream = nil; output = nil; outputURL = nil; filter = nil; recording = false; choosing = false; starting = false; stopping = false; pausing = false; paused = false; stopWhenStarted = false; startedAt = nil; segmentStartedAt = nil; captureRegion = nil; finalizing = false; cameraSession = nil; deactivatePicker() }
    private func fail(_ error: Error) {
        guard stream != nil || choosing || starting || recording || finalizing else { return }
        let old = stream, urls = segments+(outputURL.map { [$0] } ?? [])+cameraSegments
        let capturedCamera = camera
        reset()
        Task {
            try? await old?.stopCapture()
            var recoveryURLs = urls
            if let cameraURL = try? await capturedCamera?.stop() { recoveryURLs.append(cameraURL) }
            let recovery = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/Recovery/\(UUID())", isDirectory: true)
            var count = 0
            for url in Set(recoveryURLs) {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { continue }
                do { try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true); try FileManager.default.moveItem(at: url, to: recovery.appendingPathComponent(url.lastPathComponent)); count += 1 } catch { /* Leave the original temporary file intact if recovery cannot move it. */ }
            }
            onError?(error.localizedDescription + (count > 0 ? "\n\n\(count) recording files were preserved in \(recovery.path)." : ""))
        }
    }
}
