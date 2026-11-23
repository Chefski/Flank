import XCTest
@testable import Flank

final class MatchReplayTests: XCTestCase {
    func testRealLogsPayloadDecodes() throws {
        let replay = try decodeReplay(Self.logsPayload)

        XCTAssertEqual(replay.matchID, "793796")
        XCTAssertEqual(replay.gameID, "298328")
        XCTAssertEqual(replay.map, "sunset")
        XCTAssertEqual(replay.teams.team1?.name, "ZEXAR ESPORTS")
        XCTAssertEqual(replay.teams.team2?.tag, "SGN")
        XCTAssertEqual(replay.rounds.map(\.number), [1, 13, 15])

        let first = replay.rounds[0]
        XCTAssertEqual(first.winner, .team2)
        XCTAssertEqual(first.attackingSide, .team1)
        XCTAssertEqual(first.score, ReplayScore(team1: 0, team2: 1))
        XCTAssertEqual(first.endReason, "Time expired")
        XCTAssertEqual(first.phase, .firstHalf)
        XCTAssertEqual(first.economy.count, 10)
        XCTAssertEqual(first.buys(for: .team1).count, 5)
        XCTAssertEqual(first.economy[2].player, "fluxx")
        XCTAssertEqual(first.economy[2].agent, "chamber")
        XCTAssertEqual(first.economy[2].spent, 800)
        XCTAssertEqual(first.economy[2].armor, ReplayArmor.none)
        XCTAssertEqual(first.agentsByPlayer["fluxx"], "chamber")

        let kill = first.events[0]
        XCTAssertEqual(kill.kind, .kill)
        XCTAssertEqual(kill.time, "0:21")
        XCTAssertEqual(kill.player, "fluxx")
        XCTAssertEqual(kill.slot, .team1)
        XCTAssertEqual(kill.victim, "Garv")
        XCTAssertEqual(kill.victimSlot, .team2)
        XCTAssertEqual(kill.source, "Headhunter")
        XCTAssertEqual(kill.position, ReplayPoint(x: 716.1, y: 670.3))
        XCTAssertEqual(kill.origin, ReplayPoint(x: 678.6, y: 785.6))
        XCTAssertEqual(kill.positions.first?.player, "tricky")
        // Older servers send the facing angle as `hp`.
        XCTAssertEqual(kill.positions.first?.facing, 180)
        XCTAssertNil(kill.headshot)
        XCTAssertFalse(kill.isSpikeKill)

        let secondHalf = replay.rounds[1]
        XCTAssertEqual(secondHalf.phase, .secondHalf)
        XCTAssertEqual(secondHalf.attackingSide, .team2)
        let plant = try XCTUnwrap(secondHalf.events.last)
        XCTAssertEqual(plant.kind, .plant)
        XCTAssertEqual(plant.site, "A")
        XCTAssertNil(plant.victim)

        let spikeDeaths = replay.rounds[2].events.filter(\.isSpikeKill)
        XCTAssertEqual(spikeDeaths.map(\.victim), ["Garv", "tricky"])

        XCTAssertEqual(replay.canvasSize, 1024)
    }

    func testMalformedValuesDegradeInsteadOfFailing() throws {
        let replay = try decodeReplay("""
        {"status": "success", "data": {"status": 200, "segments": [{
          "match_id": 1, "game_id": "2", "map": "", "teams": {},
          "rounds": [
            {"round": null, "events": []},
            {"round": 2, "score": {}, "winner": "", "attacking_side": "team9",
             "economy": [{"player": "a", "team": "1", "armor": "shiny"}, 7],
             "events": [{"type": "boom", "t": "1:40"}, {"type": "kill", "pos": [1, 2], "positions": null}]}
          ]
        }]}}
        """)

        XCTAssertEqual(replay.matchID, "1")
        XCTAssertNil(replay.teams.team1)
        XCTAssertEqual(replay.rounds.map(\.number), [2], "A round without a number is dropped")
        let round = replay.rounds[0]
        XCTAssertEqual(round.winner, .unknown)
        XCTAssertEqual(round.attackingSide, .unknown)
        XCTAssertNil(round.score.team1)
        XCTAssertEqual(round.economy.count, 1)
        XCTAssertEqual(round.economy[0].slot, .team1)
        XCTAssertEqual(round.economy[0].armor, .unknown)
        XCTAssertEqual(round.events.map(\.kind), [.unknown, .kill])
        XCTAssertNil(round.events[1].position)
        XCTAssertTrue(round.events[1].positions.isEmpty)
        XCTAssertNil(replay.canvasSize, "No usable coordinates means no plot")
    }

