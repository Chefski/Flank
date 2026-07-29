//
//  LiveMatches.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

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
    var team1_logo: String
    var team2_logo: String
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
    let match_id: String?
}

@MainActor
final class ShowLive: ObservableObject {
    @Published var liveMatches: [LiveMatch] = []
    private var timer: Timer?
    
    init() {
        startPeriodicFetch()
    }
    
    deinit {
        timer?.invalidate()
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
        do {
            let response = try await VLRAPI.fetch(
                LiveDataModel.self,
                path: "match",
                queryItems: [URLQueryItem(name: "q", value: "live_score")]
            )
            var matches = response.segments
            let requests = matches.compactMap { match -> VLRMatchLogoRequest? in
                guard VLRAPI.imageURL(from: match.team1_logo) == nil ||
                        VLRAPI.imageURL(from: match.team2_logo) == nil else {
                    return nil
                }
                return VLRMatchLogoRequest(
                    matchPage: match.match_page,
                    team1: match.team1,
                    team2: match.team2
                )
            }
            let logosByMatch = await VLRAPI.fetchMatchLogos(for: requests)

            for index in matches.indices {
                guard let logos = logosByMatch[matches[index].match_page] else {
                    continue
                }
                if VLRAPI.imageURL(from: matches[index].team1_logo) == nil {
                    matches[index].team1_logo = logos.team1 ?? ""
                }
                if VLRAPI.imageURL(from: matches[index].team2_logo) == nil {
                    matches[index].team2_logo = logos.team2 ?? ""
                }
            }

            liveMatches = matches
        } catch {
            print("Error fetching live matches: \(error)")
        }
    }
}
