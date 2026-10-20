import Foundation

/// A vector for semantic search, and the vector space it belongs to: vectors of different
/// models are never compared.
public struct Embedding: Sendable, Hashable {
    public var model: String
    public var vector: [Float]

    public init(model: String, vector: [Float]) {
        self.model = model
        self.vector = vector
    }
}

/// Turns text into vectors whose closeness follows meaning (sist2's text embeddings). The macOS
/// one uses NaturalLanguage's contextual embeddings; tests use a hashing one.
public protocol TextEmbedder: Sendable {
    /// nil when the text cannot be embedded (no model for its language, no words)
    func embed(_ text: String) throws -> Embedding?
}

/// What is learnt from an image: a feature print to find similar images, and labels saying what
/// it shows, so that words find it.
public protocol ImageAnalyzer: Sendable {
    func analyze(imageData: Data) throws -> ImageAnalysis?
}

public struct ImageAnalysis: Sendable, Hashable {
    public var featurePrint: Embedding?
    /// Most confident first
    public var labels: [String]

    public init(featurePrint: Embedding?, labels: [String]) {
        self.featurePrint = featurePrint
        self.labels = labels
    }
}

/// Cuts a document's text into the passages that get a vector each: about `size` characters,
/// ending at a paragraph or sentence end when there is one in the second half, at most `limit`
/// of them (the beginning of long documents). Search cuts the same way to show the passage that
/// matched, so this must stay deterministic.
public enum Chunker {
    public static let size = 400
    public static let limit = 8

    public static func chunks(_ text: String, size: Int = Chunker.size, limit: Int = Chunker.limit) -> [String] {
        var chunks: [String] = []
        var rest = Substring(text)
        while chunks.count < limit {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            guard let hardEnd = rest.index(rest.startIndex, offsetBy: size, limitedBy: rest.endIndex),
                  hardEnd < rest.endIndex else {
                chunks.append(String(rest))
                break
            }
            let half = rest.index(rest.startIndex, offsetBy: size / 2)
            let window = rest[half..<hardEnd]
            let end = window.lastIndex(where: \.isNewline).map { rest.index(after: $0) }
                ?? window.lastIndex(where: { "。！？.!?；;".contains($0) }).map { rest.index(after: $0) }
                ?? window.lastIndex(where: \.isWhitespace)
                ?? hardEnd
            chunks.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...]
        }
        return chunks.filter { !$0.isEmpty }
    }
}

/// Vectors as stored: unit length, quantized to 8 bits with one scale per vector (a quarter of
/// the space of 32-bit floats, and similarity barely moves).
public enum VectorCodec {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return vector }
        return vector.map { $0 / length }
    }

    /// 4 bytes of scale (Float32, little-endian), then one signed byte per dimension
    public static func encode(_ vector: [Float]) -> Data {
        let unit = normalized(vector)
        let largest = unit.reduce(0) { max($0, abs($1)) }
        let scale = largest > 0 ? largest / 127 : 1
        var data = Data(capacity: 4 + unit.count)
        withUnsafeBytes(of: scale.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        for value in unit {
            data.append(UInt8(bitPattern: Int8(clamping: Int((value / scale).rounded()))))
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float]? {
        guard data.count > 4 else { return nil }
        let bytes = [UInt8](data)
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let scale = Float(bitPattern: bits)
        return bytes[4...].map { Float(Int8(bitPattern: $0)) * scale }
    }

    /// The cosine similarity of a stored vector and a unit-length query, without decoding it
    public static func similarity(_ data: Data, unitQuery query: [Float]) -> Float? {
        guard data.count == 4 + query.count else { return nil }
        return data.withUnsafeBytes { raw -> Float in
            let bytes = raw.bindMemory(to: UInt8.self)
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            var sum: Float = 0
            for index in 0..<query.count {
                sum += Float(Int8(bitPattern: bytes[4 + index])) * query[index]
            }
            return sum * Float(bitPattern: bits)
        }
    }
}
