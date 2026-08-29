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
    let logo_light: String?
    let logo_dark: String?
    var logoURL: URL? {
        return URL(string: "https:" + logo)
    }
}

@MainActor
final class ShowRankings: ObservableObject {
    @Published var rankings: [Rankings] = []

    private let legacyCacheKey = "cachedRankings"

    private func cacheKey(for region: String) -> String {
        "cachedRankings.\(region)"
    }

    private func loadCachedRankings(for region: String) {
        if let data = UserDefaults.standard.data(forKey: cacheKey(for: region)),
           let cachedRankings = try? JSONDecoder().decode([Rankings].self, from: data),
           !cachedRankings.isEmpty {
            rankings = cachedRankings
            return
        }

        let defaultRegion = UserDefaults.standard.string(forKey: "defaultRegion") ?? "na"
        if region == defaultRegion,
           let data = UserDefaults.standard.data(forKey: legacyCacheKey),
           let cachedRankings = try? JSONDecoder().decode([Rankings].self, from: data),
           !cachedRankings.isEmpty {
            rankings = cachedRankings
            return
        }

        rankings = []
    }
    
    private func cacheRankings(for region: String) {
        guard !rankings.isEmpty else {
            return
        }

        if let encodedData = try? JSONEncoder().encode(rankings) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey(for: region))
        }
    }
    
    func fetch(for region: String) async {
        loadCachedRankings(for: region)

        do {
            let response = try await VLRAPI.fetch(
                RankingsDataModel.self,
                path: "rankings",
                queryItems: [URLQueryItem(name: "region", value: region)]
            )

            guard !Task.isCancelled else {
                return
            }

            guard !response.segments.isEmpty else {
                Analytics.track(
                    .loadFailed(
                        surface: "rankings",
                        category: .invalidResponse,
                        retryable: true
                    )
                )
                return
            }

            rankings = response.segments
            cacheRankings(for: region)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            if rankings.isEmpty {
                Analytics.track(
                    .loadFailed(
                        surface: "rankings",
                        category: AnalyticsErrorCategory(error),
                        retryable: (error as? VLRAPIError)?.isRetryable ?? true
                    )
                )
            } else {
                Analytics.track(
                    .offlineCachePresented(
                        surface: "rankings",
                        category: AnalyticsErrorCategory(error)
                    )
                )
            }
            print(error)
        }
    }
}
