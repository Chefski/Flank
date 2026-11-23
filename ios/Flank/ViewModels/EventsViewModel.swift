//
//  EventsViewModel.swift
//  Flank
//

import Foundation

/// One segment of the Events tab. The first page is kept offline; completed events
/// page further on demand.
@MainActor
final class EventListStore: ObservableObject {
    /// The API rejects pages above 100.
    private static let maximumPage = 100

    @Published private(set) var events: [V3EventSummary] = []
    @Published private(set) var state: ListLoadState = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var loadMoreError: String?

    let query: V3EventListQuery
    private let client: VLRAPIClient
    private let cache: ListCache
    private var nextPage = 2
    /// Whether a first-page fetch succeeded since launch; the offline copy doesn't count.
    private(set) var hasLoaded = false
    /// Bumped by each first-page fetch so an older "load more" can't append to a list
    /// that was refreshed underneath it.
    private var generation = 0
    /// True while a first-page fetch is in flight. "Load more" waits for it: until it
    /// lands, `nextPage` still points into the old list.
    private var isRefreshing = false

    private var cacheKey: String { "v3.events.\(query.rawValue)" }

    init(query: V3EventListQuery, client: VLRAPIClient = .init(), cache: ListCache = .shared) {
        self.query = query
        self.client = client
        self.cache = cache
        loadCache()
    }

    /// Fetches unless this segment already loaded this session, so switching segments
    /// keeps the pages already shown. Pull-to-refresh and retry call `fetch()` instead.
    func fetchIfNeeded() async {
        guard !hasLoaded else { return }
        await fetch()
    }

