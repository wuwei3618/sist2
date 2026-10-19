#if canImport(PDFKit)
import AppKit
import Foundation
import PDFKit
import SistCore

/// PDF with PDFKit, replacing MuPDF: text page by page, title and author, first page as
/// thumbnail, and OCR of pages without a text layer (scans) when enabled.
public struct PDFExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime == "application/pdf"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let document: PDFDocument?
        switch input {
        case .file(let path): document = PDFDocument(url: URL(fileURLWithPath: path))
        case .data(let data, _): document = PDFDocument(data: data)
        }
        guard let document else {
            throw ExtractionError.invalidFormat("not a PDF")
        }

        result.metadata[MetaKey.pages] = .int(Int64(document.pageCount))
        if let attributes = document.documentAttributes {
            result.title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.setMetadata(MetaKey.author, attributes[PDFDocumentAttribute.authorAttribute] as? String)
        }
        if result.title?.isEmpty == true {
            result.title = nil
        }

        if document.isLocked {
            context.log(.info, "Encrypted PDF, text not extracted")
        } else {
            for index in 0..<document.pageCount {
                if result.content.isFull { break }
                guard let page = document.page(at: index) else { continue }
                var text = page.string ?? ""
                if context.options.ocrDocuments,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let image = Self.render(page, maxPixelSize: 2500) {
                    text = (try? VisionOCR.recognizeText(in: image, languages: context.options.ocrLanguages)) ?? ""
                }
                result.content.appendLine(text)
            }
        }

        if context.options.thumbnailCount > 0, let page = document.page(at: 0),
           let image = Self.render(page, maxPixelSize: context.options.thumbnailSize),
           let data = ImageScaling.encode(image, quality: context.options.thumbnailQuality) {
            result.thumbnails.append(data)
        }
    }

    static func render(_ page: PDFPage, maxPixelSize: Int) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif
