//
//  UpcomingMatches.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct UpcomingDataModel: Hashable, Codable {
    let status: Int
    let segments: [UpcomingMatch]
}

struct UpcomingMatch: Hashable, Codable {
    let team1: String
    let team2: String
    var team1_logo: String? = nil
    var team2_logo: String? = nil
    let flag1: String
    let flag2: String
    let time_until_match: String
    let match_series: String
    let match_event: String
    let unix_timestamp: String
    let match_page: String
}

@MainActor
final class ShowUpcoming: ObservableObject {
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
        do {
            let response = try await VLRAPI.fetch(
                UpcomingDataModel.self,
                path: "match",
                queryItems: [URLQueryItem(name: "q", value: "upcoming")]
            )
            let cachedLogos = Dictionary(
                upcomingMatches.map {
                    (
                        $0.match_page,
                        VLRMatchLogos(team1: $0.team1_logo, team2: $0.team2_logo)
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            var matches = response.segments

            for index in matches.indices {
                guard let logos = cachedLogos[matches[index].match_page] else {
                    continue
                }
                if VLRAPI.imageURL(from: matches[index].team1_logo) == nil {
                    matches[index].team1_logo = logos.team1
                }
                if VLRAPI.imageURL(from: matches[index].team2_logo) == nil {
                    matches[index].team2_logo = logos.team2
                }
            }

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
                    matches[index].team1_logo = logos.team1
                }
                if VLRAPI.imageURL(from: matches[index].team2_logo) == nil {
                    matches[index].team2_logo = logos.team2
                }
            }

            upcomingMatches = matches
            cacheMatches()
        } catch {
            print("Error fetching upcoming matches: \(error)")
        }
    }
}
