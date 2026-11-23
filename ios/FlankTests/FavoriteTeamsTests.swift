import XCTest
@testable import Flank

@MainActor
final class FavoriteTeamsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "FavoriteTeamsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> FavoriteTeamsStore {
        FavoriteTeamsStore(defaults: defaults, cloud: nil, now: { [unowned self] in clock })
    }

    func testToggleAddsAndRemovesFavorite() {
        let store = makeStore()
        store.toggle(teamID: 2, name: "Sentinels", logo: nil)
        XCTAssertTrue(store.isFavorite(2))
        XCTAssertEqual(store.teams.map(\.name), ["Sentinels"])

        clock += 1
        store.toggle(teamID: 2, name: "Sentinels", logo: nil)
        XCTAssertFalse(store.isFavorite(2))
        XCTAssertTrue(store.teams.isEmpty)
    }

    func testFavoritesPersistAcrossLaunchesSortedByName() {
        let store = makeStore()
        store.setFavorite(true, teamID: 1, name: "Team Liquid", logo: "liquid.png")
        store.setFavorite(true, teamID: 2, name: "fnatic", logo: nil)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.teams.map(\.name), ["fnatic", "Team Liquid"])
        XCTAssertEqual(relaunched.teams.last?.logo, "liquid.png")
    }

    func testRefreshDetailsUpdatesOnlyFavorites() {
        let store = makeStore()
        store.setFavorite(true, teamID: 1, name: "Old Name", logo: "old.png")
        store.refreshDetails(teamID: 1, name: "New Name", logo: nil)
        store.refreshDetails(teamID: 99, name: "Not Followed", logo: nil)

        XCTAssertEqual(store.teams, [FavoriteTeam(id: 1, name: "New Name", logo: "old.png")])
    }

    func testMergeKeepsNewestRecordPerTeam() {
        let base = Date(timeIntervalSince1970: 1_000)
        let removedOnPhone = FavoriteTeamRecord(id: 1, name: "A", logo: nil, isFavorite: false, updatedAt: base + 10)
        let staleOnPad = FavoriteTeamRecord(id: 1, name: "A", logo: nil, isFavorite: true, updatedAt: base)
        let addedOnPad = FavoriteTeamRecord(id: 2, name: "B", logo: nil, isFavorite: true, updatedAt: base + 5)

        let merged = FavoriteTeamRecord.merge([removedOnPhone], [staleOnPad, addedOnPad], now: base + 20)

        XCTAssertEqual(merged, [removedOnPhone, addedOnPad])
    }

    func testMergeDropsExpiredTombstones() {
        let base = Date(timeIntervalSince1970: 1_000)
        let tombstone = FavoriteTeamRecord(id: 1, name: "A", logo: nil, isFavorite: false, updatedAt: base)

        XCTAssertEqual(FavoriteTeamRecord.merge([tombstone], [], now: base + 50, tombstoneLifetime: 100), [tombstone])
        XCTAssertEqual(FavoriteTeamRecord.merge([tombstone], [], now: base + 150, tombstoneLifetime: 100), [])
    }
}
