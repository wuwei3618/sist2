import AppKit
import SwiftUI
import SistCore
import SistStore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            DefaultOptionsView()
                .tabItem { Label("扫描", systemImage: "doc.text.magnifyingglass") }
            SourcesSettingsView()
                .tabItem { Label("文件夹", systemImage: "folder") }
            PermissionsView()
                .tabItem { Label("权限", systemImage: "lock.shield") }
        }
        .frame(width: 600, height: 560)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.showMenuBarItemKey) private var showMenuBarItem = true

    var body: some View {
        @Bindable var model = model
        Form {
            Section("快速搜索") {
                Picker("快捷键", selection: $model.quickSearchShortcut) {
                    ForEach(QuickSearchShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                if model.quickSearchShortcutTaken {
                    Label("这个快捷键已被其他应用占用，请换一个", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("在任何应用中按下快捷键，屏幕上方会出现搜索框：↑↓ 选择，↩ 打开，⌘↩ 在 Finder 中显示，⇧↩ 在主窗口中查看全部结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("在菜单栏中显示", isOn: $showMenuBarItem)
                Text("显示时，关闭主窗口后 Sist 继续在后台运行：快捷键随时可用，文件夹有变化时继续更新索引。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Options given to folders added from now on
private struct DefaultOptionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("文件夹内容变化时自动更新索引", isOn: $model.watchFolders)
            }
            ScanOptionsSections(options: $model.defaultOptions)
            Section {
                Text("这些设置用于之后添加的文件夹。已有文件夹的设置在“文件夹”标签页中修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourcesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?
    @State private var options = ScanOptions()

    var body: some View {
        HSplitView {
            List(model.sources, selection: $selection) { info in
                VStack(alignment: .leading) {
                    Text(info.source.name)
                    Text(info.source.root)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(info.id)
            }
            .frame(minWidth: 180, maxWidth: 220)

            if let selection, let info = model.sources.first(where: { $0.id == selection }) {
                VStack(spacing: 0) {
                    Form {
                        ScanOptionsSections(options: $options)
                    }
                    .formStyle(.grouped)
                    HStack {
                        // Parsing settings apply to every file only by parsing them all again
                        if options.changesExtraction(comparedTo: info.source.indexedOptions ?? info.source.options) {
                            Label("这些更改会让所有文件重新解析", systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重建索引") { model.rebuild(info.id) }
                            .disabled(model.isScanning(info.id))
                        Button("还原") { options = info.source.options }
                        Button("保存并扫描") {
                            let id = info.id
                            let newOptions = options
                            Task {
                                await model.updateOptions(newOptions, for: id)
                                model.scan(id)
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(options == info.source.options)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("选择一个文件夹", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selection) { _, id in
            if let info = model.sources.first(where: { $0.id == id }) {
                options = info.source.options
            }
        }
    }
}

/// The scan settings of a folder (sist2's `scan` options).
struct ScanOptionsSections: View {
    @Binding var options: ScanOptions

    var body: some View {
        Section("内容") {
            Toggle("识别图片中的文字 (OCR)", isOn: $options.ocrImages)
            Toggle("识别扫描版 PDF 中的文字 (OCR)", isOn: $options.ocrDocuments)
            TextField("OCR 语言", text: Binding(
                get: { options.ocrLanguages.joined(separator: ", ") },
                set: { options.ocrLanguages = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                .help("Vision 语言代码，例如 zh-Hans, zh-Hant, en-US, ja-JP")
            Stepper("每个文件最多保存 \(options.contentSizeLimit / 1024) K 字符正文",
                    value: $options.contentSizeLimit, in: 4096...4_194_304, step: 16_384)
            Toggle("计算 SHA-1 校验和", isOn: $options.computeChecksums)
        }

        Section("缩略图") {
            Toggle("生成缩略图", isOn: Binding(
                get: { options.thumbnailCount > 0 },
                set: { options.thumbnailCount = $0 ? 1 : 0 }))
            Picker("尺寸", selection: $options.thumbnailSize) {
                Text("小 (276 px)").tag(276)
                Text("中 (552 px)").tag(552)
                Text("大 (1024 px)").tag(1024)
            }
            .disabled(options.thumbnailCount == 0)
        }

        Section("压缩包") {
            Picker("压缩包内的文件", selection: $options.archiveMode) {
                ForEach(ArchiveMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }

        Section("范围") {
            Toggle("跳过隐藏文件", isOn: $options.skipHiddenFiles)
            Toggle("把应用程序等文件包当作单个文件", isOn: $options.treatPackagesAsFiles)
            TextField("排除路径（正则表达式）", text: Binding(
                get: { options.excludePattern ?? "" },
                set: { options.excludePattern = $0.isEmpty ? nil : $0 }))
            Text("也可以在文件夹根目录放一个 .sistignore 文件，写法同 .gitignore。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("性能") {
            Stepper(options.threads == 0 ? "并行解析：自动（每个核心一个）" : "并行解析：\(options.threads) 个",
                    value: $options.threads, in: 0...64)
            Stepper("单个文件超时：\(Int(options.jobTimeout)) 秒", value: $options.jobTimeout, in: 10...600, step: 10)
            Toggle("快速模式（只按扩展名判断类型）", isOn: $options.fast)
        }
    }
}

private struct PermissionsView: View {
    var body: some View {
        Form {
            Section {
                Text("""
                    Sist 不在沙盒中运行，可以直接读取你添加的文件夹。macOS 仍会保护部分位置：\
                    第一次扫描“文稿”“桌面”“下载”或外置磁盘时，系统会弹窗请求授权。
                    """)
                Text("要索引“邮件”“信息”等受保护数据，或避免反复授权，可以为 Sist 打开“完全磁盘访问权限”。")
                Button("打开“完全磁盘访问权限”设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("索引数据库") {
                Text(Catalog.defaultPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Catalog.defaultPath)])
                }
                Text("命令行工具 sist 使用同一个数据库，例如：sist search 季度报告")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
