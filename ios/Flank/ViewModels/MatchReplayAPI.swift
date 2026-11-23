//
//  MatchReplayAPI.swift
//  Flank
//
//  Round-by-round replay of one map, from `GET /v2/match/{match_id}/logs?game_id=...`
//  (vlr.gg's "logs" tab).
//

import Foundation

// MARK: - Models

/// Which of the two teams something belongs to. The payload sends `"team1"`, `"team2"`,
/// or `""` when vlr.gg didn't say.
enum ReplayTeamSlot: String, Codable, Sendable, UnknownCaseDecodable {
    case team1
    case team2
    case unknown

    static let unknownCase = ReplayTeamSlot.unknown

    /// Team numbers as the payload uses them on players and events (`1` or `2`).
    init(number: Int?) {
        switch number {
        case 1: self = .team1
        case 2: self = .team2
        default: self = .unknown
        }
    }
}

enum ReplayEventKind: String, Codable, Sendable, UnknownCaseDecodable {
    case kill
    case plant
    case defuse
    case unknown

    static let unknownCase = ReplayEventKind.unknown
}

enum ReplayArmor: String, Codable, Sendable, UnknownCaseDecodable {
    case none
    case light
    case heavy
    case regen
    case unknown

    static let unknownCase = ReplayArmor.unknown
}

struct ReplayTeam: Codable, Hashable, Sendable {
    let name: String?
    let tag: String?
}

struct ReplayTeams: Codable, Hashable, Sendable, EmptyDefaultable {
    let team1: ReplayTeam?
    let team2: ReplayTeam?

    static let emptyValue = ReplayTeams(team1: nil, team2: nil)

    subscript(slot: ReplayTeamSlot) -> ReplayTeam? {
        switch slot {
        case .team1: team1
        case .team2: team2
        case .unknown: nil
        }
    }
}

struct ReplayScore: Codable, Hashable, Sendable, EmptyDefaultable {
    let team1: Int?
    let team2: Int?

    static let emptyValue = ReplayScore(team1: nil, team2: nil)
}

/// A point on vlr.gg's replay canvas (a 1024 × 1024 SVG viewBox).
struct ReplayPoint: Codable, Hashable, Sendable {
    let x: Double?
    let y: Double?
}

/// Where one living player stood, and which way they faced, when an event happened.
struct ReplayPosition: Codable, Hashable, Sendable {
    let player: String
    let team: Int?
    let x: Double?
    let y: Double?
    /// The direction the player faced, in degrees. Not health: older servers sent this
    /// value as `hp`.
    let facing: Double?

    enum CodingKeys: String, CodingKey {
        case player, team, x, y, facing
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case hp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        player = container.lenientString(forKey: .player) ?? ""
        team = container.lenientInt(forKey: .team)
        x = container.lenientDouble(forKey: .x)
        y = container.lenientDouble(forKey: .y)
        facing = container.lenientDouble(forKey: .facing)
            ?? decoder.legacyFacing(forKey: LegacyCodingKeys.hp)
    }

    var slot: ReplayTeamSlot { ReplayTeamSlot(number: team) }
}

/// One player's buy for the round.
struct ReplayBuy: Codable, Hashable, Sendable {
    let player: String
    let team: Int?
    let agent: String?
    /// Credits left after the buy phase.
    let credits: Int?
    /// Credits spent in the buy phase.
    let spent: Int?
    let weapon: String?
    let armor: ReplayArmor

    enum CodingKeys: String, CodingKey {
        case player, team, agent, credits, spent, weapon, armor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        player = container.lenientString(forKey: .player) ?? ""
        team = container.lenientInt(forKey: .team)
        agent = container.lenientString(forKey: .agent)
        credits = container.lenientInt(forKey: .credits)
        spent = container.lenientInt(forKey: .spent)
        weapon = container.lenientString(forKey: .weapon)
        armor = (try? container.decodeIfPresent(ReplayArmor.self, forKey: .armor)) ?? .unknown
    }

    var slot: ReplayTeamSlot { ReplayTeamSlot(number: team) }
}

