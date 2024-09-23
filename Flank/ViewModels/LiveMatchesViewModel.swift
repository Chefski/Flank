//
//  LiveMatches.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct LiveAPIResponse: Codable {
    let data: LiveDataModel
}

struct LiveDataModel: Hashable, Codable {
    let status: Int
    let segments: [LiveMatch]
}

struct LiveMatch: Hashable, Codable {
    var team1: String
    var team2: String
    let flag1: String
    let flag2: String
    let score1: String
    let score2: String
    let team1_round_ct: String
    let team1_round_t: String
    let team2_round_ct: String
    let team2_round_t: String
    let map_number: String
    let current_map: String
    let time_until_match: String
    let match_series: String
    let match_event: String
    let unix_timestamp: String
    let match_page: String
}

class ShowLive: ObservableObject {
    @Published var liveMatches: [LiveMatch] = []
    private var timer: Timer?
    
    init() {
        startPeriodicFetch()
    }
    
    deinit {
        stopPeriodicFetch()
    }
    
    func startPeriodicFetch() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.fetch()
            }
        }
    }
    
    func stopPeriodicFetch() {
        timer?.invalidate()
        timer = nil
    }
    
    func fetch() async {
        guard let url = URL(string: "https://vlrggapi.vercel.app/match?q=live_score") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LiveAPIResponse.self, from: data)
            DispatchQueue.main.async {
                self.liveMatches = response.data.segments
            }
        } catch {
            print("Error fetching live matches: \(error)")
        }
    }
}