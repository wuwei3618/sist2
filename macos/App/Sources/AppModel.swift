import AppKit
import Foundation
import Observation
import SistCore
import SistScan
import SistStore

/// App-wide state: the catalog, its sources, running scans and the folder watchers.
@MainActor
@Observable
final class AppModel {
    private(set) var catalog: Catalog?
    private(set) var sources: [SourceInfo] = []
    private(set) var tags: [TagCount] = []
    private(set) var activeScans: [Int64: ScanProgress] = [:]
    var errorMessage: String?

    /// Options given to newly added folders
    var defaultOptions: ScanOptions {
        didSet { Self.saveDefaultOptions(defaultOptions) }
    }

    /// Rescan a folder a few seconds after something in it changes
    var watchFolders: Bool {
        didSet {
            UserDefaults.standard.set(watchFolders, forKey: "watchFolders")
            updateWatchers()
        }
    }

    let search = SearchModel()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [Int64: FileSystemWatcher] = [:]
    @ObservationIgnored private var pendingRescans: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var changedDuringScan: Set<Int64> = []

    static let rescanDelay: Duration = .seconds(10)

    init() {
        defaultOptions = Self.loadDefaultOptions()
        watchFolders = UserDefaults.standard.object(forKey: "watchFolders") as? Bool ?? true
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let catalog = try Catalog(path: Catalog.defaultPath)
            self.catalog = catalog
            search.catalog = catalog
            await refreshSources()
            await refreshTags()
            search.run()
        } catch {
            errorMessage = "无法打开索引数据库：\(error)"
        }
    }

    // MARK: Sources

    func refreshSources() async {
        guard let catalog else { return }
        do {
            sources = try await catalog.sources()
            updateWatchers()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func refreshTags() async {
        guard let catalog else { return }
        tags = (try? await catalog.tags()) ?? []
    }

    func chooseFoldersToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要建立索引的文件夹"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                await addSource(url)
            }
        }
    }

    func addSource(_ url: URL) async {
        guard let catalog else { return }
        do {
            let source = try await catalog.addSource(root: url.path, options: defaultOptions)
            await refreshSources()
            scan(source.id)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func removeSource(_ id: Int64) async {
        guard let catalog else { return }
        scanTasks[id]?.cancel()
        do {
            try await catalog.removeSource(id: id)
        } catch {
            errorMessage = "\(error)"
        }
        search.sourceIds.remove(id)
        await refreshSources()
        search.run()
    }

    func updateOptions(_ options: ScanOptions, for id: Int64) async {
        guard let catalog else { return }
        do {
            try await catalog.updateSource(id: id, options: options)
            await refreshSources()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func revealInFinder(_ info: SourceInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.source.root)])
    }

    // MARK: Scans

    func scan(_ id: Int64) {
        guard let catalog, scanTasks[id] == nil else { return }
        let coordinator = ScanCoordinator(catalog: catalog)
        scanTasks[id] = Task { [weak self] in
            do {
                try await coordinator.scan(sourceId: id, progress: { progress in
                    Task { @MainActor [weak self] in
                        self?.activeScans[id] = progress
                    }
                })
            } catch is CancellationError {
            } catch {
                self?.errorMessage = "扫描失败：\(error)"
            }
            await self?.scanFinished(id)
        }
    }

    private func scanFinished(_ id: Int64) async {
        scanTasks[id] = nil
        activeScans[id] = nil
        await refreshSources()
        search.run()
        if changedDuringScan.remove(id) != nil {
            scheduleRescan(id)
        }
    }

    func scanAll() {
        for info in sources {
            scan(info.id)
        }
    }

    func cancelScan(_ id: Int64) {
        scanTasks[id]?.cancel()
    }

    func cancelAllScans() {
        for task in scanTasks.values {
            task.cancel()
        }
    }

    func isScanning(_ id: Int64) -> Bool {
        scanTasks[id] != nil
    }

    // MARK: Watching

    private func updateWatchers() {
        let wanted = watchFolders ? Set(sources.map(\.id)) : []
        for (id, watcher) in watchers where !wanted.contains(id) {
            watcher.stop()
            watchers[id] = nil
        }
        // The catalog may live inside a watched folder: its own writes must not trigger scans
        let catalogDirectory = (Catalog.defaultPath as NSString).deletingLastPathComponent
        for info in sources where wanted.contains(info.id) && watchers[info.id] == nil {
            let id = info.id
            let watcher = FileSystemWatcher(path: info.source.root, ignoring: [catalogDirectory]) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.folderChanged(id)
                }
            }
            watcher.start()
            watchers[id] = watcher
        }
    }

    private func folderChanged(_ id: Int64) {
        if scanTasks[id] != nil {
            changedDuringScan.insert(id)
        } else {
            scheduleRescan(id)
        }
    }

    private func scheduleRescan(_ id: Int64) {
        pendingRescans[id]?.cancel()
        pendingRescans[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.rescanDelay)
            guard !Task.isCancelled else { return }
            self?.pendingRescans[id] = nil
            self?.scan(id)
        }
    }

    // MARK: Tags

    func addTag(_ name: String, to documentId: Int64) async {
        try? await catalog?.addTag(name, to: documentId)
        await refreshTags()
    }

    func removeTag(_ name: String, from documentId: Int64) async {
        try? await catalog?.removeTag(name, from: documentId)
        await refreshTags()
    }

    // MARK: Defaults

    private static let optionsKey = "defaultScanOptions"

    private static func loadDefaultOptions() -> ScanOptions {
        guard let data = UserDefaults.standard.data(forKey: optionsKey),
              let options = try? JSONDecoder().decode(ScanOptions.self, from: data) else {
            return ScanOptions()
        }
        return options
    }

    private static func saveDefaultOptions(_ options: ScanOptions) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: optionsKey)
        }
    }
}
