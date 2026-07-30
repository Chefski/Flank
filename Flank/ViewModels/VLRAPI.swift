//
//  VLRAPI.swift
//  Flank
//

import Foundation
import SwiftUI

private struct VLRAPIResponse<Value: Decodable>: Decodable {
    let status: String
    let data: Value
    let message: String?
}

private struct VLRMatchDetailsDataModel: Decodable, Sendable {
    let segments: [VLRMatchDetails]
}

private struct VLRMatchDetails: Decodable, Sendable {
    let teams: [VLRMatchDetailsTeam]
}

private struct VLRMatchDetailsTeam: Decodable, Sendable {
    let name: String
    let logo: String
    let logo_light: String?
    let logo_dark: String?
}

struct VLRMatchLogoRequest: Hashable, Sendable {
    let matchPage: String
    let team1: String
    let team2: String
}

struct VLRMatchLogos: Hashable, Sendable {
    let team1: String?
    let team1Light: String?
    let team1Dark: String?
    let team2: String?
    let team2Light: String?
    let team2Dark: String?

    init(
        team1: String?,
        team1Light: String? = nil,
        team1Dark: String? = nil,
        team2: String?,
        team2Light: String? = nil,
        team2Dark: String? = nil
    ) {
        self.team1 = team1
        self.team1Light = team1Light
        self.team1Dark = team1Dark
        self.team2 = team2
        self.team2Light = team2Light
        self.team2Dark = team2Dark
    }
}

enum VLRAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case requestFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The VLR API URL could not be created."
        case .invalidResponse:
            return "The VLR API returned an invalid response."
        case .httpStatus(let statusCode):
            return "The VLR API returned HTTP status \(statusCode)."
        case .requestFailed(let message):
            return message ?? "The VLR API request failed."
        }
    }
}

enum VLRAPI {
    private static let baseURL = URL(string: "https://flank-vlr-api.vercel.app/v2/")!

    static func imageURL(from value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("//") {
            return URL(string: "https:\(value)")
        }

        return URL(string: value)
    }

    static func preferredLogo(
        fallback: String?,
        light: String?,
        dark: String?,
        for colorScheme: ColorScheme
    ) -> String? {
        let candidates = colorScheme == .dark
            ? [dark, light, fallback]
            : [light, fallback, dark]

        return candidates.compactMap { candidate in
            imageURL(from: candidate) == nil ? nil : candidate
        }.first
    }

    static func needsLogoVariants(
        fallback: String?,
        light: String?,
        dark: String?
    ) -> Bool {
        imageURL(from: fallback) == nil ||
            (imageURL(from: light) == nil && imageURL(from: dark) == nil)
    }

    static func fetchMatchLogos(
        for requests: [VLRMatchLogoRequest],
        maxConcurrentRequests: Int = 1
    ) async -> [String: VLRMatchLogos] {
        let uniqueRequests = Dictionary(
            requests.map { ($0.matchPage, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        let requests = Array(uniqueRequests)
        let batchSize = max(1, maxConcurrentRequests)
        var result: [String: VLRMatchLogos] = [:]

        for startIndex in stride(from: 0, to: requests.count, by: batchSize) {
            guard !Task.isCancelled else {
                break
            }

            let endIndex = min(startIndex + batchSize, requests.count)
            let batch = requests[startIndex..<endIndex]
            let batchResult = await withTaskGroup(
                of: (String, VLRMatchLogos?).self,
                returning: [String: VLRMatchLogos].self
            ) { group in
                for request in batch {
                    group.addTask {
                        guard !Task.isCancelled else {
                            return (request.matchPage, nil)
                        }

                        do {
                            let logos = try await fetchMatchLogos(for: request)
                            return (request.matchPage, logos)
                        } catch {
                            print("Error fetching match logos for \(request.matchPage): \(error)")
                            return (request.matchPage, nil)
                        }
                    }
                }

                var batchResult: [String: VLRMatchLogos] = [:]
                for await (matchPage, logos) in group {
                    if let logos {
                        batchResult[matchPage] = logos
                    }
                }
                return batchResult
            }
            result.merge(batchResult) { _, new in new }
        }

        return result
    }

    static func fetch<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Value {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw VLRAPIError.invalidURL
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw VLRAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VLRAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw VLRAPIError.httpStatus(httpResponse.statusCode)
        }

        let responseBody = try JSONDecoder().decode(VLRAPIResponse<Value>.self, from: data)
        guard responseBody.status == "success" else {
            throw VLRAPIError.requestFailed(responseBody.message)
        }

        return responseBody.data
    }

    private static func fetchMatchLogos(
        for request: VLRMatchLogoRequest
    ) async throws -> VLRMatchLogos? {
        guard let matchID = matchID(from: request.matchPage) else {
            return nil
        }

        let details = try await fetch(
            VLRMatchDetailsDataModel.self,
            path: "match/details",
            queryItems: [URLQueryItem(name: "match_id", value: matchID)]
        )
        guard let teams = details.segments.first?.teams else {
            return nil
        }

        let team1 = logoVariants(for: request.team1, in: teams, fallbackIndex: 0)
        let team2 = logoVariants(for: request.team2, in: teams, fallbackIndex: 1)

        return VLRMatchLogos(
            team1: team1?.fallback,
            team1Light: team1?.light,
            team1Dark: team1?.dark,
            team2: team2?.fallback,
            team2Light: team2?.light,
            team2Dark: team2?.dark
        )
    }

    private static func matchID(from matchPage: String) -> String? {
        let value = matchPage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        let path: String
        if let components = URLComponents(string: value), components.host != nil {
            path = components.path
        } else {
            path = value.components(separatedBy: "?").first ?? value
        }

        return path
            .split(separator: "/")
            .first
            .map(String.init)
    }

    private struct LogoVariants {
        let fallback: String?
        let light: String?
        let dark: String?
    }

    private static func logoVariants(
        for teamName: String,
        in teams: [VLRMatchDetailsTeam],
        fallbackIndex: Int
    ) -> LogoVariants? {
        let team = teams.first(where: {
            $0.name.compare(
                teamName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) ?? (teams.indices.contains(fallbackIndex) ? teams[fallbackIndex] : nil)

        guard let team else {
            return nil
        }

        return LogoVariants(
            fallback: imageURL(from: team.logo) == nil ? nil : team.logo,
            light: imageURL(from: team.logo_light) == nil ? nil : team.logo_light,
            dark: imageURL(from: team.logo_dark) == nil ? nil : team.logo_dark
        )
    }
}
