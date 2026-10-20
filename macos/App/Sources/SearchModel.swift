import Foundation
import Observation
import SistCore
import SistStore

enum DisplayMode: String, CaseIterable {
    case list, grid
}

/// A folder of a source chosen in the sidebar tree
struct FolderFilter: Hashable {
    var sourceId: Int64
    var path: String
    var name: String
}

enum SizeFilter: String, CaseIterable, Hashable {
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
}

/// The query, its filters and its results. Any change re-runs the search; typing is debounced.
@MainActor
@Observable
final class SearchModel {
    var catalog: Catalog?

    var text = "" {
        didSet { if text != oldValue { scheduleSearch() } }
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
            guard !Task.isCancelled else { return }
            self?.run()
        }
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
