//
//  FavoriteTeams.swift
//  Flank
//

import Foundation
import Observation

/// A team the user has favourited.
struct FavoriteTeam: Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let logo: String?
}

/// One team's favourite state as stored on disk and in iCloud.
///
/// Removing a favourite keeps the record with `isFavorite == false` (a tombstone), so a
/// device that syncs later can tell "removed on another device" apart from "never synced".
struct FavoriteTeamRecord: Codable, Hashable, Sendable {
    let id: Int
    var name: String
    var logo: String?
    var isFavorite: Bool
    var updatedAt: Date

    /// Merges two copies of the favourites list, keeping the newest record for each team
    /// and dropping tombstones older than `tombstoneLifetime`.
    static func merge(
        _ lhs: [FavoriteTeamRecord],
        _ rhs: [FavoriteTeamRecord],
        now: Date = .now,
        tombstoneLifetime: TimeInterval = 60 * 60 * 24 * 180
    ) -> [FavoriteTeamRecord] {
        var newest: [Int: FavoriteTeamRecord] = [:]
        for record in lhs + rhs {
            if let existing = newest[record.id], existing.updatedAt >= record.updatedAt { continue }
            newest[record.id] = record
        }
        return newest.values
            .filter { $0.isFavorite || now.timeIntervalSince($0.updatedAt) < tombstoneLifetime }
            .sorted { $0.id < $1.id }
    }
}

/// Favourite teams, synced through iCloud with no sign-in.
///
/// Anyone signed into iCloud on the device gets their favourites on all their devices;
/// without iCloud they stay on this device. A copy is always kept in `UserDefaults` so
/// favourites work offline and before the first iCloud sync finishes.
@MainActor
@Observable
final class FavoriteTeamsStore {
    static let shared = FavoriteTeamsStore(
        defaults: .standard,
        cloud: .default,
        cloudIdentity: { FileManager.default.ubiquityIdentityToken != nil }
    )

    static let storageKey = "favoriteTeams.v1"

    /// Favourite teams, sorted by name.
    private(set) var teams: [FavoriteTeam] = []
    private(set) var ids: Set<Int> = []
    /// Whether the device is signed into iCloud, so favourites sync.
    private(set) var isSyncingWithiCloud = false

    @ObservationIgnored private var records: [FavoriteTeamRecord] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private let cloudIdentity: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults,
        cloud: NSUbiquitousKeyValueStore?,
        cloudIdentity: @escaping () -> Bool = { false },
        now: @escaping () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.cloudIdentity = cloudIdentity
        self.now = now
        isSyncingWithiCloud = cloud != nil && cloudIdentity()

        let local = Self.decode(defaults.data(forKey: Self.storageKey))
        let remote = Self.decode(cloud?.data(forKey: Self.storageKey))
        apply(FavoriteTeamRecord.merge(local, remote, now: now()))
        persist()

        guard let cloud else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated { self?.cloudDidChange(reason: reason) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSyncingWithiCloud = self.cloudIdentity()
            }
        })
        cloud.synchronize()
    }

    func isFavorite(_ teamID: Int) -> Bool {
        ids.contains(teamID)
    }

    func toggle(teamID: Int, name: String, logo: String?) {
        setFavorite(!isFavorite(teamID), teamID: teamID, name: name, logo: logo)
    }

    func setFavorite(_ isFavorite: Bool, teamID: Int, name: String, logo: String?) {
        let existing = records.first { $0.id == teamID }
        let record = FavoriteTeamRecord(
            id: teamID,
            name: name.isEmpty ? existing?.name ?? name : name,
            logo: logo ?? existing?.logo,
            isFavorite: isFavorite,
            updatedAt: now()
        )
        apply(FavoriteTeamRecord.merge(records.filter { $0.id != teamID }, [record], now: now()))
        persist()
    }

    /// Refreshes a favourite's saved name and logo when a fresher copy is on screen, so the
    /// favourites list doesn't keep showing a team's old branding.
    func refreshDetails(teamID: Int, name: String, logo: String?) {
        guard let index = records.firstIndex(where: { $0.id == teamID && $0.isFavorite }) else { return }
        let current = records[index]
        let newLogo = logo ?? current.logo
        guard !name.isEmpty, current.name != name || current.logo != newLogo else { return }
        records[index].name = name
        records[index].logo = newLogo
        records[index].updatedAt = now()
        apply(records)
        persist()
    }

    private func cloudDidChange(reason: Int?) {
        let remote = Self.decode(cloud?.data(forKey: Self.storageKey))
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            // A different iCloud account: show its favourites rather than mixing in
            // the previous account's.
            apply(FavoriteTeamRecord.merge(remote, [], now: now()))
        } else {
            apply(FavoriteTeamRecord.merge(records, remote, now: now()))
        }
        persist()
    }

    private func apply(_ merged: [FavoriteTeamRecord]) {
        records = merged
        let favorites = merged
            .filter(\.isFavorite)
            .map { FavoriteTeam(id: $0.id, name: $0.name, logo: $0.logo) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if favorites != teams { teams = favorites }
        let favoriteIDs = Set(favorites.map(\.id))
        if favoriteIDs != ids { ids = favoriteIDs }
    }

    private func persist() {
        guard let data = try? JSONEncoder.favorites.encode(records) else { return }
        if defaults.data(forKey: Self.storageKey) != data {
            defaults.set(data, forKey: Self.storageKey)
        }
        if let cloud, cloud.data(forKey: Self.storageKey) != data {
            cloud.set(data, forKey: Self.storageKey)
        }
    }

    private static func decode(_ data: Data?) -> [FavoriteTeamRecord] {
        guard let data else { return [] }
        return (try? JSONDecoder.favorites.decode([FavoriteTeamRecord].self, from: data)) ?? []
    }
}

private extension JSONEncoder {
    static var favorites: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

private extension JSONDecoder {
    static var favorites: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
