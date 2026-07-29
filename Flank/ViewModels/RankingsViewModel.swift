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
    var logoURL: URL? {
        return URL(string: "https:" + logo)
    }
}

@MainActor
final class ShowRankings: ObservableObject {
    @Published var rankings: [Rankings] = []
    private let cacheKey = "cachedRankings"
    
    init() {
        loadCachedRankings()
    }
    
    private func loadCachedRankings() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedRankings = try? JSONDecoder().decode([Rankings].self, from: data) {
            self.rankings = cachedRankings
        }
    }
    
    private func cacheRankings() {
        if let encodedData = try? JSONEncoder().encode(rankings) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey)
        }
    }
    
    func fetch(for region: String) async {
        do {
            let response = try await VLRAPI.fetch(
                RankingsDataModel.self,
                path: "rankings",
                queryItems: [URLQueryItem(name: "region", value: region)]
            )
            rankings = response.segments
            cacheRankings()
        } catch {
            print(error)
        }
    }
}
