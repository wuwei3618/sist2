import QuickLook
import SwiftUI
import SistStore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var search = search

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ResultsView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 540)
        } detail: {
            DocumentInspector(hit: search.selectedHit)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        }
        .searchable(text: $search.text, placement: .toolbar, prompt: "搜索文件名、内容、路径…")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("显示方式", selection: $search.displayMode) {
                    Image(systemName: "list.bullet").tag(DisplayMode.list)
                    Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                }
                .pickerStyle(.segmented)
                .help("列表 / 缩略图")

                Menu {
                    Picker("排序", selection: $search.sort) {
                        ForEach(SearchSort.allCases, id: \.self) { sort in
                            Text(sort.displayName).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                    Toggle("包含压缩包内的文件", isOn: $search.includeArchiveMembers)
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .help("排序")

                FilterButton()

                Button {
                    openWindow(id: "stats")
                } label: {
                    Label("统计", systemImage: "chart.bar.xaxis")
                }
                .help("索引统计")
            }
        }
        .quickLookPreview($search.previewURL)
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
        .overlay(alignment: .bottom) {
            if let message = model.errorMessage ?? search.errorMessage {
                ErrorBanner(message: message) {
                    model.errorMessage = nil
                }
                .padding()
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
            Spacer()
            Button("关闭", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 560)
    }
}

/// Size and modification date filters, in a popover from the toolbar
struct FilterButton: View {
    @Environment(SearchModel.self) private var search
    @State private var isPresented = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        @Bindable var search = search
        Button {
            isPresented.toggle()
        } label: {
            Label("筛选", systemImage: isActive
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("按大小和修改时间筛选")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Form {
                Picker("大小", selection: $search.sizeFilter) {
                    ForEach(SizeFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                Picker("修改时间", selection: dateChoice) {
                    ForEach(DateFilter.presets, id: \.self) { filter in
                        Text(filter.displayName).tag(DateChoice.preset(filter))
                    }
                    Text("自定义…").tag(DateChoice.custom)
                }
                if search.dateFilter.isCustom {
                    DatePicker("从", selection: $from, displayedComponents: .date)
                        .onChange(of: from) { _, _ in search.dateFilter = .custom(from: from, to: to) }
                    DatePicker("到", selection: $to, displayedComponents: .date)
                        .onChange(of: to) { _, _ in search.dateFilter = .custom(from: from, to: to) }
                }
                if isActive {
                    Button("清除大小和时间筛选") {
                        search.sizeFilter = .any
                        search.dateFilter = .any
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 320)
        }
    }

    private var isActive: Bool {
        search.sizeFilter != .any || search.dateFilter != .any
    }

    private enum DateChoice: Hashable {
        case preset(DateFilter)
        case custom
    }

    private var dateChoice: Binding<DateChoice> {
        Binding(
            get: { search.dateFilter.isCustom ? .custom : .preset(search.dateFilter) },
            set: { choice in
                switch choice {
                case .preset(let filter): search.dateFilter = filter
                case .custom: search.dateFilter = .custom(from: from, to: to)
                }
            })
    }
}

/// The filters in effect, each removable, above the results
struct ActiveFilters: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search

    var body: some View {
        if search.hasFilters {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sources.filter { search.sourceIds.contains($0.id) }) { info in
                        FilterChip(title: info.source.name, symbol: "externaldrive") {
                            search.sourceIds.remove(info.id)
                        }
                    }
                    if let folder = search.folder {
                        FilterChip(title: folder.name, symbol: "folder") { search.folder = nil }
                            .help(folder.path)
                    }
                    ForEach(Array(search.categories).sorted { $0.rawValue < $1.rawValue }, id: \.self) { category in
                        FilterChip(title: category.displayName, symbol: category.symbol) {
                            search.categories.remove(category)
                        }
                    }
                    if search.sizeFilter != .any {
                        FilterChip(title: search.sizeFilter.displayName, symbol: "internaldrive") {
                            search.sizeFilter = .any
                        }
                    }
                    if search.dateFilter != .any {
                        FilterChip(title: search.dateFilter.displayName, symbol: "calendar") {
                            search.dateFilter = .any
                        }
                    }
                    ForEach(Array(search.tags).sorted(), id: \.self) { tag in
                        FilterChip(title: tag, symbol: "tag") { search.tags.remove(tag) }
                    }
                    Button("全部清除") { search.clearFilters() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let symbol: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("移除此筛选")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}
