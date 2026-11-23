//
//  EventsAPI.swift
//  Flank
//
//  Models and requests for the v3 event endpoints: `/v3/events`,
//  `/v3/events/{id}`, `/v3/events/{id}/matches` and `/v3/events/{id}/stats`.
//

import Foundation

// MARK: - Event list

/// The `q` filter of `GET /v3/events`.
enum V3EventListQuery: String, CaseIterable, Identifiable, Sendable {
    case live
    case upcoming
    case completed

    var id: Self { self }

    var title: String {
        switch self {
        case .live: String(localized: "Live")
        case .upcoming: String(localized: "Upcoming")
        case .completed: String(localized: "Completed")
        }
    }

    /// VLR.GG only pages its completed events; the other lists come back whole.
    var supportsPagination: Bool { self == .completed }
}

enum V3EventStatus: String, Codable, Sendable, UnknownCaseDecodable {
    case upcoming
    case ongoing
    case completed
    case unknown

    static let unknownCase = V3EventStatus.unknown
}

/// A prize amount. `display` is VLR.GG's own text, e.g. "$250,000" or "TBD".
struct V3EventMoney: Codable, Hashable, Sendable, EmptyDefaultable {
    let amount: Int?
    let currency: String?
    let display: String?

    static let emptyValue = V3EventMoney(amount: nil, currency: nil, display: nil)

    /// The text worth showing, leaving out empty and placeholder values.
    var displayText: String? {
        guard let display = display?.nilIfBlank else { return nil }
        if display.caseInsensitiveCompare("TBD") == .orderedSame || display == "$0" || display == "-" {
            return nil
        }
        return display
    }
}

struct V3EventSummary: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let status: V3EventStatus
    @DefaultEmpty var prize: V3EventMoney
    let dateText: String?
    let regionCode: String?
    let url: String
    @DefaultEmpty var image: V3Image

    enum CodingKeys: String, CodingKey {
        case id, name, status, prize, url, image
        case dateText = "date_text"
        case regionCode = "region_code"
    }
}

// MARK: - Event detail

struct V3EventCalendarLinks: Codable, Hashable, Sendable, EmptyDefaultable {
    let google: String?
    let apple: String?
    let subscription: String?
    let download: String?

    static let emptyValue = V3EventCalendarLinks(google: nil, apple: nil, subscription: nil, download: nil)
}

struct V3EventStage: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let slug: String?
    let dateText: String?
    let url: String?
    let active: Bool?

    var id: String { slug ?? name }

    enum CodingKeys: String, CodingKey {
        case name, slug, url, active
        case dateText = "date_text"
    }
}

struct V3EventPlayer: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case countryCode = "country_code"
    }
}

struct V3EventTeam: Codable, Hashable, Sendable {
    let team: V3TeamRef
    @DefaultEmpty var players: [V3EventPlayer]
    let qualification: String?
    let qualificationURL: String?

    enum CodingKeys: String, CodingKey {
        case team, players, qualification
        case qualificationURL = "qualification_url"
    }
}

struct V3EventPrize: Codable, Hashable, Sendable {
    let placement: String
    @DefaultEmpty var prize: V3EventMoney
    let team: V3TeamRef?
}

/// A standings table VLR.GG renders as plain columns, e.g. a league's season table.
struct V3EventStandingTable: Codable, Hashable, Sendable {
    let stage: String?
    @DefaultEmpty var columns: [String]
    @DefaultEmpty var rows: [[String?]]
}

enum V3EventGroupTeamState: String, Codable, Sendable, UnknownCaseDecodable {
    case advanced
    case eliminated
    case active
    case unknown

    static let unknownCase = V3EventGroupTeamState.unknown
}

struct V3EventGroupTeam: Codable, Hashable, Sendable {
    let rank: Int
    let team: V3TeamRef
    let state: V3EventGroupTeamState
    let seriesWins: Int?
    let seriesLosses: Int?
    let mapsWon: Int?
    let mapsLost: Int?
    let roundsWon: Int?
    let roundsLost: Int?
    let roundDifferential: Int?

    enum CodingKeys: String, CodingKey {
        case rank, team, state
        case seriesWins = "series_wins"
        case seriesLosses = "series_losses"
        case mapsWon = "maps_won"
        case mapsLost = "maps_lost"
        case roundsWon = "rounds_won"
        case roundsLost = "rounds_lost"
        case roundDifferential = "round_differential"
    }
}

/// A match inside an event's group or bracket. Lighter than `V3Match`: no event or status.
struct V3EventMatch: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let url: String
    let startsAt: Date?
    let dateText: String?
    let statusText: String?
    let series: String?
    let format: String?
    let hasStream: Bool?
    @DefaultEmpty var teams: [V3TeamRef]

    enum CodingKeys: String, CodingKey {
        case id, url, series, format, teams
        case startsAt = "starts_at"
        case dateText = "date_text"
        case statusText = "status_text"
        case hasStream = "has_stream"
    }

    var firstTeam: V3TeamRef? { teams.first }
    var secondTeam: V3TeamRef? { teams.dropFirst().first }
}

struct V3EventGroup: Codable, Hashable, Sendable {
    let id: Int?
    let name: String
    @DefaultEmpty var teams: [V3EventGroupTeam]
    @DefaultEmpty var matches: [V3EventMatch]
}

