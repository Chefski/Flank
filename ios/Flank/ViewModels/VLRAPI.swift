//
//  VLRAPI.swift
//  Flank
//

import Foundation
import SwiftUI

struct VLRAPIConfiguration: Sendable {
    var host: String
    var v2Path: String
    var v3Path: String
    var timeout: TimeInterval

    static let production = VLRAPIConfiguration(
        host: "https://flank-vlr-api.vercel.app",
        v2Path: "v2",
        v3Path: "v3",
        timeout: 20
    )

    init(
        host: String,
        v2Path: String = "v2",
        v3Path: String = "v3",
        timeout: TimeInterval = 20
    ) {
        self.host = host
        self.v2Path = v2Path
        self.v3Path = v3Path
        self.timeout = timeout
    }

    func url(versionPath: String, path: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: host),
              components.scheme != nil,
              components.host != nil else {
            throw VLRAPIError.invalidURL
        }

        let baseSegments = components.path.split(separator: "/").map(String.init)
        let allSegments = baseSegments + [versionPath] + path
        components.path = "/" + allSegments
            .flatMap { $0.split(separator: "/") }
            .map(String.init)
            .joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw VLRAPIError.invalidURL
        }
        return url
    }
}

enum VLRAPIError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case transport(URLError.Code)
    case requestFailed(String?)

    var isRetryable: Bool {
        switch self {
        case .httpStatus(let statusCode):
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .transport:
            return true
        case .invalidURL, .invalidResponse, .requestFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The VLR API URL could not be created."
        case .invalidResponse:
            return "The VLR API returned an invalid response."
        case .httpStatus(let statusCode):
            return "The VLR API returned HTTP status \(statusCode)."
        case .transport(let code):
            return URLError(code).localizedDescription
        case .requestFailed(let message):
            return message ?? "The VLR API request failed."
        }
    }
}

private struct V2Response<Value: Decodable>: Decodable {
    let status: String
    let data: Value
    let message: String?
}

struct V3Response<Value: Codable & Sendable, Metadata: Codable & Sendable>: Codable, Sendable {
    let apiVersion: String
    let data: Value
    let meta: Metadata

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case data
        case meta
    }
}

struct V3EntityMeta: Codable, Hashable, Sendable {
    let source: String?
    let id: Int
}

struct V3MatchListMeta: Codable, Hashable, Sendable {
    let source: String?
    let query: V3MatchQuery
    let pageRange: String?
    let totalPagesRequested: Int?
    let successfulPages: Int?
    let failedPages: [Int]
    let eventID: Int?

    enum CodingKeys: String, CodingKey {
        case source, query
        case pageRange = "page_range"
        case totalPagesRequested = "total_pages_requested"
        case successfulPages = "successful_pages"
        case failedPages = "failed_pages"
        case eventID = "event_id"
    }
}

enum V3MatchQuery: String, Codable, CaseIterable, Sendable {
    case upcoming
    case upcomingExtended = "upcoming_extended"
    case liveScore = "live_score"
    case results
    case event
}

enum V3MatchStatus: String, Codable, Sendable {
    case scheduled
    case live
    case completed
    case unknown

    var displayName: String {
        switch self {
        case .scheduled: "Scheduled"
        case .live: "Live"
        case .completed: "Completed"
        case .unknown: "Status unavailable"
        }
    }
}

enum V3MatchSource: String, Codable, Sendable {
    case upcoming
    case live
    case matches
    case results
    case event
    case team
    case player
}

struct V3DisplayTime: Codable, Hashable, Sendable {
    let date: String?
    let time: String?
    let relative: String?
}

struct V3Image: Codable, Hashable, Sendable {
    let url: String?
    let lightURL: String?
    let darkURL: String?

    enum CodingKeys: String, CodingKey {
        case url
        case lightURL = "light_url"
        case darkURL = "dark_url"
    }

    func preferred(for colorScheme: ColorScheme) -> String? {
        VLRAPI.preferredLogo(
            fallback: url,
            light: lightURL,
            dark: darkURL,
            for: colorScheme
        )
    }
}

struct V3EventRef: Codable, Hashable, Sendable {
    let id: Int?
    let name: String
    let stage: String?
    let stageSlug: String?
    let series: String?
    let url: String?
    let image: V3Image

    enum CodingKeys: String, CodingKey {
        case id, name, stage, series, url, image
        case stageSlug = "stage_slug"
    }
}

