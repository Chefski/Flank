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
    var team1_logo_light: String? = nil
    var team1_logo_dark: String? = nil
    var team2_logo_light: String? = nil
    var team2_logo_dark: String? = nil
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
                guard VLRAPI.needsLogoVariants(
                    fallback: match.team1_logo,
                    light: match.team1_logo_light,
                    dark: match.team1_logo_dark
                ) || VLRAPI.needsLogoVariants(
                    fallback: match.team2_logo,
                    light: match.team2_logo_light,
                    dark: match.team2_logo_dark
                ) else {
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
                matches[index].team1_logo_light = logos.team1Light
                matches[index].team1_logo_dark = logos.team1Dark
                if VLRAPI.imageURL(from: matches[index].team2_logo) == nil {
                    matches[index].team2_logo = logos.team2 ?? ""
                }
                matches[index].team2_logo_light = logos.team2Light
                matches[index].team2_logo_dark = logos.team2Dark
            }

            liveMatches = matches
        } catch {
            print("Error fetching live matches: \(error)")
        }
    }
}
