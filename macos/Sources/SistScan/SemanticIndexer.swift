import Foundation
import SistCore
import SistStore

/// Brings the semantic index up to date: embeds the passages of documents parsed since they
/// were last analysed, and analyses images (feature print and labels) from their thumbnails.
/// Separate from parsing, so that it can run after scans in the background, catch up on
/// documents indexed before it was turned on, and never slow a scan down.
public struct SemanticIndexer: Sendable {
    public let catalog: Catalog
    public let text: (any TextEmbedder)?
    public let images: (any ImageAnalyzer)?

    public init(catalog: Catalog, text: (any TextEmbedder)?, images: (any ImageAnalyzer)?) {
        self.catalog = catalog
        self.text = text
        self.images = images
    }

    /// Analyses every pending document, in batches. Returns how many were analysed; `progress`
    /// gets the count so far and the count still pending at the start.
    @discardableResult
    public func run(batchSize: Int = 32,
                    progress: (@Sendable (_ done: Int, _ pending: Int) -> Void)? = nil) async throws -> Int {
        let status = try await catalog.semanticStatus()
        var kinds: [EmbeddingKind] = []
        if text != nil { kinds.append(.text) }
        if images != nil { kinds.append(.image) }
        let pending = kinds.reduce(0) { $0 + (status.pending[$1] ?? 0) }
        var done = 0
        for kind in kinds {
            var seen = Set<Int64>()
            while true {
                try Task.checkCancellation()
                let batch = try await catalog.pendingDocuments(kind: kind, limit: batchSize)
                    .filter { seen.insert($0.id).inserted }
                // A document that comes back unchanged was not stored (it was parsed again meanwhile
                // and comes back with its new scan id): leave it for the next run
                guard !batch.isEmpty else { break }
                let updates = await withTaskGroup(of: SemanticUpdate?.self) { group in
                    for document in batch {
                        group.addTask { self.analyze(document) }
                    }
                    var updates: [SemanticUpdate] = []
                    for await update in group {
                        if let update {
                            updates.append(update)
                        }
                    }
                    return updates
                }
                try await catalog.store(updates)
                done += batch.count
                progress?(done, pending)
            }
        }
        return done
    }

    /// nil when the document should be tried again later (a model still being downloaded)
    func analyze(_ document: PendingDocument) -> SemanticUpdate? {
        var update = SemanticUpdate(documentId: document.id, scanId: document.scanId, kind: document.kind, embeddings: [])
        switch document.kind {
        case .text:
            guard let text, let content = document.content else { break }
            for (chunk, passage) in Chunker.chunks(content).enumerated() {
                do {
                    if let embedding = try text.embed(passage) {
                        update.embeddings.append((chunk, embedding))
                    }
                } catch EmbeddingError.modelUnavailable {
                    return nil
                } catch {
                    continue
                }
            }
        case .image:
            guard let images, let thumbnail = document.thumbnail,
                  let analysis = try? images.analyze(imageData: thumbnail) else { break }
            if let featurePrint = analysis.featurePrint {
                update.embeddings.append((0, featurePrint))
            }
            update.labels = analysis.labels
        }
        return update
    }
}
