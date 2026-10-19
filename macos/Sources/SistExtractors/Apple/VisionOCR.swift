#if canImport(Vision)
import CoreGraphics
import Foundation
import Vision

/// Text recognition with the Vision framework, replacing sist2's tesseract dependency. Runs on
/// device and supports Simplified/Traditional Chinese, Japanese, Korean and the Latin languages.
enum VisionOCR {
    static func recognizeText(in image: CGImage, languages: [String]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
#endif
