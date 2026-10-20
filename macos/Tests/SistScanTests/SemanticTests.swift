import Foundation
import Testing
import SistCore
import SistStore
@testable import SistScan

/// Character trigrams hashed into 256 dimensions: texts sharing words come out close. Not
/// semantic, but deterministic, which is what the pipeline needs to be tested.
struct HashingEmbedder: TextEmbedder {
    func embed(_ text: String) throws -> Embedding? {
        let characters = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count >= 3 else { return nil }
        var vector = [Float](repeating: 0, count: 256)
        for start in 0...(characters.count - 3) {
            var hash: UInt32 = 2_166_136_261
            for scalar in String(characters[start..<(start + 3)]).unicodeScalars {
                hash = (hash ^ scalar.value) &* 16_777_619
            }
            vector[Int(hash % 256)] += 1
        }
        return Embedding(model: "test-hash", vector: vector)
    }
}

/// "Sees" the first bytes of the image data
struct FakeImageAnalyzer: ImageAnalyzer {
    func analyze(imageData: Data) throws -> ImageAnalysis? {
        let vector = imageData.prefix(8).map { Float($0) } + [Float](repeating: 1, count: max(0, 8 - imageData.count))
        return ImageAnalysis(featurePrint: Embedding(model: "test-image", vector: vector),
                             labels: imageData.first == 0x01 ? ["beach", "sand"] : ["document"])
    }
}

@Suite struct SemanticTests {
    func makeCatalog() async throws -> (Catalog, Source, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sist-semantic-\(UUID().uuidString)").path
        let catalog = try Catalog(path: directory + "/catalog.sqlite")
        return (catalog, try await catalog.addSource(root: "/r"), directory)
    }

    func doc(_ path: String, content: String? = nil, mime: String = "text/plain", thumbnail: Data? = nil) -> ParseResult {
        ParseResult(document: ParsedDocument(path: path, name: path.lastPathComponentFast, ext: path.pathExtensionFast,
                                             mime: mime, size: 10, mtime: 1_700_000_000, content: content),
                    thumbnails: thumbnail.map { [$0] } ?? [])
    }

