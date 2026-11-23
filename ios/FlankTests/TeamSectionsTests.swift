import XCTest
@testable import Flank

final class TeamSectionsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testDecodesScheduleStatsRosterAndTransactions() throws {
        let fixtures = try decode(V2ProfileCollection<V2TeamFixture>.self, """
        {"status": 200, "segments": [{"match_id": "793778", "url": "https://www.vlr.gg/793778/a-vs-b",
          "event": "LR1", "date": "2026/11/24", "time": "10:00 am", "eta": "",
          "team1": {"name": "FunPlus Phoenix", "tag": "FPX", "logo": "https://owcdn.net/img/a.png"},
          "team2": {"name": "KeepBest Gaming", "tag": "KBG", "logo": ""}}]}
        """).segments
        XCTAssertEqual(fixtures.first?.numericID, 793778)
        XCTAssertEqual(fixtures.first?.team2.name, "KeepBest Gaming")

        let stats = try decode(V2ProfileCollection<V2TeamMapStat>.self, """
        {"status": 200, "segments": [{"map": "Bind", "games": 83, "win_pct": "64%", "wins": 53, "losses": 30,
          "atk_first": 37, "def_first": 45, "atk_rwin_pct": "57%", "atk_rw": 455, "atk_rl": 348,
          "def_rwin_pct": "56%", "def_rw": 480, "def_rl": 383}]}
        """).segments
        XCTAssertEqual(stats.first?.wins, 53)
        XCTAssertEqual(stats.first?.attackRoundsWon, 455)

        let roster = try decode(V2ProfileCollection<V2TeamGroupedRoster>.self, """
        {"status": 200, "segments": [{"active": [{"id": "20140", "url": "", "alias": "vora", "real_name": "Jordan",
          "avatar": "", "country": "ca", "is_captain": true, "role": "", "is_staff": false}],
          "staff": [], "former": [{"id": "1", "alias": "old", "date_joined": "2024/01/02", "date_left": "2025/03/04"}],
          "benched": [], "transactions": [{"date": "x"}]}]}
        """).segments.first
        XCTAssertEqual(roster?.active?.first?.alias, "vora")
        XCTAssertEqual(roster?.former?.first?.dateLeft, "2025/03/04")

