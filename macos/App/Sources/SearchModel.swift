import Foundation
import Observation
import SistCore
import SistStore

enum DisplayMode: String, CaseIterable {
    case list, grid
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
        tags = []
    }

    private func makeQuery(offset: Int) -> SearchQuery {
        var query = SearchQuery(text: text)
        query.categories = categories
        query.sourceIds = sourceIds
        query.tags = tags
        query.sort = sort
        query.includeArchiveMembers = includeArchiveMembers
        query.limit = Self.pageSize
        query.offset = offset
        return query
    }
}
