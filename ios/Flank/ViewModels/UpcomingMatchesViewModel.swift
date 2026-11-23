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
    @MainActor
    static func afterFailure(_ error: Error, hasContent: Bool, surface: String) -> ListLoadState {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let category = AnalyticsErrorCategory(error)
        if hasContent {
            Analytics.track(.offlineCachePresented(surface: surface, category: category))
            return .showingSaved(message: message, isOffline: category == .offline)
        }
        let retryable = (error as? VLRAPIError)?.isRetryable ?? true
        Analytics.track(.loadFailed(surface: surface, category: category, retryable: retryable))
        return .failed(message: message, retryable: retryable)
    }
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

    func fetch() async {
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
            state = .afterFailure(error, hasContent: !matches.isEmpty, surface: "matches_\(query.rawValue)")
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