/// A kill, spike plant or spike defuse.
struct ReplayEvent: Codable, Hashable, Sendable {
    /// Round clock when it happened, e.g. `"1:04"`.
    let time: String?
    let kind: ReplayEventKind
    /// The killer, planter or defuser.
    let player: String?
    let team: Int?
    let victim: String?
    let victimTeam: Int?
    /// Kill: where the victim died. Plant/defuse: where the spike is.
    let position: ReplayPoint?
    /// Kill: where the killer stood.
    let origin: ReplayPoint?
    /// Living players at the moment of the event (the victim of a kill is not included).
    @DefaultEmpty var positions: [ReplayPosition]
    /// Damage source of a kill (weapon or ability), e.g. `"Vandal"` or `"Spike"`.
    let source: String?
    /// Spike site of a plant or defuse.
    let site: String?
    /// Not sent by the API today; shown when present.
    let headshot: Bool?

    enum CodingKeys: String, CodingKey {
        case time = "t"
        case kind = "type"
        case player, team, victim, positions, source, site, headshot
        case victimTeam = "victim_team"
        case position = "pos"
        case origin = "from"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = container.lenientString(forKey: .time)
        kind = (try? container.decodeIfPresent(ReplayEventKind.self, forKey: .kind)) ?? .unknown
        player = container.lenientString(forKey: .player)
        team = container.lenientInt(forKey: .team)
        victim = container.lenientString(forKey: .victim)
        victimTeam = container.lenientInt(forKey: .victimTeam)
        position = try? container.decodeIfPresent(ReplayPoint.self, forKey: .position)
        origin = try? container.decodeIfPresent(ReplayPoint.self, forKey: .origin)
        _positions = DefaultEmpty(
            wrappedValue: (try? container.decodeIfPresent([ReplayPosition].self, forKey: .positions)) ?? []
        )
        source = container.lenientString(forKey: .source)
        site = container.lenientString(forKey: .site)
        headshot = try? container.decodeIfPresent(Bool.self, forKey: .headshot)
    }

    var slot: ReplayTeamSlot { ReplayTeamSlot(number: team) }
    var victimSlot: ReplayTeamSlot { ReplayTeamSlot(number: victimTeam) }

    /// vlr.gg records a spike detonation death with the victim as its own killer.
    var isSpikeKill: Bool {
        kind == .kill && (source?.caseInsensitiveCompare("Spike") == .orderedSame
            || (player != nil && player == victim))
    }
}

struct ReplayRound: Codable, Hashable, Identifiable, Sendable {
    var id: Int { number }
    let number: Int
    /// Score after this round.
    @DefaultEmpty var score: ReplayScore
    let winner: ReplayTeamSlot
    let attackingSide: ReplayTeamSlot
    /// E.g. `"Elimination"`, `"Spike defused"`, `"Time expired"`.
    let endReason: String?
    @DefaultEmpty var economy: [ReplayBuy]
    @DefaultEmpty var events: [ReplayEvent]

    enum CodingKeys: String, CodingKey {
        case number = "round"
        case score, winner, economy, events
        case attackingSide = "attacking_side"
        case endReason = "end_reason"
    }

    init(
        number: Int,
        score: ReplayScore = .emptyValue,
        winner: ReplayTeamSlot = .unknown,
        attackingSide: ReplayTeamSlot = .unknown,
        endReason: String? = nil,
        economy: [ReplayBuy] = [],
        events: [ReplayEvent] = []
    ) {
        self.number = number
        self.winner = winner
        self.attackingSide = attackingSide
        self.endReason = endReason
        _score = DefaultEmpty(wrappedValue: score)
        _economy = DefaultEmpty(wrappedValue: economy)
        _events = DefaultEmpty(wrappedValue: events)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let number = container.lenientInt(forKey: .number) else {
            throw DecodingError.dataCorruptedError(
                forKey: .number,
                in: container,
                debugDescription: "A replay round needs a round number."
            )
        }
        self.number = number
        _score = DefaultEmpty(
            wrappedValue: (try? container.decodeIfPresent(ReplayScore.self, forKey: .score)) ?? .emptyValue
        )
        winner = (try? container.decodeIfPresent(ReplayTeamSlot.self, forKey: .winner)) ?? .unknown
        attackingSide = (try? container.decodeIfPresent(ReplayTeamSlot.self, forKey: .attackingSide)) ?? .unknown
        endReason = container.lenientString(forKey: .endReason)
        _economy = DefaultEmpty(
            wrappedValue: (try? container.decode(LossyArray<ReplayBuy>.self, forKey: .economy).elements) ?? []
        )
        _events = DefaultEmpty(
            wrappedValue: (try? container.decode(LossyArray<ReplayEvent>.self, forKey: .events).elements) ?? []
        )
    }

