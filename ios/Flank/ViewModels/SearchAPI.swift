//
//  SearchAPI.swift
//  Flank
//

import Foundation

// MARK: - Payload

/// `data` of `GET /v2/search?q=`: `{ "status": 200, "segments": { "query", "results" } }`.
struct V2SearchPayload: Decodable, Sendable {
    let segments: Segments

    struct Segments: Decodable, Sendable {
        let query: String?
        let results: V2SearchResults
    }
}

struct V2SearchResults: Decodable, Hashable, Sendable {
    @DefaultEmpty var players: [V2SearchItem]
    @DefaultEmpty var teams: [V2SearchItem]
    @DefaultEmpty var events: [V2SearchItem]

    init(players: [V2SearchItem] = [], teams: [V2SearchItem] = [], events: [V2SearchItem] = []) {
        self.players = players
        self.teams = teams
        self.events = events
    }

    var isEmpty: Bool {
        players.isEmpty && teams.isEmpty && events.isEmpty
    }
}

/// One VLR.GG search hit. The scraper sends every field as a string; `id` is the
/// numeric VLR.GG id and `tag` is inline title text such as "(inactive )".
struct V2SearchItem: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let img: String?
    let description: String?
    let tag: String?
    /// Event hits only: `"event"` or `"series"`. Older servers leave it out.
    let type: String?
    /// Event hits only: the hit's absolute VLR.GG URL. Older servers leave it out.
    let url: String?

    init(
        id: String,
        name: String,
        img: String? = nil,
        description: String? = nil,
        tag: String? = nil,
        type: String? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.name = name
        self.img = img
        self.description = description
        self.tag = tag
        self.type = type
        self.url = url
    }
}

// MARK: - App-facing results

enum SearchCategory: String, CaseIterable, Hashable, Sendable {
    case teams
    case players
    case events
    case matches

    var title: String {
        switch self {
        case .teams: "Teams"
        case .players: "Players"
        case .events: "Events"
        case .matches: "Matches"
        }
    }
}

/// What an Events hit points at. Series (e.g. "Champions Tour") have no event page in
/// the app, so they open on VLR.GG.
enum SearchEventKind: Hashable, Sendable {
    case event
    case series
    /// A type this version doesn't know; opened on VLR.GG when it has a URL.
    case other

    /// Older servers send no type; all their event hits were events.
    init(type: String?) {
        switch type?.nilIfBlank?.lowercased() {
        case nil, "event": self = .event
        case "series": self = .series
        default: self = .other
        }
    }
}

/// A team, player or event hit, cleaned up for display.
struct SearchEntity: Identifiable, Hashable, Sendable {
    let category: SearchCategory
    let vlrID: Int
    let name: String
    let subtitle: String?
    let image: String?
    let isInactive: Bool
    /// For `.events` hits; `.event` for the other categories.
    let eventKind: SearchEventKind
    /// The hit's VLR.GG page, when the API sent one.
    let url: URL?

    var id: String { "\(category.rawValue)-\(eventKind)-\(vlrID)" }

    /// Whether the hit opens the in-app event page rather than VLR.GG.
    var opensEventDetail: Bool { category == .events && eventKind == .event }

    /// VLR.GG's generic team logo and player silhouette; rows show their own placeholder instead.
    static let placeholderImagePaths = ["/img/vlr/tmp/vlr.png", "/img/base/ph/sil.png"]