        let transactions = try decode(V2ProfileCollection<V2TeamTransaction>.self, """
        {"status": 200, "segments": [{"date": "2025/11/07", "action": "join",
          "player": {"name": "bang", "id": "3880", "url": "", "avatar": "", "country": "us"}, "role": "Player"}]}
        """).segments
        XCTAssertEqual(transactions.first?.player?.id, "3880")
    }

    func testUpcomingKeepsYesterdayOnwardSoonestFirst() throws {
        func fixture(_ id: String, _ date: String?) -> V2TeamFixture {
            let dateJSON = date.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"match_id": "\(id)", "date": \(dateJSON), "team1": {"name": "A"}, "team2": {"name": "B"}}
            """
            return try! JSONDecoder().decode(V2TeamFixture.self, from: Data(json.utf8))
        }
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23))!
        let items = TeamFixtureSchedule.upcoming(
            [
                fixture("1", "2026/11/16"),
                fixture("2", "2026/11/24"),
                fixture("3", "2026/11/23"),
                fixture("4", nil),
                fixture("5", "2026/11/22"),
                fixture("3", "2026/11/23"),
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(items.map(\.fixture.matchID), ["5", "3", "2", "4"])
    }

    /// The user's calendar on a Thai device: the year is 2569 for Gregorian 2026.
    private var buddhistCalendar: Calendar {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        calendar.locale = Locale(identifier: "th_TH")
        return calendar
    }

    func testDatesStayGregorianOnBuddhistCalendar() throws {
        let calendar = buddhistCalendar
        let gregorian = Calendar.apiGregorian(timeZone: calendar.timeZone)

        let day = try XCTUnwrap(TeamFixtureSchedule.day(from: "2026/11/23", calendar: calendar))
        XCTAssertEqual(gregorian.dateComponents([.year, .month, .day, .hour], from: day),
                       DateComponents(year: 2026, month: 11, day: 23, hour: 0))
        XCTAssertEqual(calendar.component(.year, from: day), 2569, "Display still uses the user's calendar")

        let now = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        XCTAssertEqual(TeamMapStatsRange.pastYear.dateStart(now: now, calendar: calendar), "2025-11-23")
        XCTAssertEqual(TeamMapStatsRange.past90Days.dateStart(now: now, calendar: calendar), "2026-08-25")
    }

    func testUpcomingOnBuddhistCalendarKeepsRecentFixtures() throws {
        func fixture(_ id: String, _ date: String) -> V2TeamFixture {
            let json = """
            {"match_id": "\(id)", "date": "\(date)", "team1": {"name": "A"}, "team2": {"name": "B"}}
            """
            return try! JSONDecoder().decode(V2TeamFixture.self, from: Data(json.utf8))
        }
        let calendar = buddhistCalendar
        let now = Calendar.apiGregorian(timeZone: calendar.timeZone)
            .date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        let items = TeamFixtureSchedule.upcoming(
            [fixture("old", "2026/11/16"), fixture("next", "2026/11/24"), fixture("today", "2026/11/23")],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(items.map(\.fixture.matchID), ["today", "next"])
    }

    func testScheduleHidesCompletedAndHydratesRecentRows() throws {
        func fixture(_ id: String, _ date: String) -> V2TeamFixture {
            let json = """
            {"match_id": "\(id)", "date": "\(date)", "team1": {"name": "A"}, "team2": {"name": "B"}}
            """
            return try! JSONDecoder().decode(V2TeamFixture.self, from: Data(json.utf8))
        }
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        let items = TeamFixtureSchedule.upcoming(
            [
                fixture("y", "2026/11/22"),
                fixture("t", "2026/11/23"),
                fixture("a", "2026/11/25"),
                fixture("b", "2026/11/26"),
                fixture("c", "2026/11/27"),
            ],
            now: now,
            calendar: calendar
        )

        let visible = TeamFixtureSchedule.hidingCompleted(items, statuses: ["y": .completed, "t": .live])
        XCTAssertEqual(visible.map(\.fixture.matchID), ["t", "a", "b", "c"])

        let hydrated = items.enumerated().filter { index, item in
            TeamFixtureSchedule.shouldHydrate(item, at: index, now: now, calendar: calendar)
        }.map(\.element.fixture.matchID)
        XCTAssertEqual(hydrated, ["y", "t", "a"])

        // Past the row limit, rows dated today or earlier are still checked.
        let late = TeamFixtureSchedule.Item(fixture: fixture("late", "2026/11/23"), day: TeamFixtureSchedule.day(from: "2026/11/23", calendar: calendar))
        XCTAssertTrue(TeamFixtureSchedule.shouldHydrate(late, at: 7, now: now, calendar: calendar))
        XCTAssertFalse(TeamFixtureSchedule.shouldHydrate(items[4], at: 7, now: now, calendar: calendar))
    }

    func testMapPercentPrefersCountsOverText() {
        XCTAssertEqual(TeamMapPercent.rate(won: 3, lost: 1, fallback: "10%"), 0.75)
        XCTAssertEqual(TeamMapPercent.rate(won: 0, lost: 0, fallback: "64%"), 0.64)
        XCTAssertNil(TeamMapPercent.rate(won: 0, lost: 0, fallback: "-"))
    }

    func testMapStatsRangeDateStart() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        XCTAssertNil(TeamMapStatsRange.allTime.dateStart(now: now, calendar: calendar))
        XCTAssertEqual(TeamMapStatsRange.pastYear.dateStart(now: now, calendar: calendar), "2025-11-23")
        XCTAssertEqual(TeamMapStatsRange.past90Days.dateStart(now: now, calendar: calendar), "2026-08-25")
    }
}
