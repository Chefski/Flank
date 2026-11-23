import XCTest
@testable import Flank

final class V3MatchAPITests: XCTestCase {
    func testScheduledMatchDecodesNullableDetails() throws {
        let envelope = try decodeDetail(scheduledPayload)

        XCTAssertEqual(envelope.apiVersion, "3")
        XCTAssertEqual(envelope.data.id, 712826)
        XCTAssertEqual(envelope.data.status, .scheduled)
        XCTAssertNil(envelope.data.startsAt)
        XCTAssertNil(envelope.data.patch)
        XCTAssertTrue(envelope.data.games.isEmpty)
        XCTAssertEqual(envelope.data.teams.count, 2)
        XCTAssertNil(envelope.data.teams[0].score)
    }

    func testLiveMatchDecodesPartialMapData() throws {
        let detail = try decodeDetail(livePayload).data

        XCTAssertEqual(detail.status, .live)
        XCTAssertEqual(detail.games.count, 1)
        XCTAssertNil(detail.games[0].mapName)
        XCTAssertEqual(detail.games[0].status, .inProgress)
        XCTAssertEqual(detail.games[0].score.team1, 6)
        XCTAssertNil(detail.games[0].score.team2)
        XCTAssertNil(detail.games[0].players.team1[0].rating)
        XCTAssertEqual(detail.games[0].players.team1[0].agent, "Omen")
        XCTAssertTrue(detail.games[0].rounds.isEmpty)
    }

    func testCompletedMatchDecodesAllDetailSections() throws {
        let detail = try decodeDetail(completedPayload).data

        XCTAssertEqual(detail.status, .completed)
        XCTAssertEqual(detail.patch, "13.01")
        XCTAssertEqual(detail.mapVetos, "Alpha pick Lotus; Beta pick Haven")
        XCTAssertEqual(detail.streams.first?.platform, "twitch")
        XCTAssertEqual(detail.vods.first?.mapNumber, 1)
        XCTAssertEqual(detail.games.first?.mapName, "Lotus")
        XCTAssertEqual(detail.games.first?.sideScores.team1.attack, 5)
        XCTAssertEqual(detail.games.first?.players.team1.first?.averageCombatScore, 242)
        XCTAssertEqual(detail.games.first?.rounds.first?.methodCode, "elim")
        XCTAssertEqual(detail.economy.first?.full.wins, 3)
        XCTAssertEqual(detail.performance.advancedStats.first?.multiKills.three, 1)
        XCTAssertEqual(detail.performance.advancedStats.first?.clutches.oneVsOne, 1)
        XCTAssertEqual(detail.headToHead.first?.id, 644674)
    }

    func testRFC3339TimestampWithFractionalSeconds() throws {
        let detail = try decodeDetail(
            scheduledPayload.replacingOccurrences(
                of: "\"starts_at\": null",
                with: "\"starts_at\": \"2026-07-30T11:00:00.125Z\""
            )
        ).data

        let startsAt = try XCTUnwrap(detail.startsAt)
        XCTAssertEqual(startsAt.timeIntervalSince1970, 1_785_409_200.125, accuracy: 0.001)
    }

    func testMissingOptionalFieldsRemainNil() throws {
        let detail = try decodeDetail(scheduledPayload).data

        XCTAssertNil(detail.statsID)
        XCTAssertNil(detail.dateText)
        XCTAssertNil(detail.format)
        XCTAssertNil(detail.event.stageSlug)
        XCTAssertNil(detail.teams[0].countryCode)
    }

    func testInvalidPayloadFailsDecoding() {
        let invalid = scheduledPayload.replacingOccurrences(of: "\"id\": 712826", with: "\"id\": \"not-an-integer\"")

        XCTAssertThrowsError(try decodeDetail(invalid))
    }

    func testHTTPErrorPreservesStatusAndRetryability() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v3/matches")
            XCTAssertEqual(request.url?.query, "q=results")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let client = VLRAPIClient(
            configuration: .init(host: "https://example.test"),
            session: stubSession()
        )

