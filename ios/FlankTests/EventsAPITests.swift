import XCTest
@testable import Flank

final class EventsAPITests: XCTestCase {
    @MainActor
    func testSwitchingBackToASegmentKeepsItsLoadedPages() async throws {
        let requests = EventsRequestLog()
        EventsStubURLProtocol.handler = { request in
            requests.append(request.url?.query ?? "")
            let page = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            let body = """
            {"api_version": "3", "data": [{"id": \(page)00, "name": "Event \(page)", "status": "completed",
              "url": "/event/\(page)00"}], "meta": {"page": \(page)}}
            """
            return (response, Data(body.utf8))
        }
        defer { EventsStubURLProtocol.handler = nil }

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EventsStubURLProtocol.self]
        let store = EventListStore(
            query: .completed,
            client: VLRAPIClient(
                configuration: .init(host: "https://example.test"),
                session: URLSession(configuration: configuration)
            ),
            cache: ListCache(directory: directory)
        )

        await store.fetchIfNeeded()
        await store.loadMore()
        XCTAssertEqual(store.events.map(\.id), [100, 200])

        // Coming back to the segment doesn't throw page 2 away or ask again.
        await store.fetchIfNeeded()
        XCTAssertEqual(store.events.map(\.id), [100, 200])
        XCTAssertEqual(requests.values.count, 2)

        // Pull to refresh still reloads.
        await store.fetch()
        XCTAssertEqual(requests.values.count, 3)
        XCTAssertEqual(store.events.map(\.id), [100])
    }

    func testEventListDecodesSparseLiveEvent() throws {
        let body = try decode(V3Response<[V3EventSummary], V3PageMeta>.self, eventListPayload)

        XCTAssertEqual(body.meta.page, 1)
        XCTAssertEqual(body.data.count, 2)
        XCTAssertEqual(body.data[0].status, .unknown)
        XCTAssertNil(body.data[0].dateText)
        XCTAssertNil(body.data[0].prize.displayText)
        XCTAssertEqual(body.data[1].status, .ongoing)
        XCTAssertNil(body.data[1].prize.displayText, "TBD prize pools are hidden")
        XCTAssertEqual(body.data[1].image.preferred(for: .dark), "https://owcdn.net/img/dark.png")
    }

    func testEventDetailDecodesStagesPrizesAndBrackets() throws {
        let detail = try decode(V3Response<V3EventDetail, V3EntityMeta>.self, eventDetailPayload).data

        XCTAssertEqual(detail.id, 2283)
        XCTAssertEqual(detail.prize.displayText, "$2,250,000")
        XCTAssertEqual(detail.stages.map(\.slug), ["playoffs", "group-stage"])
        XCTAssertEqual(detail.activeStage?.slug, "playoffs")
        XCTAssertEqual(detail.teams.first?.team.id, 624)
        XCTAssertEqual(detail.teams.first?.players.first?.name, "Jinggg")
        XCTAssertEqual(detail.prizes.first?.team?.name, "NRG")
        XCTAssertEqual(detail.groups.first?.teams.first?.state, .advanced)
        XCTAssertEqual(detail.brackets.first?.rounds.first?.matches.first?.teams.first?.score, 2)
        XCTAssertTrue(detail.hasStageContent)
    }

    func testEventStatsDecodesPlayers() throws {
        let body = try decode(V3Response<V3EventStatsData, V3EntityMeta>.self, eventStatsPayload)

        XCTAssertEqual(body.meta.id, 2283)
        XCTAssertEqual(body.data.players.first?.player.name, "aspas")
        XCTAssertEqual(body.data.players.first?.rating, 1.33)
        XCTAssertNil(body.data.players.first?.headshotPercent)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try VLRAPI.decoder.decode(type, from: Data(json.utf8))
    }
}

private let eventListPayload = """
{
  "api_version": "3",
  "data": [
    {
      "id": 3185,
      "name": "VCT 27: AMER Kickoff",
      "status": "unknown",
      "prize": {"amount": null, "currency": null, "display": null},
      "date_text": null,
      "region_code": "AMER",
      "url": "https://www.vlr.gg/event/3185",
      "image": {"url": "https://owcdn.net/img/a.png", "light_url": null, "dark_url": null}
    },
    {
      "id": 3177,
      "name": "VCT 2027: EMEA Kickoff - Türkiye Qualifier",
      "status": "ongoing",
      "prize": {"amount": null, "currency": null, "display": "TBD"},
      "date_text": "Nov 10—Dec 6",
      "region_code": "tr",
      "url": "https://www.vlr.gg/event/3177",
      "image": {"url": "https://owcdn.net/img/a.png", "light_url": null, "dark_url": "https://owcdn.net/img/dark.png"}
    }
  ],
  "meta": {"source": "vlr.gg", "page": 1, "total_pages": null, "has_previous": false, "has_next": null}
}
"""