struct V3TeamRef: Codable, Hashable, Sendable {
    let id: Int?
    let name: String
    let tag: String?
    let countryCode: String?
    let region: String?
    let url: String?
    let image: V3Image
    let score: Int?
    let isWinner: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, tag, region, url, image, score
        case countryCode = "country_code"
        case isWinner = "is_winner"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        image = try container.decode(V3Image.self, forKey: .image)
        score = try container.decodeIfPresent(Int.self, forKey: .score)
        isWinner = try container.decodeIfPresent(Bool.self, forKey: .isWinner) ?? false
    }
}

struct V3Match: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let statsID: Int?
    let source: V3MatchSource
    let url: String
    let status: V3MatchStatus
    let statusText: String?
    let startsAt: Date?
    let display: V3DisplayTime
    let event: V3EventRef
    let teams: [V3TeamRef]
    let note: String?
    let page: Int?

    enum CodingKeys: String, CodingKey {
        case id, source, url, status, display, event, teams, note, page
        case statsID = "stats_id"
        case statusText = "status_text"
        case startsAt = "starts_at"
    }

    var firstTeam: V3TeamRef? { teams.first }
    var secondTeam: V3TeamRef? { teams.dropFirst().first }
}

struct V3Stream: Codable, Hashable, Identifiable, Sendable {
    var id: String { url }
    let name: String
    let url: String
    let platform: String?
    let countryCode: String?
    let embedded: Bool
    let siteID: String?

    enum CodingKeys: String, CodingKey {
        case name, url, platform, embedded
        case countryCode = "country_code"
        case siteID = "site_id"
    }
}

struct V3Vod: Codable, Hashable, Identifiable, Sendable {
    var id: String { url }
    let name: String
    let url: String
    let platform: String?
    let mapNumber: Int?

    enum CodingKeys: String, CodingKey {
        case name, url, platform
        case mapNumber = "map_number"
    }
}

struct V3Score: Codable, Hashable, Sendable {
    let team1: Int?
    let team2: Int?
}

struct V3TeamSideScore: Codable, Hashable, Sendable {
    let total: Int?
    let attack: Int?
    let defense: Int?
    let overtime: Int?
}

struct V3MapSideScores: Codable, Hashable, Sendable {
    let team1: V3TeamSideScore
    let team2: V3TeamSideScore
}

struct V3MapPick: Codable, Hashable, Sendable {
    let slot: String?
    let team: V3TeamRef?
}

struct V3PlayerRef: Codable, Hashable, Sendable {
    let id: Int?
    let name: String
    let url: String?

    var identityKey: String { id.map(String.init) ?? url ?? name }
}

struct V3PlayerSideStats: Codable, Hashable, Sendable {
    let rating: Double?
    let averageCombatScore: Double?
    let kills: Int?
    let deaths: Int?
    let assists: Int?
    let killDeathDifferential: Int?
    let kastPercent: Double?
    let averageDamagePerRound: Double?
    let headshotPercent: Double?
    let firstKills: Int?
    let firstDeaths: Int?
    let firstKillDifferential: Int?

    enum CodingKeys: String, CodingKey {
        case rating, kills, deaths, assists
        case averageCombatScore = "average_combat_score"
        case killDeathDifferential = "kill_death_differential"
        case kastPercent = "kast_percent"
        case averageDamagePerRound = "average_damage_per_round"
        case headshotPercent = "headshot_percent"
        case firstKills = "first_kills"
        case firstDeaths = "first_deaths"
        case firstKillDifferential = "first_kill_differential"
    }
}

struct V3MapPlayerStats: Codable, Hashable, Sendable {
    let rating: Double?
    let averageCombatScore: Double?
    let kills: Int?
    let deaths: Int?
    let assists: Int?
    let killDeathDifferential: Int?
    let kastPercent: Double?
    let averageDamagePerRound: Double?
    let headshotPercent: Double?
    let firstKills: Int?
    let firstDeaths: Int?
    let firstKillDifferential: Int?
    let player: V3PlayerRef
    let countryCode: String?
    let teamTag: String?
    let agent: String?
    let agentSlug: String?
    let attack: V3PlayerSideStats
    let defense: V3PlayerSideStats

