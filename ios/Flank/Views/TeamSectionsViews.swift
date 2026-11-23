//
//  TeamSectionsViews.swift
//  Flank
//
//  The Schedule, Maps, Roster and Transfers sections of the team profile. Each one
//  loads the first time it is shown, since every request scrapes a vlr.gg page.
//

import Foundation
import SwiftUI

// MARK: - Models

struct V2TeamFixtureTeam: Decodable, Sendable {
    let name: String?
    let tag: String?
    let logo: String?
}

/// A card from the team page's match list (`/v2/team/{id}/schedule`).
struct V2TeamFixture: Decodable, Sendable {
    let matchID: String
    let url: String?
    /// Only the series line of the card, e.g. "UBQF"; the event name is not sent.
    let event: String?
    /// `yyyy/MM/dd` as vlr.gg renders it, in the zone vlr.gg chose for the scraper.
    let date: String?
    let time: String?
    let eta: String?
    let team1: V2TeamFixtureTeam
    let team2: V2TeamFixtureTeam

    enum CodingKeys: String, CodingKey {
        case url, event, date, time, eta, team1, team2
        case matchID = "match_id"
    }

    var numericID: Int? { Int(matchID) }
}

/// One row of `/v2/team/{id}/stats`.
struct V2TeamMapStat: Decodable, Sendable {
    let map: String
    let games: Int?
    let winPercent: String?
    let wins: Int?
    let losses: Int?
    let attackFirst: Int?
    let defenseFirst: Int?
    let attackRoundWinPercent: String?
    let attackRoundsWon: Int?
    let attackRoundsLost: Int?
    let defenseRoundWinPercent: String?
    let defenseRoundsWon: Int?
    let defenseRoundsLost: Int?

    enum CodingKeys: String, CodingKey {
        case map, games, wins, losses
        case winPercent = "win_pct"
        case attackFirst = "atk_first"
        case defenseFirst = "def_first"
        case attackRoundWinPercent = "atk_rwin_pct"
        case attackRoundsWon = "atk_rw"
        case attackRoundsLost = "atk_rl"
        case defenseRoundWinPercent = "def_rwin_pct"
        case defenseRoundsWon = "def_rw"
        case defenseRoundsLost = "def_rl"
    }
}

/// The single segment of `/v2/team/{id}/roster`. Its raw `transactions` list is ignored;
/// the Transfers section loads those itself.
struct V2TeamGroupedRoster: Decodable, Sendable {
    let active: [V2TeamRosterMember]?
    let staff: [V2TeamRosterMember]?
    let former: [V2TeamRosterMember]?
    let benched: [V2TeamRosterMember]?
}

struct V2TeamTransactionPlayer: Decodable, Sendable {
    let name: String?
    let id: String?
    let url: String?
    let avatar: String?
    let country: String?
}

/// One row of `/v2/team/{id}/transactions`.
struct V2TeamTransaction: Decodable, Sendable {
    let date: String?
    let action: String?
    let player: V2TeamTransactionPlayer?
    let role: String?
}

extension VLRAPIClient {
    func fetchTeamSchedule(id: Int) async throws -> [V2TeamFixture] {
        try await fetchV2(V2ProfileCollection<V2TeamFixture>.self, path: "team/\(id)/schedule").segments
    }

    func fetchTeamMapStats(id: Int, dateStart: String? = nil) async throws -> [V2TeamMapStat] {
        let queryItems = dateStart.map { [URLQueryItem(name: "date_start", value: $0)] } ?? []
        return try await fetchV2(
            V2ProfileCollection<V2TeamMapStat>.self,
            path: "team/\(id)/stats",
            queryItems: queryItems
        ).segments
    }

    func fetchTeamRoster(id: Int) async throws -> V2TeamGroupedRoster? {
        try await fetchV2(V2ProfileCollection<V2TeamGroupedRoster>.self, path: "team/\(id)/roster").segments.first
    }

    func fetchTeamTransactions(id: Int) async throws -> [V2TeamTransaction] {
        try await fetchV2(V2ProfileCollection<V2TeamTransaction>.self, path: "team/\(id)/transactions").segments
    }
}

// MARK: - State

enum TeamProfileSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case schedule = "Schedule"
    case maps = "Maps"
    case roster = "Roster"
    case transfers = "Transfers"

    var id: Self { self }
}

enum TeamMapStatsRange: String, CaseIterable, Identifiable, Sendable {
    case allTime = "All time"
    case pastYear = "Past year"
    case past90Days = "90 days"

    var id: Self { self }

    /// The `date_start` query value (`yyyy-MM-dd`), or nil for the whole history.
    ///
    /// Always Gregorian: `calendar` (the user's, which may be Buddhist or Japanese) only
    /// supplies the time zone.
    func dateStart(now: Date = .now, calendar userCalendar: Calendar = .current) -> String? {
        let calendar = Calendar.apiGregorian(timeZone: userCalendar.timeZone)
        let start: Date?
        switch self {
        case .allTime: return nil
        case .pastYear: start = calendar.date(byAdding: .year, value: -1, to: now)
        case .past90Days: start = calendar.date(byAdding: .day, value: -90, to: now)
        }
        guard let start else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

enum TeamSectionState<Value: Sendable> {
    case idle
    case loading
    case loaded(Value)
    case failed(message: String, retryable: Bool)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

@MainActor
final class TeamSectionsViewModel: ObservableObject {
    @Published private(set) var schedule: TeamSectionState<[V2TeamFixture]> = .idle
    @Published private(set) var roster: TeamSectionState<V2TeamGroupedRoster?> = .idle
    @Published private(set) var transactions: TeamSectionState<[V2TeamTransaction]> = .idle
    @Published private(set) var mapStats: [TeamMapStatsRange: TeamSectionState<[V2TeamMapStat]>] = [:]
    @Published var mapStatsRange: TeamMapStatsRange = .allTime
    /// Why the last pull-to-refresh of a section failed while its content stayed on
    /// screen, keyed like `sectionKey(_:)`. Cleared by the next successful load.
    @Published private(set) var refreshFailures: [String: RefreshFailure] = [:]

    private let teamID: Int
    private let client: VLRAPIClient
    private var inFlight: Set<String> = []

    init(teamID: Int, client: VLRAPIClient = .init()) {
        self.teamID = teamID
        self.client = client
    }

    func mapStatsState(for range: TeamMapStatsRange) -> TeamSectionState<[V2TeamMapStat]> {
        mapStats[range] ?? .idle
    }

    /// Loads a section the first time it is shown; later calls keep what is on screen.
    func load(_ section: TeamProfileSection) async {
        await load(section, forceRefresh: false)
    }

    /// Reloads a section in place, keeping loaded content if the refresh fails.
    func refresh(_ section: TeamProfileSection) async {
        await load(section, forceRefresh: true)
    }

    /// The key of the section's content on screen; Maps has one per period.
    func sectionKey(_ section: TeamProfileSection) -> String {
        section == .maps ? "maps.\(mapStatsRange.rawValue)" : section.rawValue
    }

    func refreshFailure(for section: TeamProfileSection) -> RefreshFailure? {
        refreshFailures[sectionKey(section)]
    }

    private func load(_ section: TeamProfileSection, forceRefresh: Bool) async {
        let client = client
        let teamID = teamID
        switch section {
        case .overview:
            return
        case .schedule:
            await run(
                key: sectionKey(.schedule),
                state: schedule,
                update: { self.schedule = $0 },
                forceRefresh: forceRefresh
            ) { try await client.fetchTeamSchedule(id: teamID) }
        case .maps:
            let range = mapStatsRange
            let dateStart = range.dateStart()
            await run(
                key: sectionKey(.maps),
                state: mapStatsState(for: range),
                update: { self.mapStats[range] = $0 },
                forceRefresh: forceRefresh
            ) { try await client.fetchTeamMapStats(id: teamID, dateStart: dateStart) }
        case .roster:
            await run(
                key: sectionKey(.roster),
                state: roster,
                update: { self.roster = $0 },
                forceRefresh: forceRefresh
            ) { try await client.fetchTeamRoster(id: teamID) }
        case .transfers:
            await run(
                key: sectionKey(.transfers),
                state: transactions,
                update: { self.transactions = $0 },
                forceRefresh: forceRefresh
            ) { try await client.fetchTeamTransactions(id: teamID) }
        }
    }

    private func run<Value: Sendable>(
        key: String,
        state: TeamSectionState<Value>,
        update: (TeamSectionState<Value>) -> Void,
        forceRefresh: Bool,
        operation: @escaping @Sendable () async throws -> Value
    ) async {
        let hasContent = state.isLoaded
        guard forceRefresh || !hasContent, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        if !hasContent {
            update(.loading)
        }
        // Unstructured so switching sections mid-request doesn't throw the scrape away
        // and leave the section stuck loading; the result lands when it arrives.
        let result = await Task { await capturedProfileRequest(operation) }.value
        switch result {
        case .success(let value):
            refreshFailures[key] = nil
            update(.loaded(value))
        case .failure(let error):
            // A failed refresh keeps the section that is already on screen, with a notice.
            if hasContent {
                if error != .transport(.cancelled) {
                    refreshFailures[key] = RefreshFailure(error)
                }
                return
            }
            update(.failed(
                message: error.errorDescription ?? "This section is unavailable.",
                retryable: error.isRetryable
            ))
        }
    }
}

// MARK: - Picker and section host

struct TeamSectionPicker: View {
    @Binding var selection: TeamProfileSection
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TeamProfileSection.allCases) { section in
                    chip(for: section)
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // Opaque so content scrolling under the pinned chips doesn't show through.
        .background(Color(uiColor: .systemGroupedBackground))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Team profile section")
    }

    private func chip(for section: TeamProfileSection) -> some View {
        let isSelected = selection == section
        return Button {
            guard !isSelected else { return }
            if reduceMotion {
                selection = section
            } else {
                withAnimation(.snappy(duration: 0.3)) { selection = section }
            }
        } label: {
            Text(section.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : .primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.primary)
                            .matchedGeometryEffect(id: "selectedTeamSection", in: namespace)
                    } else {
                        Capsule()
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shows one lazily loaded section and starts its request when it first appears.
struct TeamSectionContent: View {
    let section: TeamProfileSection
    let teamName: String
    @ObservedObject var viewModel: TeamSectionsViewModel

    var body: some View {
        if let failure = viewModel.refreshFailure(for: section) {
            SavedDataBanner(
                offlineText: "Offline — couldn’t refresh",
                failedText: "Couldn’t refresh",
                message: failure.message,
                isOffline: failure.isOffline
            )
        }
        sectionBody
            .task(id: viewModel.sectionKey(section)) { await viewModel.load(section) }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .overview:
            EmptyView()
        case .schedule:
            TeamSectionStateView(
                state: viewModel.schedule,
                loadingTitle: "Loading schedule…",
                failureTitle: "Schedule unavailable",
                retry: retry
            ) { fixtures in
                TeamScheduleCard(fixtures: fixtures, teamName: teamName)
            }
        case .maps:
            VStack(spacing: 16) {
                Picker("Period", selection: $viewModel.mapStatsRange) {
                    ForEach(TeamMapStatsRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                TeamSectionStateView(
                    state: viewModel.mapStatsState(for: viewModel.mapStatsRange),
                    loadingTitle: "Loading map stats…",
                    failureTitle: "Map stats unavailable",
                    retry: retry
                ) { stats in
                    TeamMapStatsView(stats: stats)
                }
            }
        case .roster:
            TeamSectionStateView(
                state: viewModel.roster,
                loadingTitle: "Loading roster…",
                failureTitle: "Roster unavailable",
                retry: retry
            ) { roster in
                TeamGroupedRosterView(roster: roster)
            }
        case .transfers:
            TeamSectionStateView(
                state: viewModel.transactions,
                loadingTitle: "Loading transfers…",
                failureTitle: "Transfers unavailable",
                retry: retry
            ) { transactions in
                TeamTransactionsCard(transactions: transactions)
            }
        }
    }

    private func retry() {
        Task { await viewModel.refresh(section) }
    }
}

private struct TeamSectionStateView<Value: Sendable, Content: View>: View {
    let state: TeamSectionState<Value>
    let loadingTitle: String
    let failureTitle: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView(loadingTitle)
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message, let retryable):
            ProfileFailureView(title: failureTitle, message: message, retryable: retryable, retry: retry)
                .frame(minHeight: 260)
        case .loaded(let value):
            content(value)
        }
    }
}

// MARK: - Schedule

private struct TeamScheduleCard: View {
    let fixtures: [V2TeamFixture]
    let teamName: String

    /// Light match details by match ID, for exact start times, live status and
    /// spotting matches that have already finished.
    @State private var details: [String: V3MatchDetail] = [:]

    var body: some View {
        let upcoming = TeamFixtureSchedule.upcoming(fixtures)
        let visible = TeamFixtureSchedule.hidingCompleted(upcoming, statuses: details.mapValues(\.status))
        ProfileCard(title: "Upcoming matches", symbol: "calendar") {
            if visible.isEmpty {
                ProfileEmptyState(title: "No upcoming matches", symbol: "calendar.badge.clock")
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.fixture.matchID) { index, item in
                    let row = TeamFixtureRow(
                        fixture: item.fixture,
                        day: item.day,
                        teamName: teamName,
                        detail: details[item.fixture.matchID],
                        hydrates: TeamFixtureSchedule.shouldHydrate(item, at: index)
                    ) { detail in
                        details[item.fixture.matchID] = detail
                    }
                    if let matchID = item.fixture.numericID {
                        NavigationLink {
                            MatchDetailView(matchID: matchID, fallbackURL: item.fixture.url, source: "team_profile")
                        } label: {
                            row
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens match details")
                    } else {
                        row
                    }
                }
            }
        }
    }
}

enum TeamFixtureSchedule {
    struct Item {
        let fixture: V2TeamFixture
        let day: Date?
    }

    /// Rows that read the light match detail for an exact start time and status, beyond
    /// the ones dated today or earlier. Capped so a long list doesn't scrape a match
    /// page per row.
    static let hydratedRowLimit = 3

    /// The team page lists recent results alongside upcoming matches, without scores or
    /// a status, so this keeps cards dated from yesterday on (vlr.gg's dates can be a day
    /// behind the viewer's zone), soonest first. Undated cards go last.
    ///
    /// `calendar` is the user's and only supplies the time zone; vlr.gg's dates are
    /// Gregorian whatever calendar the user has.
    static func upcoming(
        _ fixtures: [V2TeamFixture],
        now: Date = .now,
        calendar userCalendar: Calendar = .current
    ) -> [Item] {
        let calendar = Calendar.apiGregorian(timeZone: userCalendar.timeZone)
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var seen = Set<String>()
        return fixtures
            .filter { seen.insert($0.matchID).inserted }
            .map { Item(fixture: $0, day: day(from: $0.date, calendar: calendar)) }
            .filter { item in item.day.map { $0 >= cutoff } ?? true }
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.day, rhs.element.day) {
                case let (left?, right?) where left != right: left < right
                case (nil, _?): false
                case (_?, nil): true
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Drops fixtures whose match detail says they're over, so yesterday's results
    /// don't show as upcoming.
    static func hidingCompleted(_ items: [Item], statuses: [String: V3MatchStatus]) -> [Item] {
        items.filter { statuses[$0.fixture.matchID] != .completed }
    }

    /// The first few rows, plus any dated today or earlier, since those may already
    /// be live or finished.
    static func shouldHydrate(
        _ item: Item,
        at index: Int,
        now: Date = .now,
        calendar userCalendar: Calendar = .current
    ) -> Bool {
        if index < hydratedRowLimit { return true }
        guard let day = item.day else { return false }
        let calendar = Calendar.apiGregorian(timeZone: userCalendar.timeZone)
        let today = calendar.startOfDay(for: now)
        return day <= today
    }

    /// Parses vlr.gg's `yyyy/MM/dd` (or `yyyy-MM-dd`) day into local midnight.
    ///
    /// Always Gregorian: `calendar` (the user's) only supplies the time zone.
    static func day(from value: String?, calendar userCalendar: Calendar = .current) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        let calendar = Calendar.apiGregorian(timeZone: userCalendar.timeZone)
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

private struct TeamFixtureRow: View {
    let fixture: V2TeamFixture
    let day: Date?
    let teamName: String
    let detail: V3MatchDetail?
    let hydrates: Bool
    let onHydrate: (V3MatchDetail) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            opponentLogo
            VStack(alignment: .leading, spacing: 3) {
                Text("vs \(opponentName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !eventLine.isEmpty {
                    Text(eventLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            timing
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: .now))
        .task(id: fixture.matchID) { await hydrate() }
    }

    // MARK: Teams

    /// The team page lists its own team first; the names decide only when it doesn't.
    private var opponentIndex: Int {
        isTeam(fixture.team2.name) && !isTeam(fixture.team1.name) ? 0 : 1
    }

    private func isTeam(_ name: String?) -> Bool {
        guard let name = name.nilIfBlank else { return false }
        return name.compare(teamName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private var fixtureOpponent: V2TeamFixtureTeam {
        opponentIndex == 1 ? fixture.team2 : fixture.team1
    }

    private var detailOpponent: V3TeamRef? {
        guard let detail else { return nil }
        let byName = detail.teams.first { team in
            team.name.compare(fixtureOpponent.name ?? "", options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
        return byName ?? (detail.teams.indices.contains(opponentIndex) ? detail.teams[opponentIndex] : nil)
    }

    private var opponentName: String {
        fixtureOpponent.name.nilIfBlank ?? detailOpponent?.name ?? "TBD"
    }

    private var opponentLogo: some View {
        let logo = detailOpponent?.image.preferred(for: colorScheme) ?? fixtureOpponent.logo
        return AsyncImage(url: VLRAPI.imageURL(from: logo)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image("unknown_team").resizable().scaledToFit()
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private var eventLine: String {
        [(detail?.event.name).nilIfBlank, (detail?.event.series).nilIfBlank ?? fixture.event.nilIfBlank]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Timing

    private var startsAt: Date? { detail?.startsAt }

    @ViewBuilder
    private var timing: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if detail?.status == .live {
                LiveBadge()
            } else if detail?.status == .completed {
                TeamFixturePill(text: "Final", tint: .secondary, emphasised: false)
            } else if let startsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let soon = startsAt.timeIntervalSince(context.date) < 3600
                    TeamFixturePill(
                        text: TeamFixtureCountdown.text(to: startsAt, now: context.date),
                        tint: soon ? .orange : .secondary,
                        emphasised: soon
                    )
                }
            } else if let day {
                TeamFixturePill(text: TeamFixtureCountdown.dayText(for: day), tint: .secondary, emphasised: false)
            }

            if let startsAt {
                Text(startsAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let day {
                Text(day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilityText(now: Date) -> String {
        var parts = ["Versus \(opponentName)"]
        if !eventLine.isEmpty { parts.append(eventLine) }
        if detail?.status == .live {
            parts.append("Live now")
        } else if detail?.status == .completed {
            parts.append("Finished")
        } else if let startsAt {
            parts.append(TeamFixtureCountdown.text(to: startsAt, now: now))
            parts.append(startsAt.formatted(date: .complete, time: .shortened))
        } else if let day {
            parts.append(day.formatted(date: .complete, time: .omitted))
        }
        return parts.joined(separator: ", ")
    }

    /// The schedule card carries no timezone or status, so some rows read them from
    /// the light match detail (one vlr.gg request), which the repository caches.
    private func hydrate() async {
        guard hydrates, detail == nil, let matchID = fixture.numericID else { return }
        do {
            let result = try await V3MatchDetailRepository.shared.detail(id: matchID, light: true)
            try Task.checkCancellation()
            onHydrate(result.detail)
        } catch {
            // Keep the date from the schedule card.
        }
    }
}

private struct TeamFixturePill: View {
    let text: String
    let tint: Color
    let emphasised: Bool

    var body: some View {
        Label(text, systemImage: "clock")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(emphasised ? tint.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
    }
}

enum TeamFixtureCountdown {
    static func text(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return String(localized: "Starting") }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return String(localized: "in \(days)d \(hours)h") }
        if hours > 0 { return String(localized: "in \(hours)h \(minutes)m") }
        return String(localized: "in \(max(minutes, 1))m")
    }

    static func dayText(for day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: day).day ?? 0
        return days > 0 ? String(localized: "in \(days) days") : day.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Maps

private struct TeamMapStatsView: View {
    let stats: [V2TeamMapStat]

    var body: some View {
        let played = stats
            .filter { $0.played > 0 }
            .sorted { lhs, rhs in lhs.played == rhs.played ? lhs.map < rhs.map : lhs.played > rhs.played }

        if played.isEmpty {
            ProfileCard(title: "Map pool", symbol: "map") {
                ProfileEmptyState(title: "No maps played in this period", symbol: "map")
            }
        } else {
            TeamMapSummaryCard(stats: played)
            ProfileCard(title: "Maps", symbol: "map") {
                ForEach(Array(played.enumerated()), id: \.element.map) { index, stat in
                    if index > 0 { Divider() }
                    TeamMapStatRow(stat: stat)
                }
            }
        }
    }
}

private struct TeamMapSummaryCard: View {
    let stats: [V2TeamMapStat]

    var body: some View {
        let wins = stats.reduce(0) { $0 + ($1.wins ?? 0) }
        let losses = stats.reduce(0) { $0 + ($1.losses ?? 0) }
        // Ignore one-off picks so a single win doesn't make a map the "best".
        let best = stats
            .filter { $0.played >= 3 }
            .max { ($0.winRate ?? 0) < ($1.winRate ?? 0) }

        ProfileCard(title: "Map pool", symbol: "chart.bar.xaxis") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { metrics(wins: wins, losses: losses, best: best) }
                VStack(spacing: 10) { metrics(wins: wins, losses: losses, best: best) }
            }
        }
    }

    @ViewBuilder
    private func metrics(wins: Int, losses: Int, best: V2TeamMapStat?) -> some View {
        ProfileMetric(label: "Maps", value: "\(wins + losses)")
        ProfileMetric(label: "Record", value: "\(wins)–\(losses)")
        if wins + losses > 0 {
            ProfileMetric(label: "Win rate", value: TeamMapPercent.text(Double(wins) / Double(wins + losses)))
        }
        if let best, let rate = best.winRate {
            ProfileMetric(label: "Best map", value: "\(best.map) \(TeamMapPercent.text(rate))")
        }
    }
}

private struct TeamMapStatRow: View {
    let stat: V2TeamMapStat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(stat.map).font(.headline)
                Text("\(stat.played) played").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(stat.wins ?? 0)–\(stat.losses ?? 0)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if let rate = stat.winRate {
                    Text(TeamMapPercent.text(rate))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(rate >= 0.5 ? Color.green : Color.red)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            if let rate = stat.winRate {
                TeamMapBar(value: rate, tint: rate >= 0.5 ? .green : .red, height: 8)
            }
            if stat.attackRoundRate != nil || stat.defenseRoundRate != nil {
                HStack(spacing: 16) {
                    if let attack = stat.attackRoundRate {
                        sideBar(label: "ATK", value: attack, tint: .red)
                    }
                    if let defense = stat.defenseRoundRate {
                        sideBar(label: "DEF", value: defense, tint: .teal)
                    }
                }
            }
            if let sides = sideStartText {
                Text(sides).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func sideBar(label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(tint).frame(width: 28, alignment: .leading)
            TeamMapBar(value: value, tint: tint, height: 5)
            Text(TeamMapPercent.text(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    private var sideStartText: String? {
        let attack = stat.attackFirst ?? 0
        let defense = stat.defenseFirst ?? 0
        guard attack + defense > 0 else { return nil }
        return String(localized: "Started on attack \(attack)× · defense \(defense)×")
    }

    private var accessibilityText: String {
        var parts = [stat.map, "\(stat.played) maps played", "\(stat.wins ?? 0) wins, \(stat.losses ?? 0) losses"]
        if let rate = stat.winRate { parts.append("\(TeamMapPercent.text(rate)) win rate") }
        if let attack = stat.attackRoundRate { parts.append("attack rounds won \(TeamMapPercent.text(attack))") }
        if let defense = stat.defenseRoundRate { parts.append("defense rounds won \(TeamMapPercent.text(defense))") }
        return parts.joined(separator: ", ")
    }
}

private struct TeamMapBar: View {
    let value: Double
    let tint: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

enum TeamMapPercent {
    static func text(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Parses vlr.gg's "64%"; "-" (no games) gives nil.
    static func parse(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""),
              let number = Double(value) else { return nil }
        return number / 100
    }

    static func rate(won: Int?, lost: Int?, fallback: String?) -> Double? {
        let won = won ?? 0
        let lost = lost ?? 0
        if won + lost > 0 { return Double(won) / Double(won + lost) }
        return parse(fallback)
    }
}

private extension V2TeamMapStat {
    var played: Int { max(games ?? 0, (wins ?? 0) + (losses ?? 0)) }
    var winRate: Double? { TeamMapPercent.rate(won: wins, lost: losses, fallback: winPercent) }
    var attackRoundRate: Double? {
        TeamMapPercent.rate(won: attackRoundsWon, lost: attackRoundsLost, fallback: attackRoundWinPercent)
    }
    var defenseRoundRate: Double? {
        TeamMapPercent.rate(won: defenseRoundsWon, lost: defenseRoundsLost, fallback: defenseRoundWinPercent)
    }
}

// MARK: - Roster

private struct TeamGroupedRosterView: View {
    let roster: V2TeamGroupedRoster?

    private struct RosterGroup: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let members: [V2TeamRosterMember]
    }

    var body: some View {
        let groups = makeGroups()
        if groups.isEmpty {
            ProfileCard(title: "Roster", symbol: "person.3.fill") {
                ProfileEmptyState(title: "Roster unavailable", symbol: "person.3")
            }
        } else {
            ForEach(groups) { group in
                ProfileCard(title: group.title, symbol: group.symbol) {
                    ForEach(group.members, id: \.identityKey) { member in
                        TeamRosterMemberLink(member: member)
                    }
                }
            }
        }
    }

    /// vlr.gg's staff heading isn't always recognised by the scraper, so coaches and
    /// analysts can arrive in `active`; their role text moves them to Staff here.
    private func makeGroups() -> [RosterGroup] {
        let active = roster?.active ?? []
        let players = active.filter { !$0.isStaffMember && !$0.isSubstitute }
        let substitutes = active.filter { !$0.isStaffMember && $0.isSubstitute }
        let staff = active.filter(\.isStaffMember) + (roster?.staff ?? [])
        let candidates = [
            RosterGroup(id: "players", title: "Players", symbol: "person.3.fill", members: players),
            RosterGroup(id: "subs", title: "Substitutes & stand-ins", symbol: "person.badge.clock", members: substitutes),
            RosterGroup(id: "staff", title: "Staff", symbol: "person.text.rectangle", members: staff),
            RosterGroup(id: "benched", title: "Benched", symbol: "chair.lounge", members: roster?.benched ?? []),
            RosterGroup(id: "former", title: "Former", symbol: "clock.arrow.circlepath", members: roster?.former ?? []),
        ]
        return candidates.filter { !$0.members.isEmpty }
    }
}

/// A roster row that opens the member's profile when they have a player ID, staff
/// included (vlr.gg gives coaches and analysts player pages too).
struct TeamRosterMemberLink: View {
    let member: V2TeamRosterMember

    var body: some View {
        if let id = member.id.flatMap(Int.init) {
            NavigationLink {
                PlayerProfileView(playerID: id, name: member.alias, source: "team_profile")
            } label: {
                RosterRow(member: member, showsDisclosure: true, detail: tenure)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens player profile")
        } else {
            RosterRow(member: member, showsDisclosure: false, detail: tenure)
        }
    }

    private var tenure: String? {
        let joined = TeamFixtureSchedule.day(from: member.dateJoined)
        let left = TeamFixtureSchedule.day(from: member.dateLeft)
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        switch (joined, left) {
        case let (joined?, left?): return "\(joined.formatted(format)) – \(left.formatted(format))"
        case let (joined?, nil): return String(localized: "Joined \(joined.formatted(format))")
        case let (nil, left?): return String(localized: "Left \(left.formatted(format))")
        case (nil, nil): return nil
        }
    }
}

private extension V2TeamRosterMember {
    var lowercasedRole: String { role?.lowercased() ?? "" }

    var isStaffMember: Bool {
        isStaff == true
            || ["coach", "analyst", "manager", "staff", "performance", "psycholog"].contains {
                lowercasedRole.contains($0)
            }
    }

    var isSubstitute: Bool {
        ["sub", "stand-in", "stand in", "inactive", "reserve"].contains { lowercasedRole.contains($0) }
    }
}

// MARK: - Transfers

private struct TeamTransactionsCard: View {
    let transactions: [V2TeamTransaction]

    @State private var showsAll = false
    private static let collapsedCount = 25

    private struct Entry: Identifiable {
        let id: Int
        let transaction: V2TeamTransaction
        let day: Date?
    }

    private struct YearGroup: Identifiable {
        let id: String
        let title: String?
        let entries: [Entry]
    }

    var body: some View {
        let entries = transactions.enumerated().map { index, transaction in
            Entry(id: index, transaction: transaction, day: TeamFixtureSchedule.day(from: transaction.date))
        }
        let visible = showsAll ? entries : Array(entries.prefix(Self.collapsedCount))

        ProfileCard(title: "Roster moves", symbol: "arrow.left.arrow.right") {
            if entries.isEmpty {
                ProfileEmptyState(title: "No roster moves recorded", symbol: "arrow.left.arrow.right")
            } else {
                ForEach(groups(for: visible)) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        if let title = group.title {
                            Text(title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            TeamTransactionRow(
                                transaction: entry.transaction,
                                day: entry.day,
                                isLast: index == group.entries.count - 1
                            )
                        }
                    }
                }
                if entries.count > Self.collapsedCount {
                    Button(showsAll ? "Show fewer" : "Show all \(entries.count) moves") {
                        withAnimation(.snappy) { showsAll.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    /// Groups consecutive entries by year when they are dated; the feed is newest first.
    private func groups(for entries: [Entry]) -> [YearGroup] {
        guard entries.contains(where: { $0.day != nil }) else {
            return [YearGroup(id: "all", title: nil, entries: entries)]
        }
        var result: [YearGroup] = []
        for entry in entries {
            let title = entry.day.map { String(Calendar.current.component(.year, from: $0)) }
                ?? String(localized: "Undated")
            if let last = result.last, last.title == title {
                result[result.count - 1] = YearGroup(id: last.id, title: title, entries: last.entries + [entry])
            } else {
                result.append(YearGroup(id: "\(title)-\(entry.id)", title: title, entries: [entry]))
            }
        }
        return result
    }
}

private struct TeamTransactionRow: View {
    let transaction: V2TeamTransaction
    let day: Date?
    let isLast: Bool

    var body: some View {
        if let id = transaction.player?.id.flatMap(Int.init) {
            NavigationLink {
                PlayerProfileView(playerID: id, name: playerName, source: "team_profile")
            } label: {
                row(showsDisclosure: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens player profile")
        } else {
            row(showsDisclosure: false)
        }
    }

    private func row(showsDisclosure: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(kind.tint)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                Rectangle()
                    .fill(Color.primary.opacity(isLast ? 0 : 0.12))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let flag = countryFlag(transaction.player?.country) {
                        Text(flag).accessibilityHidden(true)
                    }
                    Text(playerName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(kind.title)
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(kind.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(kind.tint.opacity(0.14), in: Capsule())
                }
                let caption = [role, day?.formatted(.dateTime.day().month(.abbreviated).year())]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)

            Spacer(minLength: 0)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var playerName: String {
        transaction.player?.name.nilIfBlank ?? String(localized: "Unknown player")
    }

    /// The scraper can put the reference link where the position belongs; skip URLs.
    private var role: String? {
        guard let role = transaction.role.nilIfBlank,
              !role.lowercased().hasPrefix("http"),
              !role.contains("://") else { return nil }
        return role
    }

    private var kind: TeamTransactionKind { TeamTransactionKind(action: transaction.action) }

    private var accessibilityText: String {
        var parts = [playerName, kind.title]
        if let role { parts.append(role) }
        if let day { parts.append(day.formatted(date: .long, time: .omitted)) }
        return parts.joined(separator: ", ")
    }
}

private enum TeamTransactionKind {
    case joined, left, inactive, other(String)

    init(action: String?) {
        let action = action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if action.contains("join") || action.contains("sign") {
            self = .joined
        } else if action.contains("leave") || action.contains("left") || action.contains("release") || action.contains("depart") {
            self = .left
        } else if action.contains("inactive") || action.contains("bench") {
            self = .inactive
        } else {
            self = .other(action.isEmpty ? String(localized: "Move") : action.capitalized)
        }
    }

    var title: String {
        switch self {
        case .joined: String(localized: "Joined")
        case .left: String(localized: "Left")
        case .inactive: String(localized: "Inactive")
        case .other(let text): text
        }
    }

    var tint: Color {
        switch self {
        case .joined: .green
        case .left: .red
        case .inactive: .gray
        case .other: .secondary
        }
    }
}
