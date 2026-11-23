import XCTest
@testable import Flank

final class SearchTests: XCTestCase {
    func testDecodesSearchPayloadAndGroupsInDisplayOrder() throws {
        let payload = try VLRAPI.decoder.decode(V2SearchPayload.self, from: Data(searchPayload.utf8))
        let results = payload.segments.results

        XCTAssertEqual(payload.segments.query, "sen")
        XCTAssertEqual(results.players.count, 1)
        XCTAssertEqual(results.teams.count, 4)
        XCTAssertEqual(results.events.count, 1)

        let sections = SearchGrouping.sections(results: results, matches: [])
        XCTAssertEqual(sections.map(\.category), [.teams, .players, .events])

        guard case .entities(let teams) = sections[0].rows else {
            return XCTFail("Expected team entities")
        }
        // The id-less hit is dropped and the duplicate keeps its first position.
        XCTAssertEqual(teams.map(\.vlrID), [2, 20543])
        XCTAssertEqual(teams[0].name, "Sentinels")
        XCTAssertEqual(teams[0].image, "https://owcdn.net/img/62875027c8e06.png")
        XCTAssertFalse(teams[0].isInactive)

        // The scraper appends the "(inactive )" tag to the name and uses VLR.GG's placeholder logo.
        XCTAssertEqual(teams[1].name, "Team TenZ")
        XCTAssertTrue(teams[1].isInactive)
        XCTAssertNil(teams[1].image)

        guard case .entities(let players) = sections[1].rows else {
            return XCTFail("Expected player entities")
        }
        XCTAssertEqual(players.first?.vlrID, 9)
        XCTAssertNil(players.first?.image, "Silhouette placeholder should be dropped")

        guard case .entities(let events) = sections[2].rows else {
            return XCTFail("Expected event entities")
        }
        XCTAssertEqual(events.first?.subtitle, "Dec 4, 2025 to Dec 7, 2025 ⋅ $10,000")
        // Older servers send no type; their event hits open the event page.
        XCTAssertEqual(events.first?.eventKind, .event)
        XCTAssertTrue(events.first?.opensEventDetail == true)
    }

    func testSeriesHitsOpenOnVLRAndKeepTheirOwnIdentity() throws {
        let json = """
        {"status": 200, "segments": {"query": "champions", "results": {"events": [
            {"id": "2283", "name": "Valorant Champions 2025", "img": "", "description": "", "tag": "",
             "type": "event", "url": "https://www.vlr.gg/event/2283/valorant-champions-2025"},
            {"id": "2283", "name": "Champions Tour", "img": "", "description": "", "tag": "",
             "type": "series", "url": "https://www.vlr.gg/series/2283"},
            {"id": "77", "name": "Series without a link", "img": "", "description": "", "tag": "", "type": "series"},
            {"id": "78", "name": "Future kind", "img": "", "description": "", "tag": "",
             "type": "circuit", "url": "https://www.vlr.gg/circuit/78"}
        ]}}}
        """
        let results = try VLRAPI.decoder.decode(V2SearchPayload.self, from: Data(json.utf8)).segments.results
        guard case .entities(let events) = SearchGrouping.sections(results: results, matches: []).first?.rows else {
            return XCTFail("Expected event entities")
        }

        // The event and the series share an ID but are different hits; the series
        // without a URL can't be opened and is dropped.
        XCTAssertEqual(events.map(\.name), ["Valorant Champions 2025", "Champions Tour", "Future kind"])
        XCTAssertEqual(Set(events.map(\.id)).count, 3)

        XCTAssertTrue(events[0].opensEventDetail)
        XCTAssertEqual(events[1].eventKind, .series)
        XCTAssertFalse(events[1].opensEventDetail)
        XCTAssertEqual(events[1].url?.absoluteString, "https://www.vlr.gg/series/2283")
        XCTAssertEqual(events[2].eventKind, .other)
        XCTAssertFalse(events[2].opensEventDetail)
    }