struct V3EventBracketRound: Codable, Hashable, Sendable {
    let name: String
    @DefaultEmpty var matches: [V3EventMatch]
}

struct V3EventBracket: Codable, Hashable, Sendable {
    /// "upper", "lower" or "main"; kept as a string so a new bracket kind still decodes.
    let type: String
    @DefaultEmpty var rounds: [V3EventBracketRound]
}

struct V3EventDetail: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let series: String?
    let subtitle: String?
    let dateText: String?
    @DefaultEmpty var prize: V3EventMoney
    let location: String?
    let regionCode: String?
    let url: String
    @DefaultEmpty var image: V3Image
    @DefaultEmpty var calendar: V3EventCalendarLinks
    @DefaultEmpty var stages: [V3EventStage]
    let activeStage: V3EventStage?
    @DefaultEmpty var teams: [V3EventTeam]
    @DefaultEmpty var prizes: [V3EventPrize]
    @DefaultEmpty var standings: [V3EventStandingTable]
    @DefaultEmpty var groups: [V3EventGroup]
    @DefaultEmpty var brackets: [V3EventBracket]

    enum CodingKeys: String, CodingKey {
        case id, name, series, subtitle, prize, location, url, image, calendar, stages
        case teams, prizes, standings, groups, brackets
        case dateText = "date_text"
        case regionCode = "region_code"
        case activeStage = "active_stage"
    }

    /// Whether the stage-specific sections (groups, tables, brackets) have anything to show.
    var hasStageContent: Bool {
        !groups.isEmpty || standings.contains { !$0.rows.isEmpty } || brackets.contains { !$0.rounds.isEmpty }
    }
}

// MARK: - Event stats

struct V3EventAgentUsage: Codable, Hashable, Sendable {
    let agent: String
    let usagePercent: Double?

    enum CodingKeys: String, CodingKey {
        case agent
        case usagePercent = "usage_percent"
    }
}

struct V3EventPlayerStats: Codable, Hashable, Identifiable, Sendable {
    let player: V3PlayerRef
    let countryCode: String?
    let organization: String?
    @DefaultEmpty var agents: [V3EventAgentUsage]
    let mapsPlayed: Int?
    let roundsPlayed: Int?
    let rating: Double?
    let averageCombatScore: Double?
    let killDeathRatio: Double?
    let kastPercent: Double?
    let averageDamagePerRound: Double?
    let killsPerRound: Double?
    let headshotPercent: Double?
    let clutchSuccessPercent: Double?
    let kills: Int?
    let deaths: Int?
    let assists: Int?
    let firstKills: Int?
    let firstDeaths: Int?

    var id: String { player.identityKey }

    enum CodingKeys: String, CodingKey {
        case player, organization, agents, rating, kills, deaths, assists
        case countryCode = "country_code"
        case mapsPlayed = "maps_played"
        case roundsPlayed = "rounds_played"
        case averageCombatScore = "average_combat_score"
        case killDeathRatio = "kill_death_ratio"
        case kastPercent = "kast_percent"
        case averageDamagePerRound = "average_damage_per_round"
        case killsPerRound = "kills_per_round"
        case headshotPercent = "headshot_percent"
        case clutchSuccessPercent = "clutch_success_percent"
        case firstKills = "first_kills"
        case firstDeaths = "first_deaths"
    }
}

struct V3EventStatsData: Codable, Hashable, Sendable {
    @DefaultEmpty var players: [V3EventPlayerStats]
}

// MARK: - Requests

extension VLRAPIClient {
    func fetchEvents(query: V3EventListQuery, page: Int = 1) async throws -> [V3EventSummary] {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["events"],
            queryItems: [
                URLQueryItem(name: "q", value: query.rawValue),
                URLQueryItem(name: "page", value: String(page)),
            ]
        )
        let body: V3Response<[V3EventSummary], V3PageMeta> = try await request(url)
        guard body.meta.page == page else {
            throw VLRAPIError.invalidResponse
        }
        return body.data
    }

    /// The event's overview. Without a `stage` slug VLR.GG picks the active stage, which
    /// comes back as `activeStage`; groups, tables and brackets belong to that stage.
    func fetchEventDetail(id: Int, stage: String? = nil) async throws -> V3EventDetail {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["events", String(id)],
            queryItems: stage.map { [URLQueryItem(name: "stage", value: $0)] } ?? []
        )
        let body: V3Response<V3EventDetail, V3EntityMeta> = try await request(url)
        guard body.data.id == id, body.meta.id == id else {
            throw VLRAPIError.invalidResponse
        }
        return body.data
    }

    func fetchEventMatches(id: Int) async throws -> [V3Match] {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["events", String(id), "matches"]
        )
        let body: V3Response<[V3Match], V3MatchListMeta> = try await request(url)
        if let eventID = body.meta.eventID, eventID != id {
            throw VLRAPIError.invalidResponse
        }
        return body.data
    }

    func fetchEventStats(id: Int) async throws -> [V3EventPlayerStats] {
        let url = try configuration.url(
            versionPath: configuration.v3Path,
            path: ["events", String(id), "stats"]
        )
        let body: V3Response<V3EventStatsData, V3EntityMeta> = try await request(url)
        guard body.meta.id == id else {
            throw VLRAPIError.invalidResponse
        }
        return body.data.players
    }
}
