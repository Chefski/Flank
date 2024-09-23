//
//  UpcomingMatches.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct UpcomingAPIResponse: Codable {
    let data: UpcomingDataModel
}

struct UpcomingDataModel: Hashable, Codable {
    let status: Int
    let segments: [UpcomingMatch]
}

struct UpcomingMatch: Hashable, Codable {
    let team1: String
    let team2: String
    let flag1: String
    let flag2: String
    let time_until_match: String
    let match_series: String
    let match_event: String
    let unix_timestamp: String
    let match_page: String
}

class ShowUpcoming: ObservableObject {
    @Published var upcomingMatches: [UpcomingMatch] = []
    private let cacheKey = "cachedUpcomingMatches"
    
    init() {
        loadCachedMatches()
    }
    
    private func loadCachedMatches() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedMatches = try? JSONDecoder().decode([UpcomingMatch].self, from: data) {
            self.upcomingMatches = cachedMatches
        }
    }
    
    private func cacheMatches() {
        if let encodedData = try? JSONEncoder().encode(upcomingMatches) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey)
        }
    }
    
    func fetch() async {
        guard let url = URL(string: "https://vlrggapi.vercel.app/match?q=upcoming") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(UpcomingAPIResponse.self, from: data)
            DispatchQueue.main.async {
                self.upcomingMatches = response.data.segments
                self.cacheMatches()
            }
        } catch {
            print("Error fetching upcoming matches: \(error)")
        }
    }
}