    enum CodingKeys: String, CodingKey {
        case rating, kills, deaths, assists, player, agent, attack, defense
        case averageCombatScore = "average_combat_score"
        case killDeathDifferential = "kill_death_differential"
        case kastPercent = "kast_percent"
        case averageDamagePerRound = "average_damage_per_round"
        case headshotPercent = "headshot_percent"
        case firstKills = "first_kills"
        case firstDeaths = "first_deaths"
        case firstKillDifferential = "first_kill_differential"
        case countryCode = "country_code"
        case teamTag = "team_tag"
        case agentSlug = "agent_slug"
    }
}

struct V3GamePlayers: Codable, Hashable, Sendable {
    let team1: [V3MapPlayerStats]
    let team2: [V3MapPlayerStats]
}

enum V3GameStatus: String, Codable, Sendable {
    case scheduled
    case inProgress = "in_progress"
    case completed
    case unknown
}

enum V3RoundWinner: String, Codable, Sendable {
    case team1
    case team2
    case unknown
}

enum V3Side: String, Codable, Sendable {
    case attack
    case defense
    case unknown
}

struct V3Round: Codable, Hashable, Identifiable, Sendable {
    var id: Int { number }
    let number: Int
    let winner: V3RoundWinner
    let side: V3Side
    let method: String?
    let methodCode: String?
    let methodIconURL: String?
    let scoreAfter: V3Score

    enum CodingKeys: String, CodingKey {
        case number, winner, side, method
        case methodCode = "method_code"
        case methodIconURL = "method_icon_url"
        case scoreAfter = "score_after"
    }
}

struct V3Matchup: Codable, Hashable, Sendable {
    let opponent: V3PlayerRef
    let kills: Int?
    let deaths: Int?
    let differential: Int?
}

struct V3KillMatrixRow: Codable, Hashable, Sendable {
    let player: V3PlayerRef
    let teamTag: String?
    let matchups: [V3Matchup]

    enum CodingKeys: String, CodingKey {
        case player, matchups
        case teamTag = "team_tag"
    }
}

struct V3MultiKills: Codable, Hashable, Sendable {
    let two: Int?
    let three: Int?
    let four: Int?
    let five: Int?
}

struct V3Clutches: Codable, Hashable, Sendable {
    let oneVsOne: Int?
    let oneVsTwo: Int?
    let oneVsThree: Int?
    let oneVsFour: Int?
    let oneVsFive: Int?

    enum CodingKeys: String, CodingKey {
        case oneVsOne = "one_vs_one"
        case oneVsTwo = "one_vs_two"
        case oneVsThree = "one_vs_three"
        case oneVsFour = "one_vs_four"
        case oneVsFive = "one_vs_five"
    }
}

struct V3AdvancedPlayerStats: Codable, Hashable, Sendable {
    let player: V3PlayerRef
    let teamTag: String?
    let agent: String?
    let agentSlug: String?
    let multiKills: V3MultiKills
    let clutches: V3Clutches
    let economyRating: Int?
    let plants: Int?
    let defuses: Int?

    enum CodingKeys: String, CodingKey {
        case player, agent, plants, defuses
        case teamTag = "team_tag"
        case agentSlug = "agent_slug"
        case multiKills = "multi_kills"
        case clutches
        case economyRating = "economy_rating"
    }
}

struct V3Performance: Codable, Hashable, Sendable {
    let killMatrix: [V3KillMatrixRow]
    let advancedStats: [V3AdvancedPlayerStats]

    enum CodingKeys: String, CodingKey {
        case killMatrix = "kill_matrix"
        case advancedStats = "advanced_stats"
    }

    var isEmpty: Bool { killMatrix.isEmpty && advancedStats.isEmpty }
}

struct V3EconomyBucket: Codable, Hashable, Sendable {
    let rounds: Int?
    let wins: Int?
}

struct V3EconomyRow: Codable, Hashable, Sendable {
    let teamID: Int?
    let teamTag: String?
    let pistolWins: Int?
    let pistolWinPercent: Double?
    let eco: V3EconomyBucket
    let low: V3EconomyBucket
    let medium: V3EconomyBucket
    let full: V3EconomyBucket

    enum CodingKeys: String, CodingKey {
        case eco, low, medium, full
        case teamID = "team_id"
        case teamTag = "team_tag"
        case pistolWins = "pistol_wins"
        case pistolWinPercent = "pistol_win_percent"
    }

    var identityKey: String { teamID.map(String.init) ?? teamTag ?? "unknown-team" }
}

