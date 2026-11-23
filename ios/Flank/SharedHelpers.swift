//
//  SharedHelpers.swift
//  Flank
//
//  Small helpers shared across screens.
//

import Foundation

// MARK: - Blank strings

extension String {
    /// The string without surrounding whitespace, or `nil` when nothing is left.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    /// The trimmed value, or `nil` when it is missing or blank.
    var nilIfBlank: String? {
        self?.nilIfBlank
    }
}

// MARK: - API dates

extension Calendar {
    /// The calendar for reading and building the API's dates, which are always
    /// Gregorian (`yyyy-MM-dd`, `yyyy/MM/dd`). The user's own calendar may be Buddhist or
    /// Japanese, so it is only for display; this one keeps its time zone.
    static func apiGregorian(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

// MARK: - Refresh failures

/// Why a refresh failed while saved content stays on screen, for `SavedDataBanner`.
struct RefreshFailure: Equatable, Sendable {
    let message: String
    /// True only when the connection was the problem, not the server or the data.
    let isOffline: Bool

    init(message: String, isOffline: Bool) {
        self.message = message
        self.isOffline = isOffline
    }

    init(_ error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        isOffline = AnalyticsErrorCategory(error) == .offline
    }
}