private let eventDetailPayload = """
{
  "api_version": "3",
  "data": {
    "id": 2283,
    "name": "Valorant Champions 2025",
    "series": "Valorant Champions Tour 2025",
    "subtitle": null,
    "date_text": "Sep 12 – Oct 6, 2025",
    "prize": {"amount": 2250000, "currency": "USD", "display": "$2,250,000"},
    "location": "Accor Arena, Paris",
    "region_code": "fr",
    "url": "https://www.vlr.gg/event/2283",
    "image": {"url": "https://owcdn.net/img/e.png", "light_url": null, "dark_url": null},
    "calendar": {"google": null, "apple": "webcal://www.vlr.gg/event/ical/2283", "subscription": null, "download": null},
    "stages": [
      {"name": "Playoffs", "slug": "playoffs", "date_text": "Sep 25–Oct 6", "url": null, "active": true},
      {"name": "Group Stage", "slug": "group-stage", "date_text": "Sep 12–23", "url": null, "active": false}
    ],
    "active_stage": {"name": "Playoffs", "slug": "playoffs", "date_text": "Sep 25–Oct 6", "url": null, "active": true},
    "resources": [],
    "teams": [
      {
        "team": {"id": 624, "name": "Paper Rex", "image": {"url": null, "light_url": null, "dark_url": null}, "is_winner": false},
        "players": [{"id": 7378, "name": "Jinggg", "country_code": "sg"}],
        "qualification": "Group A (#1)",
        "qualification_url": null
      }
    ],
    "prizes": [
      {
        "placement": "1st",
        "prize": {"amount": 1000000, "currency": "USD", "display": "$1,000,000"},
        "team": {"id": 1034, "name": "NRG", "region": "United States", "url": null, "image": {"url": null, "light_url": null, "dark_url": null}, "is_winner": false}
      },
      {"placement": "2nd", "prize": {"amount": null, "currency": null, "display": null}, "team": null}
    ],
    "standings": [],
    "groups": [
      {
        "id": 1,
        "name": "Group A",
        "teams": [
          {
            "rank": 1,
            "team": {"id": 624, "name": "Paper Rex", "image": {"url": null, "light_url": null, "dark_url": null}, "is_winner": false},
            "state": "advanced",
            "series_wins": 2, "series_losses": 0, "maps_won": 4, "maps_lost": 1,
            "rounds_won": 60, "rounds_lost": 40, "round_differential": 20
          }
        ],
        "matches": []
      }
    ],
    "brackets": [
      {
        "type": "upper",
        "rounds": [
          {
            "name": "Upper Quarterfinals",
            "matches": [
              {
                "id": 542264,
                "url": "https://www.vlr.gg/542264",
                "starts_at": "2025-09-25T16:50:00Z",
                "date_text": null,
                "status_text": "6:50 pm CEST, Sep 25",
                "series": null,
                "format": null,
                "has_stream": true,
                "teams": [
                  {"id": 2593, "name": "FNATIC", "image": {"url": null, "light_url": null, "dark_url": null}, "score": 2, "is_winner": true},
                  {"id": 8185, "name": "KIWOOM DRX", "image": {"url": null, "light_url": null, "dark_url": null}, "score": 0, "is_winner": false}
                ]
              }
            ]
          }
        ]
      }
    ]
  },
  "meta": {"source": "vlr.gg", "id": 2283}
}
"""

private let eventStatsPayload = """
{
  "api_version": "3",
  "data": {
    "filters": {"tier": "all", "region": "all", "span": "all", "side": "all", "role": "all", "agent": "all", "map_id": null, "minimum_rounds": 0, "minimum_rating": 0, "sort": "rating", "direction": "desc", "from_date": null, "to_date": null},
    "players": [
      {
        "player": {"id": 8480, "name": "aspas", "url": "https://www.vlr.gg/player/8480/aspas"},
        "country_code": "br",
        "organization": "MIBR",
        "agents": [{"agent": "neon", "usage_percent": 33.0}],
        "maps_played": 15,
        "rounds_played": 330,
        "rating": 1.33,
        "average_combat_score": 259.0,
        "kill_death_ratio": 1.66,
        "kast_percent": 79.0,
        "average_damage_per_round": 164.7,
        "headshot_percent": null,
        "kills": 319,
        "deaths": 192
      }
    ]
  },
  "meta": {"source": "vlr.gg", "id": 2283}
}
"""

private final class EventsRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var values: [String] { lock.withLock { log } }

    func append(_ value: String) {
        lock.withLock { log.append(value) }
    }
}

private final class EventsStubURLProtocol: URLProtocol {
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
