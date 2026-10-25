import Vision
import CoreML
import CoreGraphics

public enum TextRecognition {
    public static func recognize(_ image: CGImage, language: String? = nil, keepLineBreaks: Bool = true) throws -> String {
        let results = try observations(image, language: language)
        return results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: keepLineBreaks ? "\n" : " ")
    }
    public static func lineBounds(_ image: CGImage) throws -> [CGRect] {
        try observations(image).map { result in
            let box = result.boundingBox
            return CGRect(x: box.minX*Double(image.width), y: (1-box.maxY)*Double(image.height), width: box.width*Double(image.width), height: box.height*Double(image.height))
        }
    }
    private static func observations(_ image: CGImage, language: String? = nil) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = language == nil
        if let language { request.recognitionLanguages = [language] }
        // Small screenshot jobs run reliably on CPU without a first-run Neural Engine model compilation.
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) { request.setComputeDevice(cpu, for: stage) }
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }
    public static func codes(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}
