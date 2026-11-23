//
//  StatsViewModel.swift
//  Flank
//
//  Created by Patryk Radziszewski on 11/02/2025.
//

import Foundation

struct StatsDataModel: Hashable, Codable {
    let status: Int
    let segments: [PlayerStats]
}

struct PlayerStats: Hashable, Codable {
    let player: String
    var player_id: String? = nil
    var player_url: String? = nil
    let org: String
    let agents: [String]
    let rounds_played: String
    let rating: String
    let average_combat_score: String
    let kill_deaths: String
    let kill_assists_survived_traded: String
    let average_damage_per_round: String
    let kills_per_round: String
    let assists_per_round: String
    let first_kills_per_round: String
    let first_deaths_per_round: String
    let headshot_percentage: String
    let clutch_success_percentage: String

    var identityKey: String {
        player_id ?? player_url ?? "\(player)|\(org)"
    }
}

@MainActor
final class ShowStats: ObservableObject {
    @Published private(set) var stats: [PlayerStats] = []
    @Published private(set) var state: ListLoadState = .idle

    /// Bumped per fetch so a slower, older request (e.g. a pull-to-refresh for the
    /// previous filters) can't overwrite the selection the user switched to.
    private var latestRequest = 0
    private let cache: ListCache

    init(cache: ListCache = .shared) {
        self.cache = cache
    }

    private func cacheKey(region: String, timespan: String) -> String {
        "cachedPlayerStats.\(region).\(timespan)"
    }

    private func loadCachedStats(region: String, timespan: String) {
        stats = cache.load([PlayerStats].self, forKey: cacheKey(region: region, timespan: timespan)) ?? []
    }
    
    private func cacheStats(region: String, timespan: String) {
        cache.save(stats, forKey: cacheKey(region: region, timespan: timespan))
    }
    
    func fetch(for region: String, for timespan: String) async {
        latestRequest += 1
        let request = latestRequest
        loadCachedStats(region: region, timespan: timespan)
        state = stats.isEmpty ? .loading : .loaded

        do {
            let response = try await VLRAPI.fetch(
                StatsDataModel.self,
                path: "stats",
                queryItems: [
                    URLQueryItem(name: "region", value: region),
                    URLQueryItem(name: "timespan", value: timespan),
                ]
            )
            try Task.checkCancellation()
            guard request == latestRequest else { return }
            stats = response.segments
            state = response.segments.isEmpty ? .empty : .loaded
            cacheStats(region: region, timespan: timespan)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, request == latestRequest else { return }
            state = .afterFailure(error, hasContent: !stats.isEmpty, surface: "stats")
        }
    }
}
