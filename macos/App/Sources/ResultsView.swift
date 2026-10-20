import SwiftUI
import SistCore
import SistStore

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search

    var body: some View {
        Group {
            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("还没有建立索引的文件夹", systemImage: "folder.badge.plus")
                } description: {
                    Text("添加文件夹后，Sist 会提取文件名、正文、元数据和缩略图，之后即可全文搜索。")
                } actions: {
                    Button("添加文件夹…") { model.chooseFoldersToAdd() }
                }
            } else if search.hits.isEmpty && !search.isSearching {
                if search.text.isEmpty {
                    ContentUnavailableView("没有文件", systemImage: "doc.text.magnifyingglass",
                                           description: Text("调整左侧的筛选条件试试。"))
                } else {
                    ContentUnavailableView.search(text: search.text)
                }
            } else {
                switch search.displayMode {
                case .list: ResultList()
                case .grid: ResultGrid()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ActiveFilters()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
    }
}

private struct ResultList: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search

    var body: some View {
        @Bindable var search = search
        List(selection: $search.selection) {
            ForEach(search.hits) { hit in
                ResultRow(hit: hit, terms: search.highlightTerms)
                    .tag(hit.id)
                    .onAppear {
                        if hit.id == search.hits.last?.id {
                            search.loadMore()
                        }
                    }
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            DocumentMenu(documents: documents(ids))
        } primaryAction: { ids in
            documents(ids).forEach { model.open($0) }
        }
        .onKeyPress(.space) {
            guard let hit = search.selectedHit else { return .ignored }
            if search.previewURL == nil {
                model.preview(hit.document)
            } else {
                search.previewURL = nil
            }
            return .handled
        }
    }

    private func documents(_ ids: Set<Int64>) -> [DocumentSummary] {
        search.hits.filter { ids.contains($0.id) }.map(\.document)
    }
}

private struct ResultGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(search.hits) { hit in
                    GridCell(hit: hit, isSelected: search.selection.contains(hit.id))
                        .onTapGesture(count: 2) { model.open(hit.document) }
                        .onTapGesture { search.selection = [hit.id] }
                        .contextMenu { DocumentMenu(documents: [hit.document]) }
                        .onAppear {
                            if hit.id == search.hits.last?.id {
                                search.loadMore()
                            }
                        }
                }
            }
            .padding(12)
        }
    }
}

struct ResultRow: View {
    let hit: SearchHit
    let terms: [String]

    var body: some View {
        let document = hit.document
        HStack(alignment: .top, spacing: 10) {
            ThumbnailView(document: document, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(Highlighter.highlight(document.name, terms: terms).attributed)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let title = document.title, !title.isEmpty, title != document.name {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                }
                Text(document.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let excerpt = hit.excerpt, excerpt.hasHighlights {
                    Text(excerpt.attributed)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bytes(document.size))
                Text(document.modificationDate, format: .dateTime.year().month().day())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}

private struct GridCell: View {
    let hit: SearchHit
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(document: hit.document, size: 140)
                .frame(height: 140)
            Text(hit.document.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

struct DocumentMenu: View {
    @Environment(AppModel.self) private var model
    let documents: [DocumentSummary]

    var body: some View {
        if let first = documents.first {
            Button("打开") { documents.forEach { model.open($0) } }
            Button("快速查看") { model.preview(first) }
            Button("在 Finder 中显示") { first.revealInFinder() }
            Divider()
            Button("拷贝路径") { first.copyPath() }
            if first.isArchiveMember {
                Text("位于压缩包内：打开时先解压到临时文件夹")
            }
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search

    var body: some View {
        HStack(spacing: 12) {
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            Text("\(Format.number(search.total)) 个结果")
            Text("\(Int(search.elapsed * 1000)) ms")
                .foregroundStyle(.tertiary)
            Spacer()
            if let progress = model.activeScans.values.first {
                Text("扫描中：\(Format.number(progress.counters.walked)) 个文件，已解析 \(Format.number(progress.counters.parsed))，队列 \(progress.queued)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
