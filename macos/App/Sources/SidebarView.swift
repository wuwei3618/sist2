import AppKit
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
                    SourceNode(info: info, sourceToRemove: $sourceToRemove)
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

            if search.hasFilters {
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

/// A source, expandable into its folder tree. Clicking the source filters to it; clicking a
/// folder filters to that folder.
private struct SourceNode: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search
    let info: SourceInfo
    @Binding var sourceToRemove: SourceInfo?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                FolderChildren(sourceId: info.id, parent: info.source.root)
            }
        } label: {
            SourceRow(info: info, progress: model.activeScans[info.id], isScanning: model.isScanning(info.id),
                      isSelected: search.sourceIds.contains(info.id))
                .contentShape(Rectangle())
                .onTapGesture {
                    if search.sourceIds.contains(info.id) {
                        search.sourceIds.remove(info.id)
                    } else {
                        search.sourceIds.insert(info.id)
                    }
                }
                .contextMenu {
                    if model.isScanning(info.id) {
                        Button("停止扫描") { model.cancelScan(info.id) }
                    } else {
                        Button("立即扫描") { model.scan(info.id) }
                        Button("重建索引") { model.rebuild(info.id) }
                    }
                    Button("在 Finder 中显示") { model.revealInFinder(info) }
                    Divider()
                    Button("从索引中移除…", role: .destructive) { sourceToRemove = info }
                }
        }
    }
}

/// The subfolders of a folder, loaded when shown and again after each scan.
private struct FolderChildren: View {
    @Environment(AppModel.self) private var model
    let sourceId: Int64
    let parent: String
    @State private var folders: [FolderInfo]?

    var body: some View {
        Group {
            if let folders {
                if folders.isEmpty {
                    Text("没有子文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        FolderNode(folder: folder)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: model.catalogVersion) {
            folders = (try? await model.catalog?.folders(sourceId: sourceId, parent: parent)) ?? []
        }
    }
}

private struct FolderNode: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search
    let folder: FolderInfo
    @State private var isExpanded = false

    var body: some View {
        if folder.hasSubfolders {
            DisclosureGroup(isExpanded: $isExpanded) {
                if isExpanded {
                    FolderChildren(sourceId: folder.sourceId, parent: folder.path)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var filter: FolderFilter {
        FolderFilter(sourceId: folder.sourceId, path: folder.path, name: folder.name)
    }

    private var label: some View {
        FilterRow(title: folder.name, symbol: "folder", count: folder.count, isSelected: search.folder == filter)
            .onTapGesture {
                search.folder = search.folder == filter ? nil : filter
            }
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                }
                Button("重新扫描此文件夹") { model.scanFolder(filter) }
                    .disabled(model.isScanning(folder.sourceId))
            }
            .help("\(folder.path)\n\(Format.number(folder.count)) 个文件 · \(Format.bytes(folder.size))")
    }
}

struct SourceRow: View {
    let info: SourceInfo
    let progress: ScanProgress?
    let isScanning: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "externaldrive")
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
            case .walking:
                let kind = progress.isRebuild ? "重建中" : (progress.scopes == nil ? "扫描中" : "更新中")
                return "\(kind)：\(Format.number(c.walked)) 个文件，已解析 \(Format.number(c.parsed))"
            case .finishing: return "正在收尾…"
            case .completed: return "完成"
            }
        }
        if isScanning { return "准备扫描…" }
        if let scan = info.lastScan, scan.status == .failed { return "上次扫描失败" }
        if info.source.needsRebuild { return "设置已更改，下次扫描将重建" }
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
                .lineLimit(1)
            Spacer()
            Text(Format.number(count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}