    func fetch() async {
        generation += 1
        let request = generation
        isRefreshing = true
        defer { if request == generation { isRefreshing = false } }
        // A "load more" still in flight belongs to the old list and will be dropped.
        isLoadingMore = false
        if events.isEmpty {
            state = .loading
        }

        do {
            let response = try await client.fetchEvents(query: query, page: 1)
            try Task.checkCancellation()
            guard request == generation else { return }
            events = Self.deduplicated(response)
            state = events.isEmpty ? .empty : .loaded
            nextPage = 2
            canLoadMore = query.supportsPagination && !events.isEmpty
            loadMoreError = nil
            hasLoaded = true
            cache.save(events, forKey: cacheKey)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            state = .afterFailure(error, hasContent: !events.isEmpty, surface: "events_\(query.rawValue)")
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isRefreshing, nextPage <= Self.maximumPage else { return }
        let request = generation
        let page = nextPage
        isLoadingMore = true
        loadMoreError = nil

        do {
            let response = try await client.fetchEvents(query: query, page: page)
            guard request == generation else { return }
            isLoadingMore = false
            let known = Set(events.map(\.id))
            let newEvents = Self.deduplicated(response).filter { !known.contains($0.id) }
            // The API doesn't report a page count, so an empty or repeated page is the end.
            guard !newEvents.isEmpty else {
                canLoadMore = false
                return
            }
            events += newEvents
            nextPage = page + 1
            canLoadMore = nextPage <= Self.maximumPage
        } catch {
            guard request == generation else { return }
            isLoadingMore = false
            if error is CancellationError { return }
            loadMoreError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadCache() {
        guard let cached = cache.load([V3EventSummary].self, forKey: cacheKey) else { return }
        events = cached
        state = cached.isEmpty ? .empty : .loaded
        canLoadMore = query.supportsPagination && !cached.isEmpty
    }

    private static func deduplicated(_ events: [V3EventSummary]) -> [V3EventSummary] {
        var seen = Set<Int>()
        return events.filter { seen.insert($0.id).inserted }
    }
}

/// Everything `EventDetailView` shows. The overview loads first; matches and stats load
/// the first time their section opens, and other stages load when picked.
@MainActor
final class EventDetailViewModel: ObservableObject {
    @Published private(set) var detail: V3EventDetail?
    @Published private(set) var detailState: ListLoadState = .idle

    /// Details for stages other than the one the overview came with, by slug.
    @Published private(set) var stageDetails: [String: V3EventDetail] = [:]
    @Published private(set) var stageStates: [String: ListLoadState] = [:]

    @Published private(set) var matches: [V3Match] = []
    @Published private(set) var matchesState: ListLoadState = .idle

    @Published private(set) var stats: [V3EventPlayerStats] = []
    @Published private(set) var statsState: ListLoadState = .idle

    let eventID: Int
    private let client: VLRAPIClient
    private let cache: ListCache

    private var detailCacheKey: String { "v3.events.\(eventID).detail" }
    private var matchesCacheKey: String { "v3.events.\(eventID).matches" }
    private var statsCacheKey: String { "v3.events.\(eventID).stats" }

    init(eventID: Int, client: VLRAPIClient = .init(), cache: ListCache = .shared) {
        self.eventID = eventID
        self.client = client
        self.cache = cache
        if let cached = cache.load(V3EventDetail.self, forKey: detailCacheKey), cached.id == eventID {
            detail = cached
            detailState = .loaded
        }
    }

    /// Logos from every team list loaded so far (event teams, prizes, groups), for
    /// match rows that came without one.
    var teamLogoDirectory: TeamLogoDirectory {
        var directory = TeamLogoDirectory()
        for detail in [detail].compactMap({ $0 }) + stageDetails.values {
            for entry in detail.teams { directory.add(entry.team) }
            for prize in detail.prizes { prize.team.map { directory.add($0) } }
            for group in detail.groups {
                for row in group.teams { directory.add(row.team) }
            }
        }
        return directory
    }

    /// The slug of the stage the overview's groups and brackets belong to.
    var defaultStageSlug: String? {
        detail?.activeStage?.slug ?? detail?.stages.first(where: { $0.active == true })?.slug
    }

    func fetchDetail() async {
        if detail == nil {
            detailState = .loading
        }
        do {
            let response = try await client.fetchEventDetail(id: eventID)
            try Task.checkCancellation()
            detail = response
            detailState = .loaded
            cache.save(response, forKey: detailCacheKey)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            detailState = .afterFailure(error, hasContent: detail != nil, surface: "event_detail")
        }
    }

    /// Loads a stage other than the default one, unless it's already on screen.
    func fetchStage(_ slug: String, force: Bool = false) async {
        guard slug != defaultStageSlug else { return }
        if !force, stageDetails[slug] != nil { return }
        if stageDetails[slug] == nil {
            stageStates[slug] = .loading
        }
        do {
            let response = try await client.fetchEventDetail(id: eventID, stage: slug)
            try Task.checkCancellation()
            stageDetails[slug] = response
            stageStates[slug] = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            stageStates[slug] = .afterFailure(error, hasContent: stageDetails[slug] != nil, surface: "event_stage")
        }
    }

    func fetchMatches(force: Bool = false) async {
        if !force, matchesState == .loaded || matchesState == .empty { return }
        if matches.isEmpty {
            if let cached = cache.load([V3Match].self, forKey: matchesCacheKey), !cached.isEmpty {
                matches = cached
            } else {
                matchesState = .loading
            }
        }
        do {
            let response = try await client.fetchEventMatches(id: eventID)
            try Task.checkCancellation()
            matches = response
            matchesState = response.isEmpty ? .empty : .loaded
            cache.save(response, forKey: matchesCacheKey)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            matchesState = .afterFailure(error, hasContent: !matches.isEmpty, surface: "event_matches")
        }
    }

    func fetchStats(force: Bool = false) async {
        if !force, statsState == .loaded || statsState == .empty { return }
        if stats.isEmpty {
            if let cached = cache.load([V3EventPlayerStats].self, forKey: statsCacheKey), !cached.isEmpty {
                stats = cached
            } else {
                statsState = .loading
            }
        }
        do {
            let response = try await client.fetchEventStats(id: eventID)
            try Task.checkCancellation()
            stats = response
            statsState = response.isEmpty ? .empty : .loaded
            cache.save(response, forKey: statsCacheKey)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            statsState = .afterFailure(error, hasContent: !stats.isEmpty, surface: "event_stats")
        }
    }
}