    func testRemoteQueryIsTrimmedAndLowercased() async throws {
        XCTAssertEqual(SearchQuery.remote("  Sentinels \n"), "sentinels")

        SearchStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v2/search")
            XCTAssertEqual(request.url?.query, "q=paper%20rex")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            let body = #"{"status": "success", "data": {"status": 200, "segments": {"query": "paper rex", "results": {}}}}"#
            return (response, Data(body.utf8))
        }
        defer { SearchStubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchStubURLProtocol.self]
        let client = VLRAPIClient(
            configuration: .init(host: "https://example.test"),
            session: URLSession(configuration: configuration)
        )
        let results = try await client.search(" Paper Rex ")
        XCTAssertTrue(results.isEmpty)
    }

    func testMissingResultListsDecodeAsEmpty() throws {
        let json = #"{"status": 200, "segments": {"query": "zz", "results": {"teams": null}}}"#
        let results = try VLRAPI.decoder.decode(V2SearchPayload.self, from: Data(json.utf8)).segments.results

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(SearchGrouping.sections(results: results, matches: []).isEmpty)
    }

    func testLocalMatchesFilterByTeamOrEventAndDeduplicate() throws {
        let live = try decodeMatches(#"[\#(match(id: 1, teams: ["Sentinels", "G2 Esports"], event: "Champions Tour 2026: Americas"))]"#)
        let upcoming = try decodeMatches(#"[\#(match(id: 1, teams: ["Sentinels", "G2 Esports"], event: "Champions Tour 2026: Americas")), \#(match(id: 2, teams: ["Fnatic", "Team Heretics"], event: "Champions Tour 2026: EMEA"))]"#)

        XCTAssertEqual(SearchGrouping.matches(in: [live, upcoming], matching: "sentinels").map(\.id), [1])
        XCTAssertEqual(SearchGrouping.matches(in: [live, upcoming], matching: " emea ").map(\.id), [2])
        XCTAssertEqual(SearchGrouping.matches(in: [live, upcoming], matching: "champions").map(\.id), [1, 2])
        XCTAssertTrue(SearchGrouping.matches(in: [live, upcoming], matching: "  ").isEmpty)

        let sections = SearchGrouping.sections(results: nil, matches: live)
        XCTAssertEqual(sections.map(\.category), [.matches])
    }

    func testRecentSearchesDeduplicateAndKeepTheNewestEight() throws {
        let suiteName = "SearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentSearchesStore(defaults: defaults)

        for query in ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"] {
            store.record(query)
        }
        XCTAssertEqual(store.load().count, RecentSearchesStore.limit)
        XCTAssertEqual(store.load().first, "nine")
        XCTAssertFalse(store.load().contains("one"))

        store.record("  FOUR ")
        XCTAssertEqual(store.load().first, "FOUR")
        XCTAssertEqual(store.load().filter { $0.caseInsensitiveCompare("four") == .orderedSame }.count, 1)

        store.record("x")
        XCTAssertNotEqual(store.load().first, "x", "Queries under the minimum length aren't saved")

        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Fixtures

    private func decodeMatches(_ json: String) throws -> [V3Match] {
        try VLRAPI.decoder.decode([V3Match].self, from: Data(json.utf8))
    }

    private func match(id: Int, teams: [String], event: String) -> String {
        let teamJSON = teams.map { #"{"name": "\#($0)"}"# }.joined(separator: ", ")
        return """
        {"id": \(id), "source": "upcoming", "url": "/\(id)", "status": "scheduled", \
        "event": {"name": "\(event)"}, "teams": [\(teamJSON)]}
        """
    }

    private let searchPayload = """
    {
        "status": 200,
        "segments": {
            "query": "sen",
            "results": {
                "players": [
                    {"id": "9", "name": "TenZ", "img": "https://www.vlr.gg/img/base/ph/sil.png", "description": "", "tag": ""}
                ],
                "teams": [
                    {"id": "2", "name": "Sentinels", "img": "https://owcdn.net/img/62875027c8e06.png", "description": "", "tag": ""},
                    {"id": "", "name": "Broken", "img": "", "description": "", "tag": ""},
                    {"id": "20543", "name": "Team TenZ (inactive )", "img": "https://www.vlr.gg/img/vlr/tmp/vlr.png", "description": "", "tag": "(inactive )"},
                    {"id": "2", "name": "Sentinels", "img": "", "description": "", "tag": ""}
                ],
                "events": [
                    {"id": "2748", "name": "Sentinels Invitational 2025", "img": "https://owcdn.net/img/60cedc3d59613.png", "description": "Dec 4, 2025 to Dec 7, 2025 \\u22c5 $10,000", "tag": ""}
                ]
            }
        }
    }
    """
}

private final class SearchStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
