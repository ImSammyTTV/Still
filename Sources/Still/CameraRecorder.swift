import AppKit
import AVFoundation
import StillCore

final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "local.sam.Still.camera")
    private var configured = false
    private var configuredID = ""
    private var completed: Result<URL, Error>?
    private var finish: CheckedContinuation<URL?, Error>?
    private var currentURL: URL?
    private(set) var startedAt: Date?
    func start(deviceID: String = "") async throws {
        let authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { throw NSError(domain: "Still", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera access is off. Enable it in System Settings or turn off Record Camera."]) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured || self.configuredID != deviceID {
                        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
                        guard let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .video) : devices.first(where: { $0.uniqueID == deviceID }) else { throw NSError(domain: "Still", code: 2, userInfo: [NSLocalizedDescriptionKey: "No camera is connected."]) }
                        let input = try AVCaptureDeviceInput(device: device)
                        self.session.beginConfiguration(); self.session.sessionPreset = .high
                        for existing in self.session.inputs { self.session.removeInput(existing) }
                        if self.session.outputs.contains(self.output) { self.session.removeOutput(self.output) }
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else { self.session.commitConfiguration(); throw VideoError.export }
                        self.session.addInput(input); self.session.addOutput(self.output); self.session.commitConfiguration(); self.configured = true; self.configuredID = deviceID
                    }
                    self.session.startRunning()
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-camera-\(UUID()).mov")
                    self.completed = nil; self.currentURL = url; self.startedAt = Date(); self.output.startRecording(to: url, recordingDelegate: self)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.output.isRecording else { self.session.stopRunning(); if let completed = self.completed { continuation.resume(with: completed.map { Optional($0) }); self.completed = nil } else { continuation.resume(returning: nil) }; return }
                self.finish = continuation; self.output.stopRecording()
            }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.session.stopRunning()
            let continuation = self.finish; self.finish = nil
            if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true { if let continuation { continuation.resume(throwing: error) } else { self.completed = .failure(error) } }
            else { if let continuation { continuation.resume(returning: outputFileURL) } else { self.completed = .success(outputFileURL) } }
        }
    }
}
