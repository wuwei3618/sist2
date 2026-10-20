import Foundation
import Observation
import SistCore
import SistStore

enum DisplayMode: String, CaseIterable {
    case list, grid
}

/// A folder of a source chosen in the sidebar tree
struct FolderFilter: Hashable, Codable {
    var sourceId: Int64
    var path: String
    var name: String
}

enum SizeFilter: String, CaseIterable, Hashable, Codable {
    case any, under100KB, upTo1MB, upTo10MB, upTo100MB, over100MB

    var range: (min: Int64?, max: Int64?) {
        let kb: Int64 = 1024
        let mb = kb * 1024
        switch self {
        case .any: return (nil, nil)
        case .under100KB: return (nil, 100 * kb - 1)
        case .upTo1MB: return (100 * kb, mb - 1)
        case .upTo10MB: return (mb, 10 * mb - 1)
        case .upTo100MB: return (10 * mb, 100 * mb - 1)
        case .over100MB: return (100 * mb, nil)
        }
    }

    var displayName: String {
        switch self {
        case .any: return "任意大小"
        case .under100KB: return "小于 100 KB"
        case .upTo1MB: return "100 KB – 1 MB"
        case .upTo10MB: return "1 – 10 MB"
        case .upTo100MB: return "10 – 100 MB"
        case .over100MB: return "大于 100 MB"
        }
    }
}

enum DateFilter: Hashable {
    case any, today, last7Days, last30Days, thisYear, lastYear, olderThanAYear
    /// Whole days, both included
    case custom(from: Date, to: Date)

    static let presets: [DateFilter] = [.any, .today, .last7Days, .last30Days, .thisYear, .lastYear, .olderThanAYear]

