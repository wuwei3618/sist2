import AppKit
import Foundation
import Observation
import SistCore
import SistExtractors
import ServiceManagement
import SistScan
import SistService
import SistStore

/// App-wide state: the catalog, its sources and running scans. Scanning and folder watching
/// happen here, or in the background agent when it runs (see AgentLink).
@MainActor
@Observable
final class AppModel {
    private(set) var catalog: Catalog?
    /// Until the catalog is open, or failed to open
    private(set) var isOpeningCatalog = true
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
            keeper?.watching = watchFolders
            Task { await keeper?.reloadSources() }
        }
    }

    /// The background agent is running and does the scanning
    private(set) var agentRunning = false
    /// The login item's registration
    private(set) var agentStatus: SMAppService.Status = .notRegistered

    /// Shows the quick search panel from anywhere
    var quickSearchShortcut: QuickSearchShortcut {
        didSet {
            UserDefaults.standard.set(quickSearchShortcut.rawValue, forKey: "quickSearchShortcut")
            registerShortcut()
        }
    }
    /// Another app holds the shortcut
    private(set) var quickSearchShortcutTaken = false

    /// UserDefaults key of the menu bar item setting (an @AppStorage in the scene and settings)
    static let showMenuBarItemKey = "showMenuBarItem"
    static var showsMenuBarItem: Bool {
        UserDefaults.standard.object(forKey: showMenuBarItemKey) as? Bool ?? true
    }

    /// Set by a view that has SwiftUI's openWindow action
    @ObservationIgnored var openMainWindow: (() -> Void)?

    let search = SearchModel()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var quickSearch: QuickSearchController?
    /// Scanning and watching in this process, while the agent does not run
    @ObservationIgnored private var keeper: IndexKeeper?
    private let scanLock = ScanLock(catalogPath: Catalog.defaultPath)
    @ObservationIgnored private var agentCheck: Task<Void, Never>?

    init() {
        defaultOptions = Self.loadDefaultOptions()
        watchFolders = UserDefaults.standard.object(forKey: "watchFolders") as? Bool ?? true
        quickSearchShortcut = UserDefaults.standard.string(forKey: "quickSearchShortcut")
            .flatMap(QuickSearchShortcut.init(rawValue:)) ?? .optionSpace
    }

    func start() async {
        guard !started else { return }
        started = true
        quickSearch = QuickSearchController(model: self)
        registerShortcut()
        do {
            // Off the main thread: after an update, opening may migrate a large catalog
            let catalog = try await Task.detached(priority: .userInitiated) {
                try Catalog(path: Catalog.defaultPath)
            }.value
            self.catalog = catalog
            isOpeningCatalog = false
            search.catalog = catalog
            await refreshSources()
            await refreshTags()
            await search.loadSavedSearches()
            search.run()
            listenToAgent()
            refreshAgentStatus()
            await chooseScanner()
        } catch {
            isOpeningCatalog = false
            errorMessage = "无法打开索引数据库：\(error)"
        }
    }

    // MARK: Sources

    func refreshSources() async {
        guard let catalog else { return }
        do {
            sources = try await catalog.sources()
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
            await sourcesChanged()
            scan(source.id)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func removeSource(_ id: Int64) async {
        guard let catalog else { return }
        cancelScan(id)
        do {
            try await catalog.removeSource(id: id)
        } catch {
            errorMessage = "\(error)"
        }
        search.sourceIds.remove(id)
        await refreshSources()
        await sourcesChanged()
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
        if agentRunning {
            AgentLink.post(AgentLink.scanRequest, AgentLink.ScanRequest(sourceId: id, mode: mode, scopes: scopes))
        } else if let keeper {
            Task { await keeper.scheduler.scan(id, mode: mode, scopes: scopes) }
        }
    }

    func rebuild(_ id: Int64) {
        scan(id, mode: .rebuild)
    }

    /// Rescans one folder of a source and everything below it
    func scanFolder(_ folder: FolderFilter) {
        scan(folder.sourceId, scopes: [ScanScope(path: folder.path, recursive: true)])
    }

    func scanAll() {
        for info in sources {
            scan(info.id)
        }
    }

    func cancelScan(_ id: Int64) {
        if agentRunning {
            AgentLink.post(AgentLink.cancelRequest, AgentLink.CancelRequest(sourceId: id))
        } else if let keeper {
            Task { await keeper.scheduler.cancel(id) }
        }
    }

    func cancelAllScans() {
        if agentRunning {
            AgentLink.post(AgentLink.cancelRequest, AgentLink.CancelRequest(sourceId: nil))
        } else if let keeper {
            Task { await keeper.scheduler.cancelAll() }
        }
    }

    func isScanning(_ id: Int64) -> Bool {
        activeScans[id] != nil
    }

    /// Progress and completion, from this process or from the agent
    private func handle(_ event: ScanScheduler.Event) {
        switch event {
        case .progress(let progress):
            activeScans[progress.sourceId] = progress
        case .finished(let id, let error):
            activeScans[id] = nil
            catalogVersion += 1
            if let error {
                errorMessage = "扫描失败：\(error)"
            }
            Task {
                await refreshSources()
                search.run()
            }
        }
    }

    private func sourcesChanged() async {
        if agentRunning {
            AgentLink.post(AgentLink.sourcesChanged)
        } else {
            await keeper?.reloadSources()
        }
    }

    // MARK: Background agent

    /// Scans here unless the agent runs: whoever holds the scan lock scans
    private func chooseScanner() async {
        if scanLock.tryAcquire() {
            agentRunning = false
            guard keeper == nil, let catalog else { return }
            let keeper = IndexKeeper(catalog: catalog) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            keeper.watching = watchFolders
            self.keeper = keeper
            await keeper.reloadSources()
        } else {
            await handOverToAgent()
        }
    }

    /// The agent took over: stop scanning and watching here, and follow its progress
    private func handOverToAgent() async {
        agentRunning = true
        if let keeper {
            self.keeper = nil
            await keeper.stop()
        }
        scanLock.release()
        activeScans = [:]
        // Should the agent die, its lock goes with it: scan here again
        agentCheck?.cancel()
        agentCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.agentRunning else { return }
                if !ScanLock.isHeldElsewhere(catalogPath: Catalog.defaultPath) {
                    await self.chooseScanner()
                }
            }
        }
    }

    private func listenToAgent() {
        AgentLink.observe(AgentLink.agentStarted) { [weak self] _ in
            guard let self, !self.agentRunning else { return }
            Task { await self.handOverToAgent() }
        }
        AgentLink.observe(AgentLink.agentStopped) { [weak self] _ in
            guard let self, self.agentRunning else { return }
            Task {
                // Its lock is released just before
                try? await Task.sleep(for: .milliseconds(500))
                await self.chooseScanner()
            }
        }
        AgentLink.observe(AgentLink.scanEvent) { [weak self] notification in
            guard let self, self.agentRunning, let event = AgentLink.event(from: notification) else { return }
            self.handle(event)
        }
        AgentLink.post(AgentLink.statusRequest)
    }

    private var agentService: SMAppService? {
        Bundle.main.bundleIdentifier.map { SMAppService.loginItem(identifier: AgentLink.agentIdentifier(appIdentifier: $0)) }
    }

    func refreshAgentStatus() {
        agentStatus = agentService?.status ?? .notFound
    }

    /// Registers the agent as a login item, which also starts it, or stops and unregisters it.
    /// While it starts the app keeps scanning; it hands over once the agent holds the lock.
    func setBackgroundAgent(_ enabled: Bool) {
        guard let service = agentService else { return }
        Task {
            do {
                if enabled {
                    // The agent waits for the lock: let go of it if no scan is running here
                    if activeScans.isEmpty, let keeper {
                        self.keeper = nil
                        await keeper.stop()
                        scanLock.release()
                    }
                    try service.register()
                } else {
                    AgentLink.post(AgentLink.quit)
                    try await service.unregister()
                }
            } catch {
                errorMessage = "无法\(enabled ? "启用" : "停用")后台索引：\(error.localizedDescription)"
            }
            refreshAgentStatus()
            // Give the agent a moment, then make sure someone scans
            try? await Task.sleep(for: .seconds(5))
            if !agentRunning {
                await chooseScanner()
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Windows

    func showMainWindow() {
        NSApp.activate()
        if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    func showQuickSearch() {
        quickSearch?.show()
    }

    private func registerShortcut() {
        guard let quickSearch else { return }
        quickSearchShortcutTaken = !quickSearch.register(quickSearchShortcut)
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
                self?.errorMessage = "无法取出 \(document.name)：\(error)"
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
