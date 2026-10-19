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
                .help("排序与筛选")

                Button {
                    openWindow(id: "stats")
                } label: {
                    Label("统计", systemImage: "chart.bar.xaxis")
                }
                .help("索引统计")
            }
        }
        .quickLookPreview($search.previewURL)
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
