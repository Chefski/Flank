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
    @Published var stats: [PlayerStats] = []

    private func cacheKey(region: String, timespan: String) -> String {
        "cachedPlayerStats.\(region).\(timespan)"
    }

    private func loadCachedStats(region: String, timespan: String) {
        if let data = UserDefaults.standard.data(forKey: cacheKey(region: region, timespan: timespan)),
           let cachedRankings = try? JSONDecoder().decode([PlayerStats].self, from: data) {
            stats = cachedRankings
        } else {
            stats = []
        }
    }
    
    private func cacheStats(region: String, timespan: String) {
        if let encodedData = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey(region: region, timespan: timespan))
        }
    }
    
    func fetch(for region: String, for timespan: String) async {
        loadCachedStats(region: region, timespan: timespan)

        do {
            let response = try await VLRAPI.fetch(
                StatsDataModel.self,
                path: "stats",
                queryItems: [
                    URLQueryItem(name: "region", value: region),
                    URLQueryItem(name: "timespan", value: timespan),
                ]
            )

            guard !Task.isCancelled else {
                return
            }
            stats = response.segments
            cacheStats(region: region, timespan: timespan)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            if stats.isEmpty {
                Analytics.track(
                    .loadFailed(
                        surface: "stats",
                        category: AnalyticsErrorCategory(error),
                        retryable: (error as? VLRAPIError)?.isRetryable ?? true
                    )
                )
            } else {
                Analytics.track(
                    .offlineCachePresented(
                        surface: "stats",
                        category: AnalyticsErrorCategory(error)
                    )
                )
            }
            print(error)
        }
    }
}