    func testEmptySegmentsAndCanvasDetection() throws {
        let envelope = try VLRAPI.decoder.decode(
            MatchReplayEnvelope.self,
            from: Data(#"{"status": 200}"#.utf8)
        )
        XCTAssertTrue(envelope.segments.isEmpty)

        let normalised = try decodeReplay(replayJSON(x: 0.4, y: 0.9))
        XCTAssertEqual(normalised.canvasSize, 1)
        let outOfRange = try decodeReplay(replayJSON(x: 2048, y: 10))
        XCTAssertNil(outOfRange.canvasSize)
    }

    func testReplaySurvivesCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ListCache(directory: directory)
        let replay = try decodeReplay(Self.logsPayload)

        cache.save(replay, forKey: "replay.793796.298328")

        XCTAssertEqual(cache.load(MatchReplay.self, forKey: "replay.793796.298328"), replay)
    }

    func testFetchUsesLogsPathAndGameID() async throws {
        ReplayStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v2/match/793796/logs")
            XCTAssertEqual(request.url?.query, "game_id=298328")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(Self.logsPayload.utf8))
        }
        defer { ReplayStubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayStubURLProtocol.self]
        let client = VLRAPIClient(
            configuration: .init(host: "https://example.test"),
            session: URLSession(configuration: configuration)
        )

        let replay = try await client.fetchMatchReplay(matchID: 793796, gameID: 298328)
        XCTAssertEqual(replay?.rounds.count, 3)
    }

    func testFacingDecodesFromNewKeyBeforeLegacyHP() throws {
        let position = try VLRAPI.decoder.decode(
            ReplayPosition.self,
            from: Data(#"{"player": "a", "team": 1, "x": 1, "y": 2, "hp": 90, "facing": 271.5}"#.utf8)
        )
        XCTAssertEqual(position.facing, 271.5)

        let roundTripped = try VLRAPI.decoder.decode(ReplayPosition.self, from: VLRAPI.encoder.encode(position))
        XCTAssertEqual(roundTripped, position)
    }

    @MainActor
    func testFailedRefreshKeepsSavedReplayVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ListCache(directory: directory)
        let replay = try decodeReplay(Self.logsPayload)
        // Saved while the map was in progress, so it is refreshed.
        cache.save(SavedMatchReplay(replay: replay, savedAt: Date(), isComplete: false), forKey: "replay.1.2")

        let viewModel = MatchReplayViewModel(matchID: 1, gameID: 2, cache: cache, loader: { _, _ in
            throw VLRAPIError.httpStatus(503)
        })
        await viewModel.load()

        guard case .loaded(let shown, let refreshFailure) = viewModel.state else {
            return XCTFail("Expected the saved replay, got \(viewModel.state)")
        }
        XCTAssertEqual(shown, replay)
        // A server error isn't blamed on the connection.
        XCTAssertEqual(refreshFailure?.isOffline, false)
        XCTAssertEqual(refreshFailure?.message, VLRAPIError.httpStatus(503).errorDescription)
    }

    @MainActor
    func testCompletedMapReusesRecentSavedReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ListCache(directory: directory)
        let replay = try decodeReplay(Self.logsPayload)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save(SavedMatchReplay(replay: replay, savedAt: savedAt, isComplete: true), forKey: "replay.1.2")
        let loads = ReplayLoadCounter()

        let recent = MatchReplayViewModel(
            matchID: 1, gameID: 2, cache: cache, now: { savedAt.addingTimeInterval(600) },
            loader: { _, _ in
                loads.increment()
                return replay
            }
        )
        await recent.load()
        XCTAssertEqual(loads.value, 0, "A finished map's recent copy is used as is")
        guard case .loaded(_, nil) = recent.state else {
            return XCTFail("Expected the saved replay, got \(recent.state)")
        }

        await recent.load(force: true)
        XCTAssertEqual(loads.value, 1, "Pull to refresh always reloads")

        let inProgress = MatchReplayViewModel(
            matchID: 1, gameID: 2, isMapInProgress: true, cache: cache, now: { savedAt.addingTimeInterval(600) },
            loader: { _, _ in
                loads.increment()
                return replay
            }
        )
        await inProgress.load()
        XCTAssertEqual(loads.value, 2, "A map still being played always refreshes")
    }

    func testSavedReplayRefreshRules() throws {
        let replay = try decodeReplay(Self.logsPayload)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let complete = SavedMatchReplay(replay: replay, savedAt: savedAt, isComplete: true)
        let partial = SavedMatchReplay(replay: replay, savedAt: savedAt, isComplete: false)

        XCTAssertFalse(complete.needsRefresh(mapInProgress: false, now: savedAt.addingTimeInterval(3599)))
        XCTAssertTrue(complete.needsRefresh(mapInProgress: false, now: savedAt.addingTimeInterval(3600)))
        XCTAssertTrue(complete.needsRefresh(mapInProgress: true, now: savedAt))
        XCTAssertTrue(partial.needsRefresh(mapInProgress: false, now: savedAt), "A copy saved mid-map misses rounds")
    }

    @MainActor
    func testReplayWithoutRoundsShowsEmptyState() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = MatchReplayViewModel(matchID: 1, gameID: 3, cache: ListCache(directory: directory), loader: { _, _ in
            nil
        })
        await viewModel.load()

        guard case .empty = viewModel.state else {
            return XCTFail("Expected the empty state, got \(viewModel.state)")
        }
    }

    private func decodeReplay(_ json: String) throws -> MatchReplay {
        let body = try VLRAPI.decoder.decode(ReplayV2Body.self, from: Data(json.utf8))
        XCTAssertEqual(body.status, "success")
        return try XCTUnwrap(body.data.segments.first)
    }

    private func replayJSON(x: Double, y: Double) -> String {
        """
        {"status": "success", "data": {"segments": [{"rounds": [
          {"round": 1, "events": [{"type": "plant", "pos": {"x": \(x), "y": \(y)}}]}
        ]}]}}
        """
    }

    /// Trimmed from a real `GET /v2/match/793796/logs?game_id=298328` response
    /// (ZEXAR ESPORTS vs SIGN Esports, Sunset, 2026-11): rounds 1, 13 and 15, with
    /// fewer events, buys and positions.
    private static let logsPayload = """
        {
         "status": "success",
         "data": {
          "status": 200,
          "segments": [
           {
            "match_id": "793796",
            "game_id": "298328",
            "map": "sunset",
            "teams": {
             "team1": {
              "name": "ZEXAR ESPORTS",
              "tag": "ZXR"
             },
             "team2": {
              "name": "SIGN Esports",
              "tag": "SGN"
             }
            },
            "rounds": [
             {
              "round": 1,
              "score": {
               "team1": 0,
               "team2": 1
              },
              "winner": "team2",
              "attacking_side": "team1",
              "end_reason": "Time expired",
              "economy": [
               {
                "player": "howaboutn0",
                "team": 1,
                "agent": "sova",
                "credits": 0,
                "spent": 800,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "GhostyXD",
                "team": 1,
                "agent": "neon",
                "credits": 100,
                "spent": 700,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "fluxx",
                "team": 1,
                "agent": "chamber",
                "credits": 0,
                "spent": 800,
                "weapon": "Classic",
                "armor": "none"
               },
               {
                "player": "OBITO",
                "team": 1,
                "agent": "omen",
                "credits": 0,
                "spent": 800,
                "weapon": "Classic",
                "armor": "light"
               },
               {
                "player": "BlooDy13",
                "team": 1,
                "agent": "phoenix",
                "credits": 100,
                "spent": 700,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "Yuvi",
                "team": 2,
                "agent": "phoenix",
                "credits": 50,
                "spent": 750,
                "weapon": "Classic",
                "armor": "light"
               },
               {
                "player": "Deadly10",
                "team": 2,
                "agent": "cypher",
                "credits": 0,
                "spent": 800,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "Russ",
                "team": 2,
                "agent": "omen",
                "credits": 50,
                "spent": 750,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "Garv",
                "team": 2,
                "agent": "neon",
                "credits": 100,
                "spent": 700,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "tricky",
                "team": 2,
                "agent": "sova",
                "credits": 0,
                "spent": 800,
                "weapon": "Ghost",
                "armor": "none"
               }
              ],
              "events": [
               {
                "t": "0:21",
                "type": "kill",
                "player": "fluxx",
                "team": 1,
                "victim": "Garv",
                "victim_team": 2,
                "pos": {
                 "x": 716.1,
                 "y": 670.3
                },
                "from": {
                 "x": 678.6,
                 "y": 785.6
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 294.5,
                  "y": 524.2,
                  "hp": 180
                 },
                 {
                  "player": "OBITO",
                  "team": 1,
                  "x": 455.2,
                  "y": 766.5,
                  "hp": 33
                 }
                ],
                "source": "Headhunter"
               },
               {
                "t": "1:04",
                "type": "kill",
                "player": "Deadly10",
                "team": 2,
                "victim": "BlooDy13",
                "victim_team": 1,
                "pos": {
                 "x": 698.4,
                 "y": 544
                },
                "from": {
                 "x": 695.7,
                 "y": 325.4
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 817,
                  "y": 444.8,
                  "hp": 296
                 },
                 {
                  "player": "OBITO",
                  "team": 1,
                  "x": 943.9,
                  "y": 295.2,
                  "hp": 146
                 }
                ],
                "source": "Ghost"
               },
               {
                "t": "1:08",
                "type": "kill",
                "player": "tricky",
                "team": 2,
                "victim": "OBITO",
                "victim_team": 1,
                "pos": {
                 "x": 868.7,
                 "y": 288.9
                },
                "from": {
                 "x": 812.2,
                 "y": 443.4
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 812.2,
                  "y": 443.4,
                  "hp": 290
                 },
                 {
                  "player": "Deadly10",
                  "team": 2,
                  "x": 720.3,
                  "y": 393.7,
                  "hp": 352
                 }
                ],
                "source": "Ghost"
               }
              ]
             },
             {
              "round": 13,
              "score": {
               "team1": 2,
               "team2": 11
              },
              "winner": "team2",
              "attacking_side": "team2",
              "end_reason": "Elimination",
              "economy": [
               {
                "player": "howaboutn0",
                "team": 1,
                "agent": "sova",
                "credits": 0,
                "spent": 800,
                "weapon": "Ghost",
                "armor": "none"
               },
               {
                "player": "GhostyXD",
                "team": 1,
                "agent": "neon",
                "credits": 100,
                "spent": 700,
                "weapon": "Ghost",
                "armor": "none"
               }
              ],
              "events": [
               {
                "t": "0:12",
                "type": "kill",
                "player": "Deadly10",
                "team": 2,
                "victim": "GhostyXD",
                "victim_team": 1,
                "pos": {
                 "x": 470.8,
                 "y": 557.1
                },
                "from": {
                 "x": 560.5,
                 "y": 652
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 787.3,
                  "y": 569.2,
                  "hp": 316
                 },
                 {
                  "player": "OBITO",
                  "team": 1,
                  "x": 523.4,
                  "y": 394.2,
                  "hp": 87
                 }
                ],
                "source": "Ghost"
               },
               {
                "t": "0:30",
                "type": "plant",
                "player": "tricky",
                "team": 2,
                "pos": {
                 "x": 841.3,
                 "y": 323.4
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 841.3,
                  "y": 323.4,
                  "hp": 253
                 },
                 {
                  "player": "OBITO",
                  "team": 1,
                  "x": 691,
                  "y": 412,
                  "hp": 17
                 }
                ],
                "site": "A"
               }
              ]
             },
             {
              "round": 15,
              "score": {
               "team1": 3,
               "team2": 12
              },
              "winner": "team2",
              "attacking_side": "team2",
              "end_reason": "Elimination",
              "economy": [
               {
                "player": "howaboutn0",
                "team": 1,
                "agent": "sova",
                "credits": 50,
                "spent": 3050,
                "weapon": "Guardian",
                "armor": "light"
               },
               {
                "player": "GhostyXD",
                "team": 1,
                "agent": "neon",
                "credits": 300,
                "spent": 3100,
                "weapon": "Spectre",
                "armor": "heavy"
               }
              ],
              "events": [
               {
                "t": "0:19",
                "type": "plant",
                "player": "Deadly10",
                "team": 2,
                "pos": {
                 "x": 786.9,
                 "y": 331.8
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 948,
                  "y": 354.1,
                  "hp": 226
                 },
                 {
                  "player": "Garv",
                  "team": 2,
                  "x": 852.4,
                  "y": 424.7,
                  "hp": 251
                 }
                ],
                "site": "A"
               },
               {
                "t": "1:05",
                "type": "kill",
                "player": "Garv",
                "team": 2,
                "victim": "Garv",
                "victim_team": 2,
                "pos": {
                 "x": 646.5,
                 "y": 294.6
                },
                "positions": [
                 {
                  "player": "tricky",
                  "team": 2,
                  "x": 665.3,
                  "y": 187.7,
                  "hp": 143
                 },
                 {
                  "player": "Russ",
                  "team": 2,
                  "x": 425.1,
                  "y": 326.4,
                  "hp": 181
                 }
                ],
                "source": "Spike"
               },
               {
                "t": "1:05",
                "type": "kill",
                "player": "tricky",
                "team": 2,
                "victim": "tricky",
                "victim_team": 2,
                "pos": {
                 "x": 656.2,
                 "y": 193.8
                },
                "positions": [
                 {
                  "player": "Russ",
                  "team": 2,
                  "x": 415.8,
                  "y": 326.2,
                  "hp": 195
                 }
                ],
                "source": "Spike"
               }
              ]
             }
            ]
           }
          ]
         },
         "meta": null,
         "message": null
        }
        """
}

private struct ReplayV2Body: Decodable {
    let status: String
    let data: MatchReplayEnvelope
}

private final class ReplayStubURLProtocol: URLProtocol {
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

private final class ReplayLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