    /// Where the round sits in the match: regulation halves, then overtime.
    enum Phase: Hashable, Sendable {
        case firstHalf
        case secondHalf
        case overtime
    }

    var phase: Phase {
        switch number {
        case ...12: .firstHalf
        case 13...24: .secondHalf
        default: .overtime
        }
    }

    func buys(for slot: ReplayTeamSlot) -> [ReplayBuy] {
        economy.filter { $0.slot == slot }
    }

    /// The agent each player is on this round, from the buy table.
    var agentsByPlayer: [String: String] {
        economy.reduce(into: [:]) { result, buy in
            if let agent = buy.agent, !agent.isEmpty, !buy.player.isEmpty {
                result[buy.player] = agent
            }
        }
    }
}

struct MatchReplay: Codable, Hashable, Sendable {
    let matchID: String?
    let gameID: String?
    /// Map slug, e.g. `"sunset"`.
    let map: String?
    @DefaultEmpty var teams: ReplayTeams
    @DefaultEmpty var rounds: [ReplayRound]

    enum CodingKeys: String, CodingKey {
        case map, teams, rounds
        case matchID = "match_id"
        case gameID = "game_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchID = container.lenientString(forKey: .matchID)
        gameID = container.lenientString(forKey: .gameID)
        map = container.lenientString(forKey: .map)
        _teams = DefaultEmpty(
            wrappedValue: (try? container.decodeIfPresent(ReplayTeams.self, forKey: .teams)) ?? .emptyValue
        )
        let rounds = (try? container.decode(LossyArray<ReplayRound>.self, forKey: .rounds).elements) ?? []
        _rounds = DefaultEmpty(wrappedValue: rounds.sorted { $0.number < $1.number })
    }

    /// The side length of the square the positions are drawn in, or `nil` when the
    /// payload has no positions or they fall outside every canvas the app knows.
    ///
    /// vlr.gg draws its replay on a 1024 × 1024 SVG; already-normalised (0...1)
    /// coordinates are accepted too.
    var canvasSize: Double? {
        var maxValue = 0.0
        var hasPoint = false
        for round in rounds {
            for event in round.events {
                for value in event.coordinateValues {
                    guard value.isFinite, value >= 0 else { return nil }
                    maxValue = max(maxValue, value)
                    hasPoint = true
                }
            }
        }
        guard hasPoint else { return nil }
        if maxValue <= 1 { return 1 }
        if maxValue <= 1024 { return 1024 }
        return nil
    }
}

private extension ReplayEvent {
    var coordinateValues: [Double] {
        var values: [Double] = []
        for point in [position, origin].compactMap({ $0 }) {
            values.append(contentsOf: [point.x, point.y].compactMap { $0 })
        }
        for player in positions {
            values.append(contentsOf: [player.x, player.y].compactMap { $0 })
        }
        return values
    }
}

/// `data` of the logs endpoint: `{"status": 200, "segments": [replay]}`.
struct MatchReplayEnvelope: Decodable, Sendable {
    @DefaultEmpty var segments: [MatchReplay]
}

// MARK: - Lenient decoding helpers

/// Decodes an array, dropping elements that fail instead of failing the whole array.
private struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        self.elements = elements
    }

    /// Accepts any JSON value without reading it, so the container moves past a bad element.
    private struct DiscardedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

private extension Decoder {
    func legacyFacing<Key: CodingKey>(forKey key: Key) -> Double? {
        (try? container(keyedBy: Key.self))?.lenientDouble(forKey: key)
    }
}

