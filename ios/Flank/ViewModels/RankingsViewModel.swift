//
//  Rankings.swift
//  Flank
//
//  Created by Patryk Radziszewski on 23/04/2024.
//

import Foundation

struct RankingsDataModel: Hashable, Codable {
    let status: Int
    let segments: [Rankings]
}

struct Rankings: Hashable, Codable {
    let rank: String
    let team: String
    let country: String
    let last_played: String
    let last_played_team: String
    let last_played_team_logo: String
    let record: String
    let earnings: String
    let logo: String
    let logo_light: String?
    let logo_dark: String?
    var logoURL: URL? {
        return URL(string: "https:" + logo)
    }
}

@MainActor
final class ShowRankings: ObservableObject {
    @Published private(set) var rankings: [Rankings] = []
    @Published private(set) var state: ListLoadState = .idle

    private let legacyCacheKey = "cachedRankings"
    /// Bumped per fetch so a slower, older request (e.g. a pull-to-refresh for the
    /// previous region) can't overwrite the selection the user switched to.
    private var latestRequest = 0
    private let cache: ListCache

    init(cache: ListCache = .shared) {
        self.cache = cache
    }

    private func cacheKey(for region: String) -> String {
        "cachedRankings.\(region)"
    }

    private func loadCachedRankings(for region: String) {
        if let cachedRankings = cache.load([Rankings].self, forKey: cacheKey(for: region)),
           !cachedRankings.isEmpty {
            rankings = cachedRankings
            return
        }

        let defaultRegion = UserDefaults.standard.string(forKey: "defaultRegion") ?? "na"
        if region == defaultRegion,
           let cachedRankings = cache.load([Rankings].self, forKey: legacyCacheKey),
           !cachedRankings.isEmpty {
            rankings = cachedRankings
            return
        }

        rankings = []
    }
    
    private func cacheRankings(for region: String) {
        guard !rankings.isEmpty else {
            return
        }

        cache.save(rankings, forKey: cacheKey(for: region))
    }
    
    func fetch(for region: String) async {
        latestRequest += 1
        let request = latestRequest
        loadCachedRankings(for: region)
        state = rankings.isEmpty ? .loading : .loaded

        do {
            let response = try await VLRAPI.fetch(
                RankingsDataModel.self,
                path: "rankings",
                queryItems: [URLQueryItem(name: "region", value: region)]
            )
            try Task.checkCancellation()
            guard request == latestRequest else { return }

            guard !response.segments.isEmpty else {
                if rankings.isEmpty {
                    Analytics.track(.loadFailed(surface: "rankings", category: .invalidResponse, retryable: true))
                    state = .empty
                }
                return
            }

            rankings = response.segments
            state = .loaded
            cacheRankings(for: region)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, request == latestRequest else { return }
            state = .afterFailure(error, hasContent: !rankings.isEmpty, surface: "rankings")
        }
    }
}