struct V3Game: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let number: Int
    let mapName: String?
    let status: V3GameStatus
    let duration: String?
    let pick: V3MapPick?
    let score: V3Score
    let sideScores: V3MapSideScores
    let players: V3GamePlayers
    let rounds: [V3Round]
    let url: String?
    let performance: V3Performance
    let economy: [V3EconomyRow]

    enum CodingKeys: String, CodingKey {
        case id, number, status, duration, pick, score, players, rounds, url, performance, economy
        case mapName = "map_name"
        case sideScores = "side_scores"
    }
}

struct V3GamePerformance: Codable, Hashable, Identifiable, Sendable {
    var id: Int { gameID }
    let killMatrix: [V3KillMatrixRow]
    let advancedStats: [V3AdvancedPlayerStats]
    let gameID: Int

    enum CodingKeys: String, CodingKey {
        case killMatrix = "kill_matrix"
        case advancedStats = "advanced_stats"
        case gameID = "game_id"
    }
}

struct V3GameEconomy: Codable, Hashable, Identifiable, Sendable {
    var id: Int { gameID }
    let gameID: Int
    let teams: [V3EconomyRow]

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case teams
    }
}

struct V3HeadToHead: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let url: String
    let eventName: String?
    let eventSeries: String?
    let dateText: String?
    let teams: [V3TeamRef]
    let score: V3Score

    enum CodingKeys: String, CodingKey {
        case id, url, teams, score
        case eventName = "event_name"
        case eventSeries = "event_series"
        case dateText = "date_text"
    }
}

struct V3MatchDetail: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let statsID: Int?
    let url: String
    let status: V3MatchStatus
    let startsAt: Date?
    let dateText: String?
    let patch: String?
    let format: String?
    let mapVetos: String?
    let notes: [String]
    let event: V3EventRef
    let teams: [V3TeamRef]
    let streams: [V3Stream]
    let vods: [V3Vod]
    let games: [V3Game]
    let headToHead: [V3HeadToHead]
    let performance: V3Performance
    let performanceByGame: [V3GamePerformance]
    let economy: [V3EconomyRow]
    let economyByGame: [V3GameEconomy]

    enum CodingKeys: String, CodingKey {
        case id, url, status, patch, format, notes, event, teams, streams, vods, games, performance, economy
        case statsID = "stats_id"
        case startsAt = "starts_at"
        case dateText = "date_text"
        case mapVetos = "map_vetos"
        case headToHead = "head_to_head"
        case performanceByGame = "performance_by_game"
        case economyByGame = "economy_by_game"
    }

    var firstTeam: V3TeamRef? { teams.first }
    var secondTeam: V3TeamRef? { teams.dropFirst().first }
}

struct VLRAPIClient: @unchecked Sendable {
    let configuration: VLRAPIConfiguration
    let session: URLSession

    init(configuration: VLRAPIConfiguration = .production, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchV2<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Value {
        let url = try configuration.url(
            versionPath: configuration.v2Path,
            path: [path],
            queryItems: queryItems
        )
        let body: V2Response<Value> = try await request(url)
        guard body.status == "success" else {
            throw VLRAPIError.requestFailed(body.message)
        }
        return body.data
    }

    func fetchMatches(query: V3MatchQuery) async throws -> [V3Match] {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["matches"],
            queryItems: [URLQueryItem(name: "q", value: query.rawValue)]
        )
        let body: V3Response<[V3Match], V3MatchListMeta> = try await request(url)
        return body.data
    }

    func fetchMatchDetail(id: Int) async throws -> V3MatchDetail {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["matches", String(id)]
        )
        let body: V3Response<V3MatchDetail, V3EntityMeta> = try await request(url)
        guard body.data.id == id, body.meta.id == id else {
            throw VLRAPIError.invalidResponse
        }
        return body.data
    }

    func fetchNews(page: Int = 1) async throws -> (articles: [V3NewsSummary], meta: V3PageMeta) {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["news"],
            queryItems: [URLQueryItem(name: "page", value: String(page))]
        )
        let body: V3Response<[V3NewsSummary], V3PageMeta> = try await request(url)
        guard body.meta.page == page else {
            throw VLRAPIError.invalidResponse
        }
        return (body.data, body.meta)
    }

    func fetchNewsArticle(id: Int) async throws -> V3NewsArticle {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["news", String(id)]
        )
        let body: V3Response<V3NewsArticle, V3EntityMeta> = try await request(url)
        guard body.data.id == id, body.meta.id == id else {
            throw VLRAPIError.invalidResponse
        }
        return body.data
    }

    private func request<Value: Decodable>(_ url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                throw CancellationError()
            }
            throw VLRAPIError.transport(error.code)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VLRAPIError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VLRAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw VLRAPIError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try VLRAPI.decoder.decode(Value.self, from: data)
        } catch {
            throw VLRAPIError.requestFailed("The VLR API response could not be decoded: \(error.localizedDescription)")
        }
    }
}

