#if canImport(NaturalLanguage) && canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import SistCore
import Vision

/// Text vectors from NaturalLanguage's contextual embeddings (macOS 14): one model per script
/// family (Latin, Cyrillic, Chinese/Japanese/Korean...), a vector per token; a passage is the
/// mean of its token vectors. Each model's vectors form their own space, named after the model,
/// so a Chinese query is compared with Chinese passages only. Models are downloaded by the
/// system the first time they are needed; until then `embed` throws `modelUnavailable` and the
/// documents stay pending for a later run.
public final class ContextualTextEmbedder: TextEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: NLContextualEmbedding] = [:]
    /// Languages without any model
    private var unsupported = Set<String>()

    public init() {}

    public func embed(_ text: String) throws -> Embedding? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }

        // A model is not safe to use from several threads at once
        lock.lock()
        defer { lock.unlock() }
        guard let model = try model(for: language) else { return nil }
        let result = try model.embeddingResult(for: text, language: language)
        var sum = [Double](repeating: 0, count: model.dimension)
        var tokens = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for index in 0..<min(vector.count, sum.count) {
                sum[index] += vector[index]
            }
            tokens += 1
            return true
        }
        guard tokens > 0 else { return nil }
        return Embedding(model: "nl:\(model.modelIdentifier)#\(model.revision)",
                         vector: sum.map { Float($0 / Double(tokens)) })
    }

    /// Whether texts in this language can be embedded now; asks for the model otherwise
    public func isAvailable(for language: NLLanguage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? model(for: language)) != nil
    }

    private func model(for language: NLLanguage) throws -> NLContextualEmbedding? {
        if let model = models[language.rawValue] {
            return model
        }
        guard !unsupported.contains(language.rawValue) else { return nil }
        guard let model = NLContextualEmbedding(language: language) else {
            unsupported.insert(language.rawValue)
            return nil
        }
        guard model.hasAvailableAssets else {
            // Downloaded in the background, for the next run
            model.requestAssets { _, _ in }
            throw EmbeddingError.modelUnavailable
        }
        try model.load()
        models[language.rawValue] = model
        return model
    }
}

/// What Vision sees in an image: a feature print, whose distances say how alike two images look,
/// and classification labels (in English) above a confidence threshold.
public struct VisionImageAnalyzer: ImageAnalyzer {
    public static let minimumConfidence: Float = 0.3
    public static let maximumLabels = 8

    public init() {}

    public func analyze(imageData: Data) throws -> ImageAnalysis? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        let classification = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([featurePrint, classification])

        var embedding: Embedding?
        if let observation = featurePrint.results?.first {
            let data = observation.data
            let vector: [Float]
            switch observation.elementType {
            case .float:
                vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(observation.elementCount)) }
            case .double:
                vector = data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(observation.elementCount).map(Float.init) }
            default:
                vector = []
            }
            if !vector.isEmpty {
                embedding = Embedding(model: "vision-featureprint#\(featurePrint.revision)", vector: vector)
            }
        }
        let labels = (classification.results ?? [])
            .filter { $0.confidence >= Self.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(Self.maximumLabels)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return ImageAnalysis(featurePrint: embedding, labels: Array(labels))
    }
}
#endif
