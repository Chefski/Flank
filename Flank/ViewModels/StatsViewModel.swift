//
//  StatsViewModel.swift
//  Flank
//
//  Created by Patryk Radziszewski on 11/02/2025.
//

import Foundation

struct StatsDataModel: Hashable, Codable {
    let data: StatsSegments
}

struct StatsSegments: Hashable, Codable {
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

class ShowStats: ObservableObject {
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
    
    func fetch(for region: String, for timespan: Int) async {
        guard let url = URL(string: "https://vlrggapi.vercel.app/stats?region=\(region)&timespan=\(timespan)") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            let response = try JSONDecoder().decode(StatsDataModel.self, from: data)
            DispatchQueue.main.async {
                self.stats = response.data.segments
                self.cacheStats()
            }
        } catch {
            print(error)
        }
    }
}