struct V3MatchDetailResult: Sendable {
    let detail: V3MatchDetail
    let isStale: Bool
}

actor V3MatchDetailRepository {
    typealias Loader = @Sendable (Int) async throws -> V3MatchDetail

    private struct CacheEntry {
        let detail: V3MatchDetail
        let storedAt: Date
    }

    private struct InFlight {
        let task: Task<V3MatchDetail, Error>
        var waiters: Set<UUID>
    }

    static let shared = V3MatchDetailRepository()

    private let cacheTTL: TimeInterval
    private let loader: Loader
    private let now: @Sendable () -> Date
    private var cache: [Int: CacheEntry] = [:]
    private var inFlight: [Int: InFlight] = [:]

    init(
        cacheTTL: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        loader: Loader? = nil
    ) {
        let client = VLRAPIClient()
        self.cacheTTL = cacheTTL
        self.now = now
        self.loader = loader ?? { id in
            try await client.fetchMatchDetail(id: id)
        }
    }

    func detail(id: Int, forceRefresh: Bool = false) async throws -> V3MatchDetailResult {
        let staleEntry = cache[id]
        if !forceRefresh,
           let entry = staleEntry,
           now().timeIntervalSince(entry.storedAt) < cacheTTL {
            return V3MatchDetailResult(detail: entry.detail, isStale: false)
        }

        let waiterID = UUID()
        let task: Task<V3MatchDetail, Error>
        if var current = inFlight[id] {
            current.waiters.insert(waiterID)
            inFlight[id] = current
            task = current.task
        } else {
            let newTask = Task { try await loader(id) }
            inFlight[id] = InFlight(task: newTask, waiters: [waiterID])
            task = newTask
        }

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                try Task.checkCancellation()
                cache[id] = CacheEntry(detail: value, storedAt: now())
                finishWaiter(waiterID, matchID: id)
                return V3MatchDetailResult(detail: value, isStale: false)
            } catch is CancellationError {
                finishWaiter(waiterID, matchID: id)
                throw CancellationError()
            } catch {
                finishWaiter(waiterID, matchID: id)
                if let staleEntry {
                    return V3MatchDetailResult(detail: staleEntry.detail, isStale: true)
                }
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, matchID: id) }
        }
    }

    func removeAllCachedDetails() {
        cache.removeAll()
    }

    private func finishWaiter(_ waiterID: UUID, matchID: Int) {
        guard var current = inFlight[matchID] else { return }
        current.waiters.remove(waiterID)
        if current.waiters.isEmpty {
            inFlight[matchID] = nil
        } else {
            inFlight[matchID] = current
        }
    }

    private func cancelWaiter(_ waiterID: UUID, matchID: Int) {
        guard var current = inFlight[matchID] else { return }
        current.waiters.remove(waiterID)
        if current.waiters.isEmpty {
            current.task.cancel()
            inFlight[matchID] = nil
        } else {
            inFlight[matchID] = current
        }
    }
}

enum VLRAPI {
    static let productionClient = VLRAPIClient()

    static var decoder: JSONDecoder { makeDecoder() }
    static var encoder: JSONEncoder { makeEncoder() }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter.internetDateTime.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601/RFC3339 timestamp."
            )
        }
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var websiteURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.vlr.gg"
        guard let url = components.url else {
            preconditionFailure("The VLR.GG fallback URL is invalid.")
        }
        return url
    }

    static func pageURL(from value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("//") {
            return URL(string: "https:\(value)")
        }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        return URL(string: value, relativeTo: websiteURL)?.absoluteURL
    }

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
        let candidates = colorScheme == .dark ? [dark, light, fallback] : [light, fallback, dark]
        return candidates.compactMap { imageURL(from: $0) == nil ? nil : $0 }.first
    }

    static func fetch<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Value {
        try await productionClient.fetchV2(type, path: path, queryItems: queryItems)
    }
}

private extension ISO8601DateFormatter {
    static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