    /// Returns nil when the hit has no usable numeric id, since it can't be opened.
    init?(_ item: V2SearchItem, category: SearchCategory) {
        guard let vlrID = Int(item.id.trimmingCharacters(in: .whitespaces)), vlrID > 0 else {
            return nil
        }
        let tag = item.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The scraper reads the title's full text, so the tag span is appended to the name.
        if !tag.isEmpty, name.hasSuffix(tag) {
            name = String(name.dropLast(tag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty else { return nil }

        let description = item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let image = item.img?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        self.category = category
        self.vlrID = vlrID
        self.name = name
        subtitle = description.isEmpty ? nil : description
        self.image = image.isEmpty || Self.placeholderImagePaths.contains(where: image.hasSuffix) ? nil : image
        isInactive = tag.localizedCaseInsensitiveContains("inactive")
        eventKind = category == .events ? SearchEventKind(type: item.type) : .event
        url = VLRAPI.pageURL(from: item.url)

        // A series or unknown hit can only open on VLR.GG, so it needs a URL.
        if category == .events, eventKind != .event, url == nil {
            return nil
        }
    }

    init(
        category: SearchCategory,
        vlrID: Int,
        name: String,
        subtitle: String? = nil,
        image: String? = nil,
        isInactive: Bool = false,
        eventKind: SearchEventKind = .event,
        url: URL? = nil
    ) {
        self.category = category
        self.vlrID = vlrID
        self.name = name
        self.subtitle = subtitle
        self.image = image
        self.isInactive = isInactive
        self.eventKind = eventKind
        self.url = url
    }
}

struct SearchSection: Identifiable, Hashable, Sendable {
    enum Rows: Hashable, Sendable {
        case entities([SearchEntity])
        case matches([V3Match])
    }

    let category: SearchCategory
    let rows: Rows

    var id: SearchCategory { category }

    var count: Int {
        switch rows {
        case .entities(let entities): entities.count
        case .matches(let matches): matches.count
        }
    }
}

enum SearchGrouping {
    /// Sections in display order (Teams, Players, Events, Matches), leaving out empty ones.
    /// Hits without a usable id are dropped, and duplicates keep their first position.
    static func sections(results: V2SearchResults?, matches: [V3Match]) -> [SearchSection] {
        var sections: [SearchSection] = []
        for category in SearchCategory.allCases {
            if category == .matches {
                if !matches.isEmpty {
                    sections.append(SearchSection(category: .matches, rows: .matches(matches)))
                }
                continue
            }
            let items: [V2SearchItem]
            switch category {
            case .teams: items = results?.teams ?? []
            case .players: items = results?.players ?? []
            case .events: items = results?.events ?? []
            case .matches: items = []
            }
            // An event and a series can share a numeric ID, so the kind is part of the key.
            var seen = Set<String>()
            let entities = items
                .compactMap { SearchEntity($0, category: category) }
                .filter { seen.insert($0.id).inserted }
            if !entities.isEmpty {
                sections.append(SearchSection(category: category, rows: .entities(entities)))
            }
        }
        return sections
    }

    /// Matches already loaded by the Matches tab whose teams or event mention the query.
    /// `/v2/search` doesn't return matches, so this is the only source for that group.
    static func matches(in lists: [[V3Match]], matching query: String, limit: Int = 25) -> [V3Match] {
        let query = SearchQuery.normalized(query)
        guard !query.isEmpty else { return [] }
        var seen = Set<Int>()
        var found: [V3Match] = []
        for match in lists.joined() where seen.insert(match.id).inserted {
            let isMatch = match.teams.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || match.event.name.localizedCaseInsensitiveContains(query)
                || match.event.series?.localizedCaseInsensitiveContains(query) == true
                || match.event.stage?.localizedCaseInsensitiveContains(query) == true
            if isMatch {
                found.append(match)
                if found.count == limit { break }
            }
        }
        return found
    }
}

// MARK: - Query rules

enum SearchQuery {
    static let minimumLength = 2
    static let debounce: Duration = .milliseconds(400)

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `q` sent to the API: trimmed and lowercased, since VLR.GG search ignores
    /// case, so "Sentinels" and "sentinels" share the API's and CDN's cached answer.
    static func remote(_ query: String) -> String {
        normalized(query).lowercased()
    }
}

// MARK: - Recent searches

/// The last few submitted or opened searches, newest first.
struct RecentSearchesStore {
    static let defaultsKey = "recentSearches"
    static let limit = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        Array((defaults.stringArray(forKey: Self.defaultsKey) ?? []).prefix(Self.limit))
    }

    /// Moves `query` to the front, dropping case-insensitive duplicates and the oldest past the limit.
    @discardableResult
    func record(_ query: String) -> [String] {
        let query = SearchQuery.normalized(query)
        guard query.count >= SearchQuery.minimumLength else { return load() }
        var searches = load().filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        searches.insert(query, at: 0)
        searches = Array(searches.prefix(Self.limit))
        defaults.set(searches, forKey: Self.defaultsKey)
        return searches
    }

    @discardableResult
    func remove(_ query: String) -> [String] {
        let searches = load().filter { $0 != query }
        defaults.set(searches, forKey: Self.defaultsKey)
        return searches
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

// MARK: - Client

extension VLRAPIClient {
    func search(_ query: String) async throws -> V2SearchResults {
        let payload = try await fetchV2(
            V2SearchPayload.self,
            path: "search",
            queryItems: [URLQueryItem(name: "q", value: SearchQuery.remote(query))]
        )
        return payload.segments.results
    }
}

// MARK: - View model

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var sections: [SearchSection] = []
    @Published private(set) var state: ListLoadState = .idle
    @Published private(set) var recentSearches: [String]
    /// The query the current `sections` and `state` belong to.
    @Published private(set) var resultsQuery = ""

    private let client: VLRAPIClient
    private let cache: ListCache
    private let recents: RecentSearchesStore
    private var localMatchLists: [[V3Match]] = []
    /// Answers already fetched this session, so editing back to an earlier query
    /// doesn't hit VLR.GG again.
    private var remoteCache: [String: V2SearchResults] = [:]
    private var remoteCacheOrder: [String] = []
    private let remoteCacheLimit = 30

    init(
        client: VLRAPIClient = .init(),
        cache: ListCache = .shared,
        recents: RecentSearchesStore = .init()
    ) {
        self.client = client
        self.cache = cache
        self.recents = recents
        recentSearches = recents.load()
    }

    /// Re-reads the match lists the Matches tab saved, newest data first (live, upcoming, results).
    func reloadLocalMatches() {
        // Same keys V3MatchListStore uses for its offline copies.
        localMatchLists = [V3MatchQuery.liveScore, .upcoming, .results].map { query in
            cache.load([V3Match].self, forKey: "v3.matches.\(query.rawValue)") ?? []
        }
    }

    /// Debounces, then searches. Call from `.task(id: query)` so a new query cancels the
    /// previous wait or request.
    func search(_ rawQuery: String, debounce: Bool = true) async {
        let query = SearchQuery.normalized(rawQuery)
        guard query.count >= SearchQuery.minimumLength else {
            sections = []
            state = .idle
            resultsQuery = query
            return
        }

        let key = SearchQuery.remote(query)
        let localMatches = SearchGrouping.matches(in: localMatchLists, matching: query)

        if let cached = remoteCache[key] {
            show(results: cached, matches: localMatches, for: query)
            return
        }

        if debounce {
            do {
                try await Task.sleep(for: SearchQuery.debounce)
            } catch {
                return
            }
        }

        resultsQuery = query
        sections = SearchGrouping.sections(results: nil, matches: localMatches)
        state = .loading

        do {
            let results = try await client.search(query)
            try Task.checkCancellation()
            storeInCache(results, forKey: key)
            show(results: results, matches: localMatches, for: query)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let retryable = (error as? VLRAPIError)?.isRetryable ?? true
            state = .failed(message: message, retryable: retryable)
        }
    }

    func recordRecentSearch(_ query: String) {
        recentSearches = recents.record(query)
    }

    func removeRecentSearch(_ query: String) {
        recentSearches = recents.remove(query)
    }

    func clearRecentSearches() {
        recents.clear()
        recentSearches = []
    }

    private func show(results: V2SearchResults, matches: [V3Match], for query: String) {
        resultsQuery = query
        sections = SearchGrouping.sections(results: results, matches: matches)
        state = sections.isEmpty ? .empty : .loaded
    }

    private func storeInCache(_ results: V2SearchResults, forKey key: String) {
        if remoteCache.updateValue(results, forKey: key) == nil {
            remoteCacheOrder.append(key)
        }
        while remoteCacheOrder.count > remoteCacheLimit {
            remoteCache.removeValue(forKey: remoteCacheOrder.removeFirst())
        }
    }
}