        do {
            _ = try await client.fetchMatches(query: .results)
            XCTFail("Expected an HTTP error")
        } catch let error as VLRAPIError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testInvalidHTTPPayloadReturnsDecodingError() async throws {
        StubURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data("{\"api_version\":\"3\",\"data\":{}}".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = VLRAPIClient(
            configuration: .init(host: "https://example.test"),
            session: stubSession()
        )

        do {
            _ = try await client.fetchMatches(query: .upcoming)
            XCTFail("Expected a decoding error")
        } catch let error as VLRAPIError {
            guard case .requestFailed(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message?.contains("could not be decoded") == true)
        }
    }

    func testRepositoryDeduplicatesAndReusesCachedDetail() async throws {
        let counter = CallCounter()
        let detail = try decodeDetail(completedPayload).data
        let repository = V3MatchDetailRepository(loader: { id in
            XCTAssertEqual(id, detail.id)
            await counter.increment()
            try await Task.sleep(for: .milliseconds(80))
            return detail
        })

        async let first = repository.detail(id: detail.id)
        async let second = repository.detail(id: detail.id)
        let results = try await (first, second)

        XCTAssertEqual(results.0.detail.id, detail.id)
        XCTAssertEqual(results.1.detail.id, detail.id)
        let callsAfterConcurrentRequests = await counter.value
        XCTAssertEqual(callsAfterConcurrentRequests, 1)

        let cached = try await repository.detail(id: detail.id)
        XCTAssertFalse(cached.isStale)
        let callsAfterCacheHit = await counter.value
        XCTAssertEqual(callsAfterCacheHit, 1)
    }

    func testRepositoryCancelsUnderlyingRequestWhenLastWaiterCancels() async throws {
        let cancellation = XCTestExpectation(description: "Loader cancelled")
        let detail = try decodeDetail(scheduledPayload).data
        let repository = V3MatchDetailRepository(loader: { _ in
            do {
                try await Task.sleep(for: .seconds(30))
                return detail
            } catch is CancellationError {
                cancellation.fulfill()
                throw CancellationError()
            }
        })

        let task = Task { try await repository.detail(id: 712826) }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await fulfillment(of: [cancellation], timeout: 1)
    }

    func testExpiredCacheFallsBackToStaleDetailOnNetworkError() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let counter = CallCounter()
        let detail = try decodeDetail(scheduledPayload).data
        let repository = V3MatchDetailRepository(
            cacheTTL: 300,
            now: { clock.now },
            loader: { _ in
                let call = await counter.increment()
                if call == 1 { return detail }
                throw VLRAPIError.transport(.notConnectedToInternet)
            }
        )

        let fresh = try await repository.detail(id: detail.id)
        XCTAssertFalse(fresh.isStale)

        clock.advance(by: 301)
        let stale = try await repository.detail(id: detail.id)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.detail.id, detail.id)
        let calls = await counter.value
        XCTAssertEqual(calls, 2)
    }

    func testUnknownEnumValuesDecodeAsUnknown() throws {
        let json = livePayload
            .replacingOccurrences(of: "\"status\": \"live\"", with: "\"status\": \"postponed\"")
            .replacingOccurrences(of: "\"status\": \"in_progress\"", with: "\"status\": \"paused\"")
        XCTAssertFalse(json.contains("\"in_progress\""), "Fixture no longer contains the game status")

        let detail = try decodeDetail(json).data

        XCTAssertEqual(detail.status, .unknown)
        XCTAssertEqual(detail.games.first?.status, .unknown)
    }

    func testMissingSectionsDecodeAsEmpty() throws {
        let json = """
        {
          "api_version": "3",
          "data": {
            "id": 1,
            "url": "https://www.vlr.gg/1/example",
            "status": "completed",
            "event": {"name": "Event"},
            "teams": [{"name": "Alpha"}, {"name": "Beta"}],
            "games": [{"id": 5, "number": 1, "status": "completed"}]
          },
          "meta": {"id": 1}
        }
        """

        let detail = try decodeDetail(json).data

        XCTAssertTrue(detail.streams.isEmpty)
        XCTAssertTrue(detail.headToHead.isEmpty)
        XCTAssertTrue(detail.performance.isEmpty)
        XCTAssertNil(detail.teams[0].image.url)
        XCTAssertNil(detail.event.image.url)
        let game = try XCTUnwrap(detail.games.first)
        XCTAssertTrue(game.players.team1.isEmpty)
        XCTAssertTrue(game.rounds.isEmpty)
        XCTAssertNil(game.score.team1)
        XCTAssertNil(game.sideScores.team1.attack)
    }

    func testMatchListToleratesNewValuesAndSurvivesCacheRoundTrip() throws {
        let json = """
        {
          "api_version": "3",
          "data": [
            {
              "id": 9,
              "source": "bracket",
              "url": "https://www.vlr.gg/9/example",
              "status": "delayed",
              "event": {"name": "Event", "image": {"url": null}},
              "teams": [{"name": "Alpha", "image": {}}, {"name": "Beta", "image": null}]
            }
          ],
          "meta": {"query": "something_new"}
        }
        """

        let response = try VLRAPI.decoder.decode(
            V3Response<[V3Match], V3MatchListMeta>.self,
            from: Data(json.utf8)
        )
        let match = try XCTUnwrap(response.data.first)
        XCTAssertEqual(match.source, .unknown)
        XCTAssertEqual(match.status, .unknown)
        XCTAssertNil(match.display.relative)
        XCTAssertNil(match.secondTeam?.image.url)
        XCTAssertTrue(response.meta.failedPages.isEmpty)

        // The offline cache encodes and re-decodes matches.
        let cached = try VLRAPI.decoder.decode(
            [V3Match].self,
            from: VLRAPI.encoder.encode(response.data)
        )
        XCTAssertEqual(cached, response.data)
    }

    @MainActor
    func testFailedLoadKeepsCachedContentVisible() {
        let error = VLRAPIError.transport(.notConnectedToInternet)

        XCTAssertEqual(
            ListLoadState.afterFailure(error, hasContent: true, surface: "test"),
            .cachedOffline(error.errorDescription ?? "")
        )
        XCTAssertEqual(
            ListLoadState.afterFailure(error, hasContent: false, surface: "test"),
            .failed(message: error.errorDescription ?? "", retryable: true)
        )
        XCTAssertEqual(
            ListLoadState.afterFailure(VLRAPIError.invalidResponse, hasContent: false, surface: "test"),
            .failed(message: VLRAPIError.invalidResponse.errorDescription ?? "", retryable: false)
        )
    }

    @MainActor
    func testTeamProfileKeepsLoadedContentOnReappearAndFailedRefresh() async throws {
        let requests = RequestCounter()
        let failing = RequestCounter()
        StubURLProtocol.handler = { request in
            requests.increment()
            let url = try XCTUnwrap(request.url)
            let isFailing = failing.value > 0
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: isFailing ? 503 : 200,
                httpVersion: nil,
                headerFields: nil
            ))
            let body = url.query?.contains("q=profile") == true
                ? #"{"status":"success","data":{"segments":[{"id":"42","name":"Alpha"}]}}"#
                : #"{"status":"success","data":{"segments":[]}}"#
            return (response, isFailing ? Data() : Data(body.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let viewModel = TeamProfileViewModel(
            teamID: 42,
            client: VLRAPIClient(configuration: .init(host: "https://example.test"), session: stubSession())
        )

        await viewModel.load()
        XCTAssertEqual(loadedTeamName(viewModel.state), "Alpha")
        XCTAssertEqual(requests.value, 2)

        // Coming back to the screen must not refetch.
        await viewModel.load()
        XCTAssertEqual(requests.value, 2)

        // A failed pull-to-refresh keeps the profile on screen.
        failing.increment()
        await viewModel.load(forceRefresh: true)
        XCTAssertEqual(requests.value, 4)
        XCTAssertEqual(loadedTeamName(viewModel.state), "Alpha")
    }

    private func loadedTeamName(_ state: TeamProfileViewModel.State) -> String? {
        guard case .loaded(let profile, _, _, _) = state else { return nil }
        return profile?.name
    }

    func testListCacheMigratesLegacyDefaultsAndRoundTrips() throws {
        let suiteName = "ListCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        defaults.set(try VLRAPI.encoder.encode(["Alpha", "Beta"]), forKey: "cachedRankings.eu")
        defaults.set("na", forKey: "defaultRegion")

        let cache = ListCache(directory: directory)
        cache.migrateLegacyEntries(from: defaults)

        XCTAssertEqual(cache.load([String].self, forKey: "cachedRankings.eu"), ["Alpha", "Beta"])
        XCTAssertNil(defaults.object(forKey: "cachedRankings.eu"), "Migrated cache should leave UserDefaults")
        XCTAssertEqual(defaults.string(forKey: "defaultRegion"), "na", "Preferences must not be touched")

        cache.save(["Gamma"], forKey: "v3.news.page.1")
        XCTAssertEqual(cache.load([String].self, forKey: "v3.news.page.1"), ["Gamma"])
        XCTAssertNil(cache.load([String].self, forKey: "missing"))
    }

    private func decodeDetail(_ json: String) throws -> V3Response<V3MatchDetail, V3EntityMeta> {
        try VLRAPI.decoder.decode(
            V3Response<V3MatchDetail, V3EntityMeta>.self,
            from: Data(json.utf8)
        )
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var scheduledPayload: String {
        """
        {
          "api_version": "3",
          "data": {
            "id": 712826,
            "url": "https://www.vlr.gg/712826/example",
            "status": "scheduled",
            "starts_at": null,
            "notes": [],
            "event": {"name": "VCT 2026 EMEA", "image": {}},
            "teams": [
              {"name": "Alpha", "image": {}},
              {"name": "Beta", "image": {}}
            ],
            "streams": [],
            "vods": [],
            "games": [],
            "head_to_head": [],
            "performance": {"kill_matrix": [], "advanced_stats": []},
            "performance_by_game": [],
            "economy": [],
            "economy_by_game": []
          },
          "meta": {"source": "vlr.gg", "id": 712826}
        }
        """
    }

    private var livePayload: String {
        """
        {
          "api_version": "3",
          "data": {
            "id": 698903,
            "url": "https://www.vlr.gg/698903/example",
            "status": "live",
            "starts_at": "2026-07-30T07:15:00Z",
            "notes": [],
            "event": {"id": 2776, "name": "VCT Pacific", "image": {}},
            "teams": [
              {"id": 1, "name": "Alpha", "image": {}, "score": 0},
              {"id": 2, "name": "Beta", "image": {}, "score": 0}
            ],
            "streams": [],
            "vods": [],
            "games": [{
              "id": 1001,
              "number": 1,
              "map_name": null,
              "status": "in_progress",
              "score": {"team1": 6, "team2": null},
              "side_scores": {"team1": {}, "team2": {}},
              "players": {
                "team1": [{
                  "player": {"id": 10, "name": "Player A"},
                  "agent": "Omen",
                  "attack": {},
                  "defense": {}
                }],
                "team2": []
              },
              "rounds": [],
              "performance": {"kill_matrix": [], "advanced_stats": []},
              "economy": []
            }],
            "head_to_head": [],
            "performance": {"kill_matrix": [], "advanced_stats": []},
            "performance_by_game": [],
            "economy": [],
            "economy_by_game": []
          },
          "meta": {"id": 698903}
        }
        """
    }

    private var completedPayload: String {
        """
        {
          "api_version": "3",
          "data": {
            "id": 698902,
            "stats_id": 77,
            "url": "https://www.vlr.gg/698902/example",
            "status": "completed",
            "starts_at": "2026-07-30T04:00:00Z",
            "date_text": "4:00 AM",
            "patch": "13.01",
            "format": "Bo3",
            "map_vetos": "Alpha pick Lotus; Beta pick Haven",
            "notes": ["Final map was not required"],
            "event": {
              "id": 2776,
              "name": "VCT Pacific",
              "stage": "Group Stage",
              "series": "Week 3",
              "image": {"url": "https://example.test/event.png"}
            },
            "teams": [
              {"id": 1, "name": "Alpha", "tag": "ALP", "image": {"light_url": "https://example.test/a-light.png", "dark_url": "https://example.test/a-dark.png"}, "score": 1},
              {"id": 2, "name": "Beta", "tag": "BET", "image": {}, "score": 2, "is_winner": true}
            ],
            "streams": [{"name": "English", "url": "https://twitch.tv/example", "platform": "twitch", "embedded": true}],
            "vods": [{"name": "Map 1", "url": "https://youtube.com/watch?v=example", "platform": "youtube", "map_number": 1}],
            "games": [{
              "id": 273253,
              "number": 1,
              "map_name": "Lotus",
              "status": "completed",
              "duration": "1:04:17",
              "pick": {"slot": "team1", "team": {"id": 1, "name": "Alpha", "image": {}}},
              "score": {"team1": 11, "team2": 13},
              "side_scores": {
                "team1": {"total": 11, "attack": 5, "defense": 6},
                "team2": {"total": 13, "attack": 6, "defense": 7}
              },
              "players": {
                "team1": [{
                  "rating": 1.36,
                  "average_combat_score": 242,
                  "kills": 22,
                  "deaths": 18,
                  "assists": 9,
                  "kast_percent": 79,
                  "average_damage_per_round": 168,
                  "headshot_percent": 42,
                  "first_kills": 2,
                  "first_deaths": 1,
                  "player": {"id": 10, "name": "Player A"},
                  "agent": "Fade",
                  "attack": {"kills": 9},
                  "defense": {"kills": 13}
                }],
                "team2": []
              },
              "rounds": [{
                "number": 1,
                "winner": "team2",
                "side": "defense",
                "method": "elimination",
                "method_code": "elim",
                "score_after": {"team1": 0, "team2": 1}
              }],
              "performance": {"kill_matrix": [], "advanced_stats": []},
              "economy": [{"team_id": 1, "eco": {"rounds": 3, "wins": 1}, "low": {}, "medium": {}, "full": {"rounds": 9, "wins": 3}}]
            }],
            "head_to_head": [{
              "id": 644674,
              "url": "https://www.vlr.gg/644674/example",
              "event_name": "Previous event",
              "teams": [
                {"id": 1, "name": "Alpha", "image": {}},
                {"id": 2, "name": "Beta", "image": {}, "is_winner": true}
              ],
              "score": {"team1": 1, "team2": 2}
            }],
            "performance": {
              "kill_matrix": [{
                "player": {"id": 10, "name": "Player A"},
                "matchups": [{"opponent": {"id": 11, "name": "Player B"}, "kills": 5, "deaths": 3, "differential": 2}]
              }],
              "advanced_stats": [{
                "player": {"id": 10, "name": "Player A"},
                "agent": "Fade",
                "multi_kills": {"two": 2, "three": 1},
                "clutches": {"one_vs_one": 1},
                "economy_rating": 68,
                "plants": 5,
                "defuses": 0
              }]
            },
            "performance_by_game": [{"game_id": 273253, "kill_matrix": [], "advanced_stats": []}],
            "economy": [{"team_id": 1, "eco": {}, "low": {}, "medium": {}, "full": {"wins": 3}}],
            "economy_by_game": [{"game_id": 273253, "teams": []}]
          },
          "meta": {"source": "vlr.gg", "id": 698902}
        }
        """
    }
}

private final class StubURLProtocol: URLProtocol {
    // Tests set this one at a time before making requests.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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

private actor CallCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