    func range(now: Date = Date(), calendar: Calendar = .current) -> (after: Date?, before: Date?) {
        let today = calendar.startOfDay(for: now)
        let thisYear = calendar.date(from: calendar.dateComponents([.year], from: now))!
        switch self {
        case .any: return (nil, nil)
        case .today: return (today, nil)
        case .last7Days: return (calendar.date(byAdding: .day, value: -7, to: today), nil)
        case .last30Days: return (calendar.date(byAdding: .day, value: -30, to: today), nil)
        case .thisYear: return (thisYear, nil)
        case .lastYear: return (calendar.date(byAdding: .year, value: -1, to: thisYear), thisYear)
        case .olderThanAYear: return (nil, calendar.date(byAdding: .year, value: -1, to: today))
        case .custom(let from, let to):
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))
            return (calendar.startOfDay(for: min(from, to)), end)
        }
    }

    var displayName: String {
        switch self {
        case .any: return "任意时间"
        case .today: return "今天"
        case .last7Days: return "最近 7 天"
        case .last30Days: return "最近 30 天"
        case .thisYear: return "今年"
        case .lastYear: return "去年"
        case .olderThanAYear: return "一年以前"
        case .custom(let from, let to):
            let format = Date.FormatStyle(date: .numeric, time: .omitted)
            return "\(min(from, to).formatted(format)) – \(max(from, to).formatted(format))"
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// As saved searches store it: presets by name, relative to the day the search runs
    var saved: SavedDate {
        switch self {
        case .any: return SavedDate(preset: "any")
        case .today: return SavedDate(preset: "today")
        case .last7Days: return SavedDate(preset: "last7Days")
        case .last30Days: return SavedDate(preset: "last30Days")
        case .thisYear: return SavedDate(preset: "thisYear")
        case .lastYear: return SavedDate(preset: "lastYear")
        case .olderThanAYear: return SavedDate(preset: "olderThanAYear")
        case .custom(let from, let to): return SavedDate(from: from, to: to)
        }
    }

    init(_ saved: SavedDate) {
        if let from = saved.from, let to = saved.to {
            self = .custom(from: from, to: to)
            return
        }
        switch saved.preset {
        case "today": self = .today
        case "last7Days": self = .last7Days
        case "last30Days": self = .last30Days
        case "thisYear": self = .thisYear
        case "lastYear": self = .lastYear
        case "olderThanAYear": self = .olderThanAYear
        default: self = .any
        }
    }
}

struct SavedDate: Codable, Hashable {
    var preset: String?
    var from: Date?
    var to: Date?
}

/// A query with its filters, as saved searches keep it
struct SearchState: Codable, Hashable {
    var text = ""
    var categories: [MimeCategory] = []
    var sourceIds: [Int64] = []
    var folder: FolderFilter?
    var size: SizeFilter = .any
    var date = SavedDate(preset: "any")
    var tags: [String] = []
    var sort: SearchSort = .relevance
    var includeArchiveMembers = true
}

/// The query, its filters and its results. Any change re-runs the search; typing is debounced.
@MainActor
@Observable
final class SearchModel {
    var catalog: Catalog?

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            if text.hasPrefix(Self.completionMarker) {
                // A folder or saved search picked from the suggestions, not text to search for
                let completion = text
                Task { @MainActor in self.applyCompletion(completion) }
                return
            }
            scheduleSearch()
        }
    }
    var categories: Set<MimeCategory> = [] {
        didSet { if categories != oldValue { run() } }
    }
    var sourceIds: Set<Int64> = [] {
        didSet { if sourceIds != oldValue { run() } }
    }
    var folder: FolderFilter? {
        didSet { if folder != oldValue { run() } }
    }
    var sizeFilter: SizeFilter = .any {
        didSet { if sizeFilter != oldValue { run() } }
    }
    var dateFilter: DateFilter = .any {
        didSet { if dateFilter != oldValue { run() } }
    }
    var tags: Set<String> = [] {
        didSet { if tags != oldValue { run() } }
    }
    var sort: SearchSort = .relevance {
        didSet { if sort != oldValue { run() } }
    }
    var includeArchiveMembers = true {
        didSet { if includeArchiveMembers != oldValue { run() } }
    }

    var selection: Set<Int64> = []
    var displayMode: DisplayMode = .list
    /// Shown with QuickLook when set
    var previewURL: URL?

    private(set) var hits: [SearchHit] = []
    private(set) var total = 0
    private(set) var categoryCounts: [MimeCategory: Int] = [:]
    private(set) var highlightTerms: [String] = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    /// Offered under the search field while typing
    private(set) var folderSuggestions: [FolderInfo] = []
    /// A corrected query, when this one finds nothing
    private(set) var spellingSuggestion: String?
    private(set) var savedSearches: [SavedSearch] = []
    /// Shows the dialog naming the current search
    var isSavingSearch = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    static let pageSize = 100

    var selectedHit: SearchHit? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return hits.first { $0.id == id }
    }

    var hasFilters: Bool {
        !categories.isEmpty || !sourceIds.isEmpty || folder != nil || sizeFilter != .any || dateFilter != .any
            || !tags.isEmpty
    }

    func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.run()
            await self.updateFolderSuggestions()
        }
    }

    private func updateFolderSuggestions() async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let catalog, !text.isEmpty, folder == nil else {
            folderSuggestions = []
            return
        }
        // The last word is the one being typed
        let word = text.hasPrefix("/") || text.hasPrefix("~") ? text : String(text.split(separator: " ").last ?? "")
        let found = (try? await catalog.folders(matching: word, limit: 5)) ?? []
        if text == self.text.trimmingCharacters(in: .whitespaces) {
            folderSuggestions = found
        }
    }

    /// Saved searches whose name contains what is typed
    var matchingSavedSearches: [SavedSearch] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        return savedSearches.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    // MARK: Completions

    /// Prefixes completions that stand for a folder or a saved search (an invisible separator)
    static let completionMarker = "\u{2063}"

    static func completion(for folder: FolderInfo) -> String {
        completionMarker + ["folder", String(folder.sourceId), folder.path, folder.name].joined(separator: "\t")
    }

    static func completion(for saved: SavedSearch) -> String {
        completionMarker + ["saved", String(saved.id)].joined(separator: "\t")
    }

    private func applyCompletion(_ value: String) {
        let parts = value.dropFirst(Self.completionMarker.count).split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        switch parts.first {
        case "folder" where parts.count == 4:
            text = ""
            if let sourceId = Int64(parts[1]) {
                folder = FolderFilter(sourceId: sourceId, path: parts[2], name: parts[3])
            }
        case "saved" where parts.count == 2:
            if let id = Int64(parts[1]), let saved = savedSearches.first(where: { $0.id == id }) {
                apply(saved)
            } else {
                text = ""
            }
        default:
            text = ""
        }
    }

    // MARK: Saved searches

    var state: SearchState {
        SearchState(text: text, categories: categories.sorted { $0.rawValue < $1.rawValue }, sourceIds: sourceIds.sorted(),
                    folder: folder, size: sizeFilter, date: dateFilter.saved, tags: tags.sorted(), sort: sort,
                    includeArchiveMembers: includeArchiveMembers)
    }

    func apply(_ state: SearchState) {
        categories = Set(state.categories)
        sourceIds = Set(state.sourceIds)
        folder = state.folder
        sizeFilter = state.size
        dateFilter = DateFilter(state.date)
        tags = Set(state.tags)
        sort = state.sort
        includeArchiveMembers = state.includeArchiveMembers
        text = state.text
        run()
    }

    func apply(_ saved: SavedSearch) {
        guard let state = try? JSONDecoder().decode(SearchState.self, from: Data(saved.state.utf8)) else { return }
        apply(state)
    }

    func loadSavedSearches() async {
        savedSearches = (try? await catalog?.savedSearches()) ?? []
    }

    func saveCurrentSearch(name: String) async {
        guard let catalog, !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let data = try? JSONEncoder().encode(state) else { return }
        do {
            try await catalog.saveSearch(name: name, state: String(decoding: data, as: UTF8.self))
        } catch {
            errorMessage = "\(error)"
        }
        await loadSavedSearches()
    }

    func renameSavedSearch(_ saved: SavedSearch, to name: String) async {
        try? await catalog?.renameSavedSearch(id: saved.id, to: name)
        await loadSavedSearches()
    }

    func deleteSavedSearch(_ saved: SavedSearch) async {
        try? await catalog?.deleteSavedSearch(id: saved.id)
        await loadSavedSearches()
    }

    func run() {
        searchTask?.cancel()
        guard let catalog else { return }
        let query = makeQuery(offset: 0)
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                let results = try await catalog.search(query)
                guard !Task.isCancelled, let self else { return }
                self.hits = results.hits
                self.total = results.total
                self.categoryCounts = results.categoryCounts
                self.highlightTerms = results.highlightTerms
                self.elapsed = results.elapsed
                self.errorMessage = nil
                let ids = Set(results.hits.map(\.id))
                self.selection = self.selection.filter { ids.contains($0) }
                self.spellingSuggestion = nil
                if results.total == 0, !query.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let suggestion = try? await catalog.spellingSuggestion(for: query.text)
                    if query.text == self.text {
                        self.spellingSuggestion = suggestion
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = "\(error)"
            }
            self?.isSearching = false
        }
    }

    /// Fetches the next page when the last row appears.
    func loadMore() {
        guard let catalog, !isLoadingMore, hits.count < total else { return }
        isLoadingMore = true
        var query = makeQuery(offset: hits.count)
        query.countCategories = false
        Task { [weak self] in
            defer { self?.isLoadingMore = false }
            guard let results = try? await catalog.search(query), let self else { return }
            // A new search may have replaced the results meanwhile
            guard self.hits.count == query.offset else { return }
            self.hits += results.hits
        }
    }

    func clearFilters() {
        categories = []
        sourceIds = []
        folder = nil
        sizeFilter = .any
        dateFilter = .any
        tags = []
    }

    private func makeQuery(offset: Int) -> SearchQuery {
        var query = SearchQuery(text: text)
        query.categories = categories
        query.sourceIds = sourceIds
        if let folder {
            // Sources may be nested: the folder belongs to one of them
            query.sourceIds = [folder.sourceId]
            query.pathPrefix = folder.path
        }
        (query.minSize, query.maxSize) = sizeFilter.range
        (query.modifiedAfter, query.modifiedBefore) = dateFilter.range()
        query.tags = tags
        query.sort = sort
        query.includeArchiveMembers = includeArchiveMembers
        query.limit = Self.pageSize
        query.offset = offset
        return query
    }
}
