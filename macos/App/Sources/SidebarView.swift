import SwiftUI
import SistCore
import SistScan
import SistStore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search
    @State private var sourceToRemove: SourceInfo?

    var body: some View {
        List {
            Section("文件夹") {
                ForEach(model.sources) { info in
                    SourceRow(info: info, progress: model.activeScans[info.id], isScanning: model.isScanning(info.id),
                              isSelected: search.sourceIds.contains(info.id))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(&search.sourceIds, info.id) }
                        .contextMenu {
                            if model.isScanning(info.id) {
                                Button("停止扫描") { model.cancelScan(info.id) }
                            } else {
                                Button("立即扫描") { model.scan(info.id) }
                            }
                            Button("在 Finder 中显示") { model.revealInFinder(info) }
                            Divider()
                            Button("从索引中移除…", role: .destructive) { sourceToRemove = info }
                        }
                }
                Button {
                    model.chooseFoldersToAdd()
                } label: {
                    Label("添加文件夹…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Section("类型") {
                ForEach(MimeCategory.allCases, id: \.self) { category in
                    let count = search.categoryCounts[category] ?? 0
                    if count > 0 || search.categories.contains(category) {
                        FilterRow(title: category.displayName, symbol: category.symbol, count: count,
                                  isSelected: search.categories.contains(category))
                            .onTapGesture { toggle(&search.categories, category) }
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("标签") {
                    ForEach(model.tags) { tag in
                        FilterRow(title: tag.name, symbol: "tag", count: tag.count,
                                  isSelected: search.tags.contains(tag.name))
                            .onTapGesture { toggle(&search.tags, tag.name) }
                    }
                }
            }

            if !search.categories.isEmpty || !search.sourceIds.isEmpty || !search.tags.isEmpty {
                Button("清除筛选") { search.clearFilters() }
                    .buttonStyle(.link)
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            "从索引中移除“\(sourceToRemove?.source.name ?? "")”？",
            isPresented: Binding(get: { sourceToRemove != nil }, set: { if !$0 { sourceToRemove = nil } }),
            presenting: sourceToRemove
        ) { info in
            Button("移除", role: .destructive) {
                Task { await model.removeSource(info.id) }
            }
        } message: { _ in
            Text("只删除索引数据，磁盘上的文件不受影响。")
        }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
}

struct SourceRow: View {
    let info: SourceInfo
    let progress: ScanProgress?
    let isScanning: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "folder")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.source.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .help(info.source.root)
    }

    private var subtitle: String {
        if let progress {
            let c = progress.counters
            switch progress.phase {
            case .walking: return "扫描中：\(Format.number(c.walked)) 个文件，已解析 \(Format.number(c.parsed))"
            case .finishing: return "正在收尾…"
            case .completed: return "完成"
            }
        }
        if isScanning { return "准备扫描…" }
        if let scan = info.lastScan, scan.status == .failed { return "上次扫描失败" }
        return "\(Format.number(info.documentCount)) 个文件 · \(Format.bytes(info.totalSize))"
    }
}

struct FilterRow: View {
    let title: String
    let symbol: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            Text(Format.number(count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}
