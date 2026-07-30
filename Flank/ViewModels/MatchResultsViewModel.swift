//
//  MatchResults.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct DataModel: Codable {
    var status: Int
    var segments: [Match]
}

struct Match: Hashable, Codable {
    var team1: String
    var team2: String
    var team1_logo: String? = nil
    var team2_logo: String? = nil
    var team1_logo_light: String? = nil
    var team1_logo_dark: String? = nil
    var team2_logo_light: String? = nil
    var team2_logo_dark: String? = nil
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

@MainActor
final class ShowResults: ObservableObject {
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
        do {
            let response = try await VLRAPI.fetch(
                DataModel.self,
                path: "match",
                queryItems: [URLQueryItem(name: "q", value: "results")]
            )
            let cachedLogos = Dictionary(
                matches.map {
                    (
                        $0.match_page,
                        VLRMatchLogos(
                            team1: $0.team1_logo,
                            team1Light: $0.team1_logo_light,
                            team1Dark: $0.team1_logo_dark,
                            team2: $0.team2_logo,
                            team2Light: $0.team2_logo_light,
                            team2Dark: $0.team2_logo_dark
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            var fetchedMatches = response.segments

            for index in fetchedMatches.indices {
                guard let logos = cachedLogos[fetchedMatches[index].match_page] else {
                    continue
                }
                if VLRAPI.imageURL(from: fetchedMatches[index].team1_logo) == nil {
                    fetchedMatches[index].team1_logo = logos.team1
                }
                fetchedMatches[index].team1_logo_light = logos.team1Light
                fetchedMatches[index].team1_logo_dark = logos.team1Dark
                if VLRAPI.imageURL(from: fetchedMatches[index].team2_logo) == nil {
                    fetchedMatches[index].team2_logo = logos.team2
                }
                fetchedMatches[index].team2_logo_light = logos.team2Light
                fetchedMatches[index].team2_logo_dark = logos.team2Dark
            }

            matches = fetchedMatches
            cacheMatches()

            guard !Task.isCancelled else {
                return
            }

            let requests = fetchedMatches.compactMap { match -> VLRMatchLogoRequest? in
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

            guard !Task.isCancelled else {
                return
            }

            for index in fetchedMatches.indices {
                guard let logos = logosByMatch[fetchedMatches[index].match_page] else {
                    continue
                }
                if VLRAPI.imageURL(from: fetchedMatches[index].team1_logo) == nil {
                    fetchedMatches[index].team1_logo = logos.team1
                }
                fetchedMatches[index].team1_logo_light = logos.team1Light
                fetchedMatches[index].team1_logo_dark = logos.team1Dark
                if VLRAPI.imageURL(from: fetchedMatches[index].team2_logo) == nil {
                    fetchedMatches[index].team2_logo = logos.team2
                }
                fetchedMatches[index].team2_logo_light = logos.team2Light
                fetchedMatches[index].team2_logo_dark = logos.team2Dark
            }

            matches = fetchedMatches
            cacheMatches()
        } catch {
            print("Error fetching match results: \(error)")
        }
    }
}
