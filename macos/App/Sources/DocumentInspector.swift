import SwiftUI
import SistCore
import SistStore

struct DocumentInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search
    let hit: SearchHit?
    @State private var detail: DocumentDetail?
    @State private var newTag = ""

    var body: some View {
        Group {
            if let detail, detail.summary.id == hit?.id {
                content(detail)
            } else if hit == nil {
                ContentUnavailableView("未选择文件", systemImage: "doc.text.magnifyingglass")
            } else {
                ProgressView()
            }
        }
        .task(id: hit?.id) {
            await load()
        }
    }

    private func load() async {
        guard let id = hit?.id else {
            detail = nil
            return
        }
        detail = try? await model.catalog?.document(id: id)
    }

    @ViewBuilder
    private func content(_ detail: DocumentDetail) -> some View {
        let document = detail.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    ThumbnailView(document: document, size: 220)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.displayTitle)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    Text(document.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("打开") { document.open() }
                    Button("快速查看") { search.previewURL = document.fileURL }
                    Button("在 Finder 中显示") { document.revealInFinder() }
                }
                .controlSize(.small)

                if let error = detail.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                GroupBox("信息") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        infoRow("类型", document.mime ?? "未知")
                        infoRow("大小", Format.bytes(document.size))
                        infoRow("修改时间", Format.date(document.modificationDate))
                        ForEach(detail.metadata.keys.sorted(), id: \.self) { key in
                            infoRow(MetadataLabel.name(for: key), detail.metadata[key]?.description ?? "")
                        }
                        if let checksum = detail.checksum {
                            infoRow("SHA-1", checksum)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("标签") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.tags, id: \.self) { tag in
                            HStack {
                                Label(tag, systemImage: "tag")
                                Spacer()
                                Button {
                                    Task {
                                        await model.removeTag(tag, from: document.id)
                                        await load()
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        TextField("添加标签", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let tag = newTag
                                newTag = ""
                                Task {
                                    await model.addTag(tag, to: document.id)
                                    await load()
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let content = detail.content {
                    GroupBox("内容") {
                        Text(Highlighter.highlight(content, terms: search.highlightTerms).attributed)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}
