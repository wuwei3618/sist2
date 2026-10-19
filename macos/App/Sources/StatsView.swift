import Charts
import SwiftUI
import SistCore
import SistStore

/// sist2's stats page: what the index holds, by kind, size, year and folder.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var sourceId: Int64?
    @State private var stats: CatalogStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("范围", selection: $sourceId) {
                    Text("全部文件夹").tag(Int64?.none)
                    ForEach(model.sources) { info in
                        Text(info.source.name).tag(Int64?.some(info.id))
                    }
                }
                .frame(maxWidth: 320)

                if let stats {
                    Text("\(Format.number(stats.documentCount)) 个文件，共 \(Format.bytes(stats.totalSize))")
                        .font(.title2.bold())

                    section("按类型（占用空间）") {
                        Chart(stats.byCategory) { bucket in
                            BarMark(x: .value("大小 (MB)", Double(bucket.size) / 1_048_576),
                                    y: .value("类型", categoryName(bucket.label)))
                            .annotation(position: .trailing) {
                                Text(Format.bytes(bucket.size)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: CGFloat(max(stats.byCategory.count, 1)) * 28 + 20)
                    }

                    section("按大小分布（文件数）") {
                        Chart(stats.sizeHistogram) { bucket in
                            BarMark(x: .value("区间", bucket.label), y: .value("文件数", bucket.count))
                        }
                        .frame(height: 200)
                    }

                    section("按修改年份（文件数）") {
                        Chart(stats.byYear) { bucket in
                            BarMark(x: .value("年份", bucket.label), y: .value("文件数", bucket.count))
                        }
                        .frame(height: 200)
                    }

                    if !stats.topFolders.isEmpty {
                        let folders = Array(stats.topFolders.prefix(15))
                        section("最大的文件夹") {
                            Chart(folders) { bucket in
                                BarMark(x: .value("大小 (MB)", Double(bucket.size) / 1_048_576),
                                        y: .value("文件夹", bucket.label))
                            }
                            .frame(height: CGFloat(folders.count) * 26 + 20)
                        }
                    }

                    section("最常见的格式") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(stats.topMimeTypes) { bucket in
                                GridRow {
                                    Text(bucket.label)
                                    Text(Format.number(bucket.count)).monospacedDigit()
                                    Text(Format.bytes(bucket.size)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.callout)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 520)
        .task(id: sourceId) {
            stats = nil
            stats = try? await model.catalog?.stats(sourceId: sourceId)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func categoryName(_ raw: String) -> String {
        MimeCategory(rawValue: raw)?.displayName ?? raw
    }
}
