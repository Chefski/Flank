//
//  UpcomingMatchesViewModel.swift
//  Flank
//

import Foundation

enum V3MatchListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case cachedOffline(String)
    case failed(message: String, retryable: Bool)
}

@MainActor
class V3MatchListStore: ObservableObject {
    @Published private(set) var matches: [V3Match] = []
    @Published private(set) var state: V3MatchListLoadState = .idle

    let query: V3MatchQuery
    private let client: VLRAPIClient
    private let defaults: UserDefaults

    private var cacheKey: String { "v3.matches.\(query.rawValue)" }

    init(
        query: V3MatchQuery,
        client: VLRAPIClient = .init(),
        defaults: UserDefaults = .standard
    ) {
        self.query = query
        self.client = client
        self.defaults = defaults
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
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if matches.isEmpty {
                state = .failed(
                    message: message,
                    retryable: (error as? VLRAPIError)?.isRetryable ?? true
                )
            } else {
                state = .cachedOffline(message)
            }
        }
    }

    private func loadCache() {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? VLRAPI.decoder.decode([V3Match].self, from: data) else {
            return
        }
        matches = cached
        state = cached.isEmpty ? .empty : .loaded
    }

    private func saveCache() {
        guard let encoded = try? VLRAPI.encoder.encode(matches) else { return }
        defaults.set(encoded, forKey: cacheKey)
    }
}

@MainActor
final class ShowUpcoming: V3MatchListStore {
    init(client: VLRAPIClient = .init(), defaults: UserDefaults = .standard) {
        super.init(query: .upcoming, client: client, defaults: defaults)
    }
}