    @Test func chunking() {
        let text = String(repeating: "第一段落的句子。", count: 40) + "\n" + String(repeating: "word ", count: 300)
        let chunks = Chunker.chunks(text, size: 100, limit: 50)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks[0].hasSuffix("。"))
        #expect(chunks.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        #expect(Chunker.chunks(text, size: 100, limit: 3).count == 3)
        #expect(Chunker.chunks("  short  ") == ["short"])
        #expect(Chunker.chunks("").isEmpty)
    }

    @Test func vectorCodec() throws {
        let vector: [Float] = [3, -4, 0, 0.5]
        let data = VectorCodec.encode(vector)
        #expect(data.count == 4 + 4)
        let decoded = try #require(VectorCodec.decode(data))
        let unit = VectorCodec.normalized(vector)
        for (a, b) in zip(decoded, unit) {
            #expect(abs(a - b) < 0.01)
        }
        #expect(abs((VectorCodec.similarity(data, unitQuery: unit) ?? 0) - 1) < 0.01)
        #expect(VectorCodec.similarity(data, unitQuery: [1, 0]) == nil)
    }

    @Test func indexingAndSearch() async throws {
        let (catalog, source, directory) = try await makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([
            doc("/r/otters.txt", content: "Sea otters float on their backs and crack shellfish with stones."),
            doc("/r/budget.txt", content: "The quarterly budget review moved to Thursday afternoon."),
            doc("/r/long.txt", content: String(repeating: "Filler text about nothing in particular. ", count: 30)
                + "\n\nThe river otters were seen near the old mill."),
            doc("/r/beach.jpg", mime: "image/jpeg", thumbnail: Data([0x01, 0x02, 0x03])),
            doc("/r/scan.jpg", mime: "image/jpeg", thumbnail: Data([0x01, 0x02, 0x04])),
            doc("/r/form.jpg", mime: "image/jpeg", thumbnail: Data([0x90, 0x80, 0x70])),
        ], source: source, scanId: scan)

        let indexer = SemanticIndexer(catalog: catalog, text: HashingEmbedder(), images: FakeImageAnalyzer())
        #expect(try await catalog.semanticStatus().pending == [.text: 3, .image: 3])
        #expect(try await indexer.run(batchSize: 2) == 6)
        let status = try await catalog.semanticStatus()
        #expect(status.pending == [.text: 0, .image: 0])
        #expect(status.indexed == [.text: 3, .image: 3])
        // Nothing left: a second run does nothing
        #expect(try await indexer.run() == 0)

        // The query embedded with the same model; the long document matches on its last passage
        var query = SearchQuery(text: "otters seen near the river")
        query.semantic = try HashingEmbedder().embed(query.text)
        query.semanticOnly = true
        let results = try await catalog.search(query)
        #expect(results.hits.first?.document.name == "long.txt")
        #expect(results.hits.first?.excerpt?.plainText.contains("river otters") == true)
        #expect(results.hits.first?.similarity ?? 0 > 0.3)
        #expect(results.hits.allSatisfy { $0.document.category == .text })

        // Mixed with full-text matches; filters apply to both
        var mixed = SearchQuery(text: "budget")
        mixed.semantic = try HashingEmbedder().embed("quarterly budget review")
        #expect(try await catalog.search(mixed).hits.first?.document.name == "budget.txt")
        mixed.pathPrefix = "/nowhere"
        #expect(try await catalog.search(mixed).hits.isEmpty)

        // Look-alike images, the image itself left out
        let beach = try #require(try await catalog.search(SearchQuery(text: "name:beach")).hits.first?.id)
        var similar = SearchQuery()
        similar.semantic = try await catalog.embedding(documentId: beach, kind: .image)
        similar.semanticOnly = true
        similar.excludedDocument = beach
        let lookAlikes = try await catalog.search(similar)
        #expect(lookAlikes.hits.map(\.document.name) == ["scan.jpg", "form.jpg"])

        // Labels make images findable by words, and show in the metadata
        #expect(try await catalog.search(SearchQuery(text: "sand")).hits.map(\.document.name).sorted() == ["beach.jpg", "scan.jpg"])
        #expect(try await catalog.document(id: beach)?.metadata[MetaKey.imageLabels] == .string("beach, sand"))
    }

    @Test func parsingAgainMakesADocumentPendingAgain() async throws {
        let (catalog, source, directory) = try await makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([doc("/r/a.txt", content: "first version about walruses")], source: source, scanId: scan)
        let indexer = SemanticIndexer(catalog: catalog, text: HashingEmbedder(), images: nil)
        try await indexer.run()

        scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([doc("/r/a.txt", content: "second version about penguins")], source: source, scanId: scan)
        #expect(try await catalog.semanticStatus().pending[.text] == 1)
        #expect(try await catalog.semanticStatus().vectors == 0)
        try await indexer.run()
        var query = SearchQuery()
        query.semantic = try HashingEmbedder().embed("penguins")
        #expect(try await catalog.search(query).hits.first?.excerpt?.plainText.contains("penguins") == true)
    }

    @Test func settings() async throws {
        let (catalog, _, directory) = try await makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(await !catalog.isSemanticSearchEnabled())
        try await catalog.setSetting(Catalog.semanticSearchSetting, "1")
        #expect(await catalog.isSemanticSearchEnabled())
        try await catalog.setSetting(Catalog.semanticSearchSetting, nil)
        #expect(await !catalog.isSemanticSearchEnabled())
    }
}

/// A model that is not there yet
struct DownloadingEmbedder: TextEmbedder {
    func embed(_ text: String) throws -> Embedding? {
        throw EmbeddingError.modelUnavailable
    }
}

@Suite struct SemanticRetryTests {
    @Test func documentsWaitForTheirModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sist-semantic-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let catalog = try Catalog(path: directory + "/catalog.sqlite")
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([ParseResult(document: ParsedDocument(
            path: "/r/a.txt", name: "a.txt", ext: "txt", mime: "text/plain", size: 1, mtime: 0, content: "some words here"))],
            source: source, scanId: scan)

        try await SemanticIndexer(catalog: catalog, text: DownloadingEmbedder(), images: nil).run()
        #expect(try await catalog.semanticStatus().pending[.text] == 1)
        try await SemanticIndexer(catalog: catalog, text: HashingEmbedder(), images: nil).run()
        #expect(try await catalog.semanticStatus().pending[.text] == 0)
    }
}
