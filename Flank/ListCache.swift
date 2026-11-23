//
//  ListCache.swift
//  Flank
//

import Foundation

/// Offline copies of list screens (matches, news, rankings, stats), stored as JSON files
/// in the Caches directory.
///
/// These used to live in `UserDefaults`, which is read into memory at launch and isn't
/// meant for large blobs. The system may purge Caches under storage pressure, which is
/// fine here: losing the cache only means the next launch shows a spinner instead of
/// saved content.
struct ListCache: Sendable {
    /// `UserDefaults` keys that older versions used for these caches.
    static let legacyKeyPrefixes = ["v3.matches.", "v3.news.", "cachedRankings", "cachedPlayerStats."]

    static let shared: ListCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = ListCache(directory: caches.appending(path: "ListCache", directoryHint: .isDirectory))
        cache.migrateLegacyEntries(from: .standard)
        return cache
    }()

    let directory: URL

    func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        return try? VLRAPI.decoder.decode(type, from: data)
    }

    func save<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? VLRAPI.encoder.encode(value) else { return }
        write(data, forKey: key)
    }

    /// Moves caches written by older versions out of `UserDefaults`, keeping any file
    /// that already exists, and deletes the old keys either way.
    func migrateLegacyEntries(from defaults: UserDefaults) {
        let legacyEntries = defaults.dictionaryRepresentation().filter { key, _ in
            Self.legacyKeyPrefixes.contains { key.hasPrefix($0) }
        }
        for (key, value) in legacyEntries {
            if let data = value as? Data,
               !FileManager.default.fileExists(atPath: fileURL(forKey: key).path) {
                write(data, forKey: key)
            }
            defaults.removeObject(forKey: key)
        }
    }

    private func write(_ data: Data, forKey key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(forKey: key), options: .atomic)
        } catch {
            // A missing offline copy only costs a spinner on the next launch.
        }
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appending(path: "\(key).json", directoryHint: .notDirectory)
    }
}