private extension KeyedDecodingContainer {
    func lenientString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

// MARK: - Fetching

extension VLRAPIClient {
    /// The replay of one map, or `nil` when the API has none for it.
    func fetchMatchReplay(matchID: Int, gameID: Int) async throws -> MatchReplay? {
        let envelope = try await fetchV2(
            MatchReplayEnvelope.self,
            path: "match/\(matchID)/logs",
            queryItems: [URLQueryItem(name: "game_id", value: String(gameID))]
        )
        return envelope.segments.first
    }
}

/// A replay saved for offline use, with what's needed to decide whether to refetch it.
struct SavedMatchReplay: Codable, Sendable {
    let replay: MatchReplay
    let savedAt: Date
    /// Whether the map had finished when this copy was saved; an in-progress copy
    /// misses later rounds.
    let isComplete: Bool

    /// A finished map's replay doesn't change, so a saved copy is used as is for an
    /// hour; maps still being played always refresh.
    static let maximumAge: TimeInterval = 60 * 60

    func needsRefresh(mapInProgress: Bool, now: Date) -> Bool {
        mapInProgress || !isComplete || now.timeIntervalSince(savedAt) >= Self.maximumAge
    }
}

@MainActor
final class MatchReplayViewModel: ObservableObject {
    enum State {
        case loading
        /// `refreshFailure` is set when a saved copy is shown because the refresh failed.
        case loaded(MatchReplay, refreshFailure: RefreshFailure?)
        case empty
        case failed(message: String, retryable: Bool)
    }

    typealias Loader = @Sendable (_ matchID: Int, _ gameID: Int) async throws -> MatchReplay?

    @Published private(set) var state: State = .loading

    let matchID: Int
    let gameID: Int
    let isMapInProgress: Bool
    private let cache: ListCache?
    private let loader: Loader
    private let now: @Sendable () -> Date
    private var savedCopy: SavedMatchReplay?

    init(
        matchID: Int,
        gameID: Int,
        isMapInProgress: Bool = false,
        cache: ListCache? = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        loader: Loader? = nil
    ) {
        self.matchID = matchID
        self.gameID = gameID
        self.isMapInProgress = isMapInProgress
        self.cache = cache
        self.now = now
        let client = VLRAPIClient()
        self.loader = loader ?? { matchID, gameID in
            try await client.fetchMatchReplay(matchID: matchID, gameID: gameID)
        }
    }

    var cacheKey: String { "replay.\(matchID).\(gameID)" }

    /// Shows the saved copy straight away when there is one. It is refreshed only when
    /// the map is still in progress, the copy is old or incomplete, or `force` is set
    /// (pull to refresh, retry).
    func load(force: Bool = false) async {
        let cached: MatchReplay?
        if case .loaded(let current, _) = state {
            cached = current
        } else {
            savedCopy = await loadCached()
            cached = savedCopy?.replay
            if let cached {
                state = .loaded(cached, refreshFailure: nil)
            } else {
                state = .loading
            }
        }

        if !force, let savedCopy, !savedCopy.needsRefresh(mapInProgress: isMapInProgress, now: now()) {
            return
        }

        do {
            let replay = try await loader(matchID, gameID)
            try Task.checkCancellation()
            guard let replay, !replay.rounds.isEmpty else {
                if let cached {
                    state = .loaded(cached, refreshFailure: RefreshFailure(
                        message: String(localized: "VLR.GG didn’t return this replay just now."),
                        isOffline: false
                    ))
                } else {
                    state = .empty
                }
                return
            }
            state = .loaded(replay, refreshFailure: nil)
            let saved = SavedMatchReplay(replay: replay, savedAt: now(), isComplete: !isMapInProgress)
            savedCopy = saved
            await save(saved)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if let cached {
                state = .loaded(cached, refreshFailure: RefreshFailure(error))
                return
            }
            state = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                retryable: (error as? VLRAPIError)?.isRetryable ?? true
            )
        }
    }

    private func loadCached() async -> SavedMatchReplay? {
        guard let cache else { return nil }
        let key = cacheKey
        return await Task.detached(priority: .userInitiated) {
            cache.load(SavedMatchReplay.self, forKey: key)
        }.value
    }

    private func save(_ saved: SavedMatchReplay) async {
        guard let cache else { return }
        let key = cacheKey
        await Task.detached(priority: .utility) {
            cache.save(saved, forKey: key)
        }.value
    }
}
