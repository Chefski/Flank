//
//  LogoColorSampler.swift
//  Flank
//

import SwiftUI
import UIImageColors

/// The colours UIImageColors finds in a logo, as a `Sendable` value.
struct LogoColors: Sendable, Equatable {
    let background: UIColor?
    let primary: UIColor?
    let secondary: UIColor?
    let detail: UIColor?

    fileprivate init(_ colors: UIImageColors) {
        background = colors.background
        primary = colors.primary
        secondary = colors.secondary
        detail = colors.detail
    }
}

/// Extracts colours from team and event logos for card and hero tints.
///
/// Each logo is downloaded and analysed once per launch: results are kept in memory,
/// and concurrent requests for the same logo share one download. The download goes
/// through `URLSession.shared`, so it can reuse the response `AsyncImage` already cached.
@MainActor
enum LogoColorSampler {
    private static var cache: [URL: LogoColors] = [:]
    private static var inFlight: [URL: Task<LogoColors?, Never>] = [:]

    /// Colours already sampled for `logo`, without any network or image work.
    static func cachedColors(for logo: String?) -> LogoColors? {
        VLRAPI.imageURL(from: logo).flatMap { cache[$0] }
    }

    /// Colours for `logo`, or `nil` when there is no logo or it couldn't be loaded.
    static func colors(for logo: String?) async -> LogoColors? {
        guard let url = VLRAPI.imageURL(from: logo) else { return nil }
        if let cached = cache[url] { return cached }

        let task: Task<LogoColors?, Never>
        if let existing = inFlight[url] {
            task = existing
        } else {
            task = Task { await sample(url) }
            inFlight[url] = task
        }

        let colors = await task.value
        inFlight[url] = nil
        if let colors {
            cache[url] = colors
        }
        return colors
    }

    private static func sample(_ url: URL) async -> LogoColors? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let image = UIImage(data: data) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            image.getColors { continuation.resume(returning: $0.map(LogoColors.init)) }
        }
    }
}
