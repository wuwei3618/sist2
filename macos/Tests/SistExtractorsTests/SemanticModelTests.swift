#if canImport(NaturalLanguage) && canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import Testing
import UniformTypeIdentifiers
import SistCore
@testable import SistExtractors

@Suite struct SemanticModelTests {
    /// A PNG of two coloured halves
    func image(_ left: CGColor, _ right: CGColor) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(left)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 128))
        context.setFillColor(right)
        context.fill(CGRect(x: 64, y: 0, width: 64, height: 128))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func imageFeaturePrints() throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let analyzer = VisionImageAnalyzer()
        let a = try #require(try analyzer.analyze(imageData: image(red, blue))?.featurePrint)
        let b = try #require(try analyzer.analyze(imageData: image(red, blue))?.featurePrint)
        let c = try #require(try analyzer.analyze(imageData: image(blue, red))?.featurePrint)
        #expect(a.model.hasPrefix("vision-featureprint#"))
        #expect(!a.vector.isEmpty)
        let unit = VectorCodec.normalized(a.vector)
        let same = try #require(VectorCodec.similarity(VectorCodec.encode(b.vector), unitQuery: unit))
        let other = try #require(VectorCodec.similarity(VectorCodec.encode(c.vector), unitQuery: unit))
        #expect(same > other)
        #expect(try analyzer.analyze(imageData: Data("not an image".utf8)) == nil)
    }

    /// Only where the system already has the English model: tests do not download it
    @Test func textEmbeddings() throws {
        guard NLContextualEmbedding(language: .english)?.hasAvailableAssets == true else { return }
        let embedder = ContextualTextEmbedder()
        let query = try #require(try embedder.embed("How do I cook pasta?"))
        let close = try #require(try embedder.embed("Boil the spaghetti in salted water for ten minutes."))
        let far = try #require(try embedder.embed("The quarterly tax return is due in April."))
        #expect(query.model == close.model)
        let unit = VectorCodec.normalized(query.vector)
        let closeScore = try #require(VectorCodec.similarity(VectorCodec.encode(close.vector), unitQuery: unit))
        let farScore = try #require(VectorCodec.similarity(VectorCodec.encode(far.vector), unitQuery: unit))
        #expect(closeScore > farScore)
    }
}
#endif
