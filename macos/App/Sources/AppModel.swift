import AppKit
import Foundation
import Observation
import SistCore
import SistExtractors
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
    /// Bumped when a scan finishes, so views showing catalog data (the folder tree) reload it
    private(set) var catalogVersion = 0
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
    /// FSEvents gathered per source until the next rescan
    @ObservationIgnored private var pendingEvents: [Int64: [FileChange]] = [:]

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

    /// Scans a source, or only `scopes` of it. Options that changed how files are parsed make it a
    /// rebuild of the whole source (see ScanCoordinator).
    func scan(_ id: Int64, mode: ScanMode = .incremental, scopes: [ScanScope]? = nil) {
        guard let catalog, scanTasks[id] == nil else { return }
        let coordinator = ScanCoordinator(catalog: catalog)
        let report: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                self.activeScans[id] = progress
            }
        }
        scanTasks[id] = Task { [weak self] in
            do {
                try await coordinator.scan(sourceId: id, mode: mode, scopes: scopes, progress: report)
            } catch is CancellationError {
            } catch {
                self?.errorMessage = "扫描失败：\(error)"
            }
            await self?.scanFinished(id)
        }
    }

    func rebuild(_ id: Int64) {
        scan(id, mode: .rebuild)
    }

    /// Rescans one folder of a source and everything below it
    func scanFolder(_ folder: FolderFilter) {
        scan(folder.sourceId, scopes: [ScanScope(path: folder.path, recursive: true)])
    }

    private func scanFinished(_ id: Int64) async {
        scanTasks[id] = nil
        activeScans[id] = nil
        catalogVersion += 1
        await refreshSources()
        search.run()
        // Changes that arrived during the scan
        if pendingEvents[id]?.isEmpty == false {
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
            let watcher = FileSystemWatcher(path: info.source.root, ignoring: [catalogDirectory]) { [weak self] events in
                Task { @MainActor [weak self] in
                    self?.folderChanged(id, events: events)
                }
            }
            watcher.start()
            watchers[id] = watcher
        }
    }

    private func folderChanged(_ id: Int64, events: [FileChange]) {
        pendingEvents[id, default: []] += events
        // A running scan picks the events up when it finishes
        if scanTasks[id] == nil {
            scheduleRescan(id)
        }
    }

    private func scheduleRescan(_ id: Int64) {
        pendingRescans[id]?.cancel()
        pendingRescans[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.rescanDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingRescans[id] = nil
            guard let root = self.sources.first(where: { $0.id == id })?.source.root else { return }
            let events = self.pendingEvents.removeValue(forKey: id) ?? []
            self.scan(id, scopes: ChangeScopes.scopes(for: events, root: root))
        }
    }

    // MARK: Opening documents

    /// Opens the file; an archive member is extracted to a temporary file first.
    func open(_ document: DocumentSummary) {
        withFileURL(for: document) { NSWorkspace.shared.open($0) }
    }

    /// Shows the document in Quick Look; an archive member is extracted to a temporary file first.
    func preview(_ document: DocumentSummary) {
        withFileURL(for: document) { [weak self] url in self?.search.previewURL = url }
    }

    private func withFileURL(for document: DocumentSummary, _ action: @escaping @MainActor (URL) -> Void) {
        guard document.isArchiveMember else {
            action(document.fileURL)
            return
        }
        let path = document.path
        let id = document.id
        Task { [weak self] in
            do {
                let url = try await Task.detached {
                    try ArchiveMemberReader.extractToTemporaryFile(path: path, documentId: id)
                }.value
                action(url)
            } catch {
                self?.errorMessage = "无法从压缩包中取出 \(document.name)：\(error)"
            }
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
