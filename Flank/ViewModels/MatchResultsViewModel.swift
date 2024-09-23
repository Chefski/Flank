//
//  MatchResults.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct ResultAPIResponse: Codable {
    let data: DataModel
}

struct DataModel: Codable {
    var status: Int
    var segments: [Match]
}

struct Match: Hashable, Codable {
    var team1: String
    var team2: String
    var score1: String
    var score2: String
    var flag1: String
    var flag2: String
    var time_completed: String
    var round_info: String
    var tournament_name: String
    var match_page: String
    var tournament_icon: String
}

class ShowResults: ObservableObject {
    @Published var matches: [Match] = []
    private let cacheKey = "cachedMatches"
    
    init() {
        loadCachedMatches()
    }
    
    private func loadCachedMatches() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedMatches = try? JSONDecoder().decode([Match].self, from: data) {
            self.matches = cachedMatches
        }
    }
    
    private func cacheMatches() {
        if let encodedData = try? JSONEncoder().encode(matches) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey)
        }
    }
    
    func fetch() async {
        guard let url = URL(string: "https://vlrggapi.vercel.app/match?q=results") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ResultAPIResponse.self, from: data)
            DispatchQueue.main.async {
                self.matches = response.data.segments
                self.cacheMatches()
            }
        } catch {
            print("Error fetching match results: \(error)")
        }
    }
}