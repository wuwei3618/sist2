import AppKit
import SwiftUI
import SistStore

/// The stored thumbnail, or the kind's symbol when there is none.
struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let document: DocumentSummary
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                Image(systemName: document.category.symbol)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: document.id) {
            image = await ThumbnailCache.shared.image(for: document, catalog: model.catalog)
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 2000
    }

    func image(for document: DocumentSummary, catalog: Catalog?) async -> NSImage? {
        guard document.thumbnailCount > 0, let catalog else { return nil }
        // mtime in the key: a file parsed again gets its new thumbnail
        let key = "\(document.id)-\(document.mtime)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = try? await catalog.thumbnail(documentId: document.id),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
