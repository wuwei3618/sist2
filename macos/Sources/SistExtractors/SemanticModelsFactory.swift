import SistCore

/// The platform's models for semantic search: NaturalLanguage and Vision on macOS, none elsewhere.
public enum SemanticModels {
    public static func textEmbedder() -> (any TextEmbedder)? {
        #if canImport(NaturalLanguage) && canImport(Vision)
        ContextualTextEmbedder()
        #else
        nil
        #endif
    }

    public static func imageAnalyzer() -> (any ImageAnalyzer)? {
        #if canImport(NaturalLanguage) && canImport(Vision)
        VisionImageAnalyzer()
        #else
        nil
        #endif
    }
}
