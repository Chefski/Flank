//
//  UpcomingMatchesViewModel.swift
//  Flank
//

import Foundation

/// Shared load state for list screens (matches, news, rankings, stats).
enum ListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    /// A refresh failed, so the saved copy stays on screen. `isOffline` is true only
    /// when the connection was the problem, not the server or the data.
    case showingSaved(message: String, isOffline: Bool)
    case failed(message: String, retryable: Bool)

    /// The state after a failed load. Content already on screen stays visible with a
    /// notice saying why; otherwise the screen shows an error with an optional retry.
    ///
    /// - Parameter previous: The state before this load. The failure is only reported
    ///   when the state changes into saved or failed, so a poller that keeps failing
    ///   doesn't send an event per tick.
    @MainActor
    static func afterFailure(
        _ error: Error,
        hasContent: Bool,
        surface: String,
        previous: ListLoadState? = nil
    ) -> ListLoadState {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let category = AnalyticsErrorCategory(error)
        if hasContent {
            if previous?.isShowingSaved != true {
                Analytics.track(.offlineCachePresented(surface: surface, category: category))
            }
            return .showingSaved(message: message, isOffline: category == .offline)
        }
        let retryable = (error as? VLRAPIError)?.isRetryable ?? true
        if previous?.isFailed != true {
            Analytics.track(.loadFailed(surface: surface, category: category, retryable: retryable))
        }
        return .failed(message: message, retryable: retryable)
    }

    var isShowingSaved: Bool {
        if case .showingSaved = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The last refresh failed, whether or not saved content is on screen.
    var isFailing: Bool { isShowingSaved || isFailed }
}

@MainActor
class V3MatchListStore: ObservableObject {
    @Published private(set) var matches: [V3Match] = []
    @Published private(set) var state: ListLoadState = .idle

    let query: V3MatchQuery
    private let client: VLRAPIClient
    private let cache: ListCache

    private var cacheKey: String { "v3.matches.\(query.rawValue)" }

    init(
        query: V3MatchQuery,
        client: VLRAPIClient = .init(),
        cache: ListCache = .shared
    ) {
        self.query = query
        self.client = client
        self.cache = cache
        loadCache()
    }

    /// When the last fetch finished, successful or not; periodic refreshes count their
    /// interval from here, so a slow or timed-out request doesn't shorten the gap.
    private(set) var lastFetchFinishedAt: Date?

    func fetch() async {
        let previous = state
        defer { lastFetchFinishedAt = Date() }
        if matches.isEmpty {
            state = .loading
        }

        do {
            let response = try await client.fetchMatches(query: query)
            try Task.checkCancellation()
            matches = response
            state = response.isEmpty ? .empty : .loaded
            saveCache()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .afterFailure(
                error,
                hasContent: !matches.isEmpty,
                surface: "matches_\(query.rawValue)",
                previous: previous
            )
        }
    }

    private func loadCache() {
        guard let cached = cache.load([V3Match].self, forKey: cacheKey) else { return }
        matches = cached
        state = cached.isEmpty ? .empty : .loaded
    }

    private func saveCache() {
        cache.save(matches, forKey: cacheKey)
    }
}

@MainActor
final class ShowUpcoming: V3MatchListStore {
    init(client: VLRAPIClient = .init(), cache: ListCache = .shared) {
        super.init(query: .upcoming, client: client, cache: cache)
    }
}
