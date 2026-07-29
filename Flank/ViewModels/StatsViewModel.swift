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
}

@MainActor
final class ShowStats: ObservableObject {
    @Published var stats: [PlayerStats] = []
    private let cacheKey = "cachedPlayerStats"
    
    init() {
        loadCachedStats()
    }
    
    private func loadCachedStats() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedRankings = try? JSONDecoder().decode([PlayerStats].self, from: data) {
            self.stats = cachedRankings
        }
    }
    
    private func cacheStats() {
        if let encodedData = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey)
        }
    }
    
    func fetch(for region: String, for timespan: String) async {
        do {
            let response = try await VLRAPI.fetch(
                StatsDataModel.self,
                path: "stats",
                queryItems: [
                    URLQueryItem(name: "region", value: region),
                    URLQueryItem(name: "timespan", value: timespan),
                ]
            )
            stats = response.segments
            cacheStats()
        } catch {
            print(error)
        }
    }
}
