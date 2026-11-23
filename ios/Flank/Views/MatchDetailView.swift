//
//  MatchDetailView.swift
//  Flank
//

import EventKit
import FluidGradient
import SwiftUI

@MainActor
final class MatchDetailViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(V3MatchDetail, isStale: Bool)
        case failed(message: String, retryable: Bool)
    }

    @Published private(set) var state: State = .idle

    let matchID: Int
    private let repository: V3MatchDetailRepository

    init(matchID: Int, repository: V3MatchDetailRepository = .shared) {
        self.matchID = matchID
        self.repository = repository
    }

    func load(forceRefresh: Bool = false) async {
        if case .loaded = state {
            // Keep cached content visible while an explicit refresh is in flight.
        } else {
            state = .loading
        }

        do {
            let result = try await repository.detail(id: matchID, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            if result.isStale {
                Analytics.track(.offlineCachePresented(surface: "match_detail", category: nil))
            }
            state = .loaded(result.detail, isStale: result.isStale)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Analytics.track(
                .loadFailed(
                    surface: "match_detail",
                    category: AnalyticsErrorCategory(error),
                    retryable: (error as? VLRAPIError)?.isRetryable ?? true
                )
            )
            state = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                retryable: (error as? VLRAPIError)?.isRetryable ?? true
            )
        }
    }
}

struct MatchDetailView: View {
    private enum StreamProvider: String, CaseIterable, Identifiable {
        case twitch
        case youtube
        case other

        var id: Self { self }

        var title: String {
            switch self {
            case .twitch: "Twitch"
            case .youtube: "YouTube"
            case .other: "Other streams"
            }
        }

        var assetName: String? {
            switch self {
            case .twitch: "twitchLogo"
            case .youtube: "youtubeLogo"
            case .other: nil
            }
        }

        func contains(_ platform: String?) -> Bool {
            let platform = platform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            switch self {
            case .twitch:
                return platform.contains("twitch")
            case .youtube:
                return platform.contains("youtube") || platform == "yt"
            case .other:
                return !StreamProvider.twitch.contains(platform)
                    && !StreamProvider.youtube.contains(platform)
            }
        }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case maps = "Maps"
        case stats = "Stats"
        case rounds = "Rounds"
        case economy = "Economy"
        case history = "History"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .overview: "rectangle.grid.1x2"
            case .maps: "map"
            case .stats: "chart.bar.xaxis"
            case .rounds: "circle.grid.3x3"
            case .economy: "creditcard"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    @StateObject private var viewModel: MatchDetailViewModel
    @State private var selectedSection: Section = .overview
    @State private var reloadToken = 0
    @State private var showingCalendarAlert = false
    @State private var calendarAlertMessage = ""
    @State private var hasTrackedOpen = false
    @Namespace private var sectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let summary: V3Match?
    private let fallbackURL: String?
    private let analyticsSource: String

    init(match: V3Match, repository: V3MatchDetailRepository = .shared) {
        summary = match
        fallbackURL = match.url
        analyticsSource = match.source.rawValue
        _viewModel = StateObject(
            wrappedValue: MatchDetailViewModel(matchID: match.id, repository: repository)
        )
    }

    init(
        matchID: Int,
        fallbackURL: String? = nil,
        source: String = "direct",
        repository: V3MatchDetailRepository = .shared
    ) {
        summary = nil
        self.fallbackURL = fallbackURL
        analyticsSource = source
        _viewModel = StateObject(
            wrappedValue: MatchDetailViewModel(matchID: matchID, repository: repository)
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            content
        }
        .navigationTitle("Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let url = VLRAPI.pageURL(from: currentVLRURL) {
                    Link(destination: url) {
                        Label("View on VLR.GG", systemImage: "arrow.up.right.square")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        Analytics.track(
                            .externalLinkOpened(
                                destination: "vlr",
                                type: .match,
                                id: String(viewModel.matchID),
                                source: "match_detail"
                            )
                        )
                    })
                    .accessibilityHint("Opens the match on VLR.GG")
                }
            }
        }
        .task(id: "\(viewModel.matchID)-\(reloadToken)") {
            await viewModel.load()
        }
        .onAppear {
            guard !hasTrackedOpen else { return }
            hasTrackedOpen = true
            Analytics.track(
                .contentOpened(
                    type: .match,
                    id: String(viewModel.matchID),
                    source: analyticsSource,
                    matchState: summary?.status.rawValue
                )
            )
        }
        .alert("Calendar Access", isPresented: $showingCalendarAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarAlertMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            VStack(spacing: 16) {
                if let summary {
                    MatchHeroView(
                        status: summary.status,
                        startsAt: summary.startsAt,
                        teams: summary.teams,
                        event: summary.event,
                        games: [],
                        format: nil
                    )
                }
                ProgressView("Loading match details…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let message, let retryable):
            ContentUnavailableView {
                Label("Match unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                if retryable {
                    Button("Try Again") {
                        Analytics.track(.retryTapped(surface: "match_detail"))
                        reloadToken += 1
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .loaded(let detail, let isStale):
            loadedContent(detail: detail, isStale: isStale)
        }
    }

    private func loadedContent(detail: V3MatchDetail, isStale: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                MatchHeroView(
                    status: detail.status,
                    startsAt: detail.startsAt,
                    teams: detail.teams,
                    event: detail.event,
                    games: detail.games,
                    format: detail.format
                )

                SwiftUI.Section {
                    VStack(spacing: 16) {
                        if isStale {
                            Label(
                                "Showing a cached copy. Pull to retry when you’re online.",
                                systemImage: "icloud.slash"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("Offline. Showing cached match details.")
                        }

                        switch selectedSection {
                        case .overview:
                            overview(detail)
                        case .maps:
                            maps(detail)
                        case .stats:
                            stats(detail)
                        case .rounds:
                            rounds(detail)
                        case .economy:
                            economy(detail)
                        case .history:
                            history(detail)
                        }
                    }
                    .id(selectedSection)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                } header: {
                    sectionPicker(for: detail)
                }
            }
        }
        .refreshable { await viewModel.load(forceRefresh: true) }
        .onChange(of: availableSections(for: detail)) { _, sections in
            if !sections.contains(selectedSection) {
                selectedSection = .overview
            }
        }
    }

    private func availableSections(for detail: V3MatchDetail) -> [Section] {
        Section.allCases.filter { section in
            switch section {
            case .overview:
                true
            case .maps:
                !detail.games.isEmpty
            case .stats:
                detail.games.contains { !$0.players.team1.isEmpty || !$0.players.team2.isEmpty }
                    || !detail.performance.isEmpty
            case .rounds:
                detail.games.contains { !$0.rounds.isEmpty }
            case .economy:
                !detail.economy.isEmpty || detail.games.contains { !$0.economy.isEmpty }
            case .history:
                !detail.headToHead.isEmpty
            }
        }
    }

    private func sectionPicker(for detail: V3MatchDetail) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            sectionButtons(for: detail)
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // Opaque so content scrolling under the pinned chips doesn't show through.
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Match detail section")
    }

    private func sectionButtons(for detail: V3MatchDetail) -> some View {
        HStack(spacing: 8) {
            ForEach(availableSections(for: detail)) { section in
                let isSelected = selectedSection == section
                Button {
                    guard !isSelected else { return }
                    if reduceMotion {
                        selectedSection = section
                    } else {
                        withAnimation(.snappy(duration: 0.3)) { selectedSection = section }
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
                                    .matchedGeometryEffect(id: "selectedSection", in: sectionNamespace)
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
        .sensoryFeedback(.selection, trigger: selectedSection)
    }

    @ViewBuilder
    private func overview(_ detail: V3MatchDetail) -> some View {
        MatchDetailCard(title: "Overview", symbol: "info.circle") {
            MatchMetadataGrid(detail: detail)

            if let startsAt = detail.startsAt {
                Button {
                    addToCalendar(detail: detail, startsAt: startsAt)
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.orange)
                .accessibilityHint("Adds this match using its exact scheduled time")
            }
        }

        if !detail.streams.isEmpty || !detail.vods.isEmpty {
            MatchDetailCard(title: "Watch", symbol: "play.rectangle") {
                ForEach(StreamProvider.allCases) { provider in
                    let streams = detail.streams.filter { provider.contains($0.platform) }
                    if !streams.isEmpty {
                        streamDisclosure(provider: provider, streams: streams)
                    }
                }

                if !detail.vods.isEmpty {
                    vodDisclosure(detail.vods)
                }
            }
        }

        if let vetos = detail.mapVetos, !vetos.isEmpty {
            MatchDetailCard(title: "Map picks and vetoes", symbol: "checklist") {
                Text(vetos)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }

        if !detail.notes.isEmpty {
            MatchDetailCard(title: "Notes", symbol: "note.text") {
                ForEach(Array(detail.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func maps(_ detail: V3MatchDetail) -> some View {
        ForEach(detail.games) { game in
            MatchDetailCard(
                title: game.mapName ?? "Map \(game.number)",
                symbol: "map"
            ) {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.pick?.team.map { "Picked by \($0.name)" } ?? game.status.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let duration = game.duration {
                        Text(duration)
                            .font(.subheadline.monospacedDigit())
                    }
                }

                MapScoreView(game: game, teams: detail.teams)

                if game.sideScores.team1.attack != nil || game.sideScores.team2.attack != nil {
                    SideScoreGrid(sideScores: game.sideScores, teams: detail.teams)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(mapAccessibilityLabel(game, teams: detail.teams))
        }
    }

    @ViewBuilder
    private func stats(_ detail: V3MatchDetail) -> some View {
        ForEach(detail.games.filter { !$0.players.team1.isEmpty || !$0.players.team2.isEmpty }) { game in
            MatchDetailCard(
                title: game.mapName ?? "Map \(game.number)",
                symbol: "chart.bar.xaxis"
            ) {
                playerTeamStats(game.players.team1, team: detail.teams.first)
                playerTeamStats(game.players.team2, team: detail.teams.dropFirst().first)
            }
        }

        if !detail.performance.advancedStats.isEmpty {
            MatchDetailCard(title: "Performance", symbol: "bolt.fill") {
                ForEach(detail.performance.advancedStats, id: \.player.identityKey) { player in
                    AdvancedPerformanceRow(player: player)
                }
            }
        }

        if !detail.performance.killMatrix.isEmpty {
            MatchDetailCard(title: "Head-to-head performance", symbol: "person.2.fill") {
                ForEach(detail.performance.killMatrix, id: \.player.identityKey) { row in
                    DisclosureGroup(row.player.name) {
                        ForEach(row.matchups, id: \.opponent.identityKey) { matchup in
                            HStack {
                                Text(matchup.opponent.name)
                                Spacer()
                                Text(matchupLine(matchup))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func playerTeamStats(_ players: [V3MapPlayerStats], team: V3TeamRef?) -> some View {
        Group {
            if !players.isEmpty {
                Text(team?.name ?? players.first?.teamTag ?? "Team")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                ForEach(players, id: \.player.identityKey) { player in
                    PlayerStatsRow(player: player)
                }
            }
        }
    }

    @ViewBuilder
    private func rounds(_ detail: V3MatchDetail) -> some View {
        ForEach(detail.games.filter { !$0.rounds.isEmpty }) { game in
            MatchDetailCard(
                title: game.mapName ?? "Map \(game.number)",
                symbol: "circle.grid.3x3.fill"
            ) {
                ForEach(game.rounds) { round in
                    RoundRow(round: round, teams: detail.teams)
                    if round.number != game.rounds.last?.number {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func economy(_ detail: V3MatchDetail) -> some View {
        if !detail.economy.isEmpty {
            MatchDetailCard(title: "Match economy", symbol: "creditcard.fill") {
                ForEach(Array(detail.economy.enumerated()), id: \.offset) { _, row in
                    EconomyRowView(row: row, teams: detail.teams)
                }
            }
        }

        ForEach(detail.games.filter { !$0.economy.isEmpty }) { game in
            MatchDetailCard(
                title: "\(game.mapName ?? "Map \(game.number)") economy",
                symbol: "banknote"
            ) {
                ForEach(Array(game.economy.enumerated()), id: \.offset) { _, row in
                    EconomyRowView(row: row, teams: detail.teams)
                }
            }
        }
    }

    private func history(_ detail: V3MatchDetail) -> some View {
        MatchDetailCard(title: "Previous meetings", symbol: "clock.arrow.circlepath") {
            ForEach(detail.headToHead) { match in
                NavigationLink {
                    MatchDetailView(matchID: match.id, fallbackURL: match.url, source: "match_history")
                } label: {
                    HistoryRow(match: match)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func externalRow(
        name: String,
        detail: String,
        url: String,
        symbol: String,
        source: String
    ) -> some View {
        Group {
            if let destination = VLRAPI.pageURL(from: url) {
                Link(destination: destination) {
                    HStack {
                        Image(systemName: symbol)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(name)
                                .font(.body.weight(.semibold))
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    Analytics.track(
                        .externalLinkOpened(
                            destination: "media",
                            type: .match,
                            id: String(viewModel.matchID),
                            source: source
                        )
                    )
                })
                .accessibilityHint("Opens externally")
            }
        }
    }

    private func streamDisclosure(
        provider: StreamProvider,
        streams: [V3Stream]
    ) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(Array(streams.enumerated()), id: \.offset) { index, stream in
                    externalRow(
                        name: stream.name,
                        detail: stream.countryCode?.uppercased() ?? "",
                        url: stream.url,
                        symbol: "dot.radiowaves.left.and.right",
                        source: "stream"
                    )

                    if index < streams.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 12) {
                streamProviderIcon(provider)

                Text(provider.title)
                    .font(.body.weight(.semibold))

                Spacer()

                Text(streams.count, format: .number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.insetFill, in: Capsule())
                    .accessibilityLabel("\(streams.count) streams")
            }
            .frame(minHeight: 44)
        }
        .accessibilityHint("Expands to show \(provider.title) live streams")
    }

    @ViewBuilder
    private func streamProviderIcon(_ provider: StreamProvider) -> some View {
        if let assetName = provider.assetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "tv")
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func vodDisclosure(_ vods: [V3Vod]) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(Array(vods.enumerated()), id: \.offset) { index, vod in
                    externalRow(
                        name: vod.name,
                        detail: [vod.platform, vod.mapNumber.map { "Map \($0)" }]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        url: vod.url,
                        symbol: "play.square.stack",
                        source: "vod"
                    )

                    if index < vods.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.square.stack")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("VODs")
                    .font(.body.weight(.semibold))

                Spacer()

                Text(vods.count, format: .number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.insetFill, in: Capsule())
                    .accessibilityLabel("\(vods.count) videos")
            }
            .frame(minHeight: 44)
        }
        .accessibilityHint("Expands to show match videos")
    }

    private var currentVLRURL: String? {
        if case .loaded(let detail, _) = viewModel.state {
            return detail.url
        }
        return summary?.url ?? fallbackURL
    }

    private func mapAccessibilityLabel(_ game: V3Game, teams: [V3TeamRef]) -> String {
        let name = game.mapName ?? "Map \(game.number)"
        let first = teams.first?.name ?? "Team one"
        let second = teams.dropFirst().first?.name ?? "Team two"
        let score = "\(first) \(game.score.team1.map(String.init) ?? "score unavailable"), \(second) \(game.score.team2.map(String.init) ?? "score unavailable")"
        return "\(name), \(game.status.displayName), \(score)"
    }

    private func matchupLine(_ matchup: V3Matchup) -> String {
        let kills = matchup.kills.map(String.init) ?? "–"
        let deaths = matchup.deaths.map(String.init) ?? "–"
        let differential = matchup.differential.map { $0 >= 0 ? "+\($0)" : String($0) } ?? "–"
        return "\(kills)–\(deaths) (\(differential))"
    }

    private func addToCalendar(detail: V3MatchDetail, startsAt: Date) {
        Task { await saveToCalendar(detail: detail, startsAt: startsAt) }
    }

    private func saveToCalendar(detail: V3MatchDetail, startsAt: Date) async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            break
        case .notDetermined:
            do {
                // Asks on a throwaway store; access is per app, so the store below can save.
                guard try await EKEventStore().requestWriteOnlyAccessToEvents() else {
                    showCalendarAlert("Calendar access was denied.")
                    return
                }
            } catch {
                showCalendarAlert(error.localizedDescription)
                return
            }
        case .restricted, .denied:
            showCalendarAlert("Calendar access is restricted or denied. Please check Settings.")
            return
        @unknown default:
            showCalendarAlert("Calendar access is unavailable.")
            return
        }

        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        let teamNames = detail.teams.map(\.name)
        event.title = teamNames.count == 2
            ? "\(teamNames[0]) vs \(teamNames[1])"
            : detail.event.name
        event.startDate = startsAt
        event.endDate = startsAt.addingTimeInterval(2 * 60 * 60)
        event.calendar = eventStore.defaultCalendarForNewEvents
        event.url = VLRAPI.pageURL(from: detail.url)

        do {
            try eventStore.save(event, span: .thisEvent)
            showCalendarAlert("Event added to calendar successfully!")
        } catch {
            showCalendarAlert("Failed to save event: \(error.localizedDescription)")
        }
    }

    private func showCalendarAlert(_ message: String) {
        calendarAlertMessage = message
        showingCalendarAlert = true
    }
}

private struct MatchDetailCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: MatchCardMetrics.cornerRadius, style: .continuous)
        )
    }
}

private struct MatchHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let status: V3MatchStatus
    let startsAt: Date?
    let teams: [V3TeamRef]
    let event: V3EventRef
    let games: [V3Game]
    let format: String?

    private static let leadingFallback = Color(red: 0.32, green: 0.16, blue: 0.42)
    private static let trailingFallback = Color(red: 0.55, green: 0.24, blue: 0.08)

    @State private var leadingColor: Color
    @State private var trailingColor: Color
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 46

    init(
        status: V3MatchStatus,
        startsAt: Date?,
        teams: [V3TeamRef],
        event: V3EventRef,
        games: [V3Game],
        format: String?
    ) {
        self.status = status
        self.startsAt = startsAt
        self.teams = teams
        self.event = event
        self.games = games
        self.format = format
        // The loading and loaded states each build a hero; starting from already-sampled
        // colours keeps the second one from flashing the fallback.
        _leadingColor = State(initialValue: HeroColorSampler.color(
            LogoColorSampler.cachedColors(for: teams.first?.image.preferred(for: .dark)),
            fallback: Self.leadingFallback
        ))
        _trailingColor = State(initialValue: HeroColorSampler.color(
            LogoColorSampler.cachedColors(for: teams.dropFirst().first?.image.preferred(for: .dark)),
            fallback: Self.trailingFallback
        ))
    }

    private var firstTeamLogo: String? {
        teams.first?.image.preferred(for: .dark)
    }

    private var secondTeamLogo: String? {
        teams.dropFirst().first?.image.preferred(for: .dark)
    }

    var body: some View {
        VStack(spacing: 22) {
            header

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    team(teams.first, position: 0)
                    scoreSummary
                    team(teams.dropFirst().first, position: 1)
                }

                VStack(spacing: 18) {
                    scoreSummary
                    HStack(alignment: .top, spacing: 16) {
                        team(teams.first, position: 0)
                        team(teams.dropFirst().first, position: 1)
                    }
                }

                VStack(spacing: 18) {
                    scoreSummary
                    team(teams.first, position: 0)
                    team(teams.dropFirst().first, position: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .background { surface }
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        // Always dark, like the live card, so the team colours read the same in both appearances.
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Match summary")
        .task(id: "\(firstTeamLogo ?? "")|\(secondTeamLogo ?? "")") {
            async let first = LogoColorSampler.colors(for: firstTeamLogo)
            async let second = LogoColorSampler.colors(for: secondTeamLogo)
            let sampled = await (first, second)
            guard !Task.isCancelled else { return }
            let colors = (
                HeroColorSampler.color(sampled.0, fallback: Self.leadingFallback),
                HeroColorSampler.color(sampled.1, fallback: Self.trailingFallback)
            )
            guard colors.0 != leadingColor || colors.1 != trailingColor else { return }

            if reduceMotion {
                leadingColor = colors.0
                trailingColor = colors.1
            } else {
                withAnimation(.easeInOut(duration: 0.45)) {
                    leadingColor = colors.0
                    trailingColor = colors.1
                }
            }
        }
    }

    private static let cornerRadius: CGFloat = 28

    private var surface: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.065)

            FluidGradient(
                blobs: [leadingColor, trailingColor],
                highlights: [leadingColor, trailingColor, trailingColor, leadingColor],
                speed: reduceMotion ? 0 : 0.22,
                blur: 0.82
            )
            .opacity(0.68)

            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AsyncImage(url: VLRAPI.imageURL(from: event.image.preferred(for: .dark))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "trophy.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if !eventDetail.isEmpty {
                    Text(eventDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            statusBadge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if status == .live {
            LiveBadge()
        } else {
            Text(status == .completed ? "Final" : status.displayName)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1), in: Capsule())
        }
    }

    @ViewBuilder
    private func team(_ team: V3TeamRef?, position: Int) -> some View {
        if let team, let teamID = team.id {
            NavigationLink {
                TeamProfileView(
                    teamID: teamID,
                    name: team.name,
                    logo: team.image.preferred(for: .dark),
                    source: "match_detail"
                )
            } label: {
                teamContent(team, position: position)
            }
            .buttonStyle(MatchCardButtonStyle())
            .accessibilityHint("Opens team profile")
        } else {
            teamContent(team, position: position)
        }
    }

    private func teamContent(_ team: V3TeamRef?, position: Int) -> some View {
        VStack(spacing: 10) {
            AsyncImage(url: VLRAPI.imageURL(from: team?.image.preferred(for: .dark))) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Image(systemName: "shield.lefthalf.filled")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(team?.name ?? "TBD")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                if let teamLabel = teamLabel(team) {
                    Text(teamLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(loserPosition == position ? 0.5 : 1)
        .contentShape(.rect)
    }

    private var scoreSummary: some View {
        VStack(spacing: 6) {
            if teams.first?.score == nil && teams.dropFirst().first?.score == nil {
                Text("VS")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    scoreText(teams.first?.score, position: 0)
                    Text("–")
                        .foregroundStyle(.tertiary)
                    scoreText(teams.dropFirst().first?.score, position: 1)
                }
                .font(.system(size: scoreSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            }

            Text(matchContext)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private func scoreText(_ value: Int?, position: Int) -> some View {
        Text(value.map(String.init) ?? "–")
            .foregroundStyle(loserPosition == position ? .secondary : .primary)
    }

    /// The non-winning slot of a completed match, faded back rather than badging the winner.
    private var loserPosition: Int? {
        guard status == .completed else { return nil }
        switch (teams.first?.isWinner == true, teams.dropFirst().first?.isWinner == true) {
        case (true, false): return 1
        case (false, true): return 0
        default: return nil
        }
    }

    private func teamLabel(_ team: V3TeamRef?) -> String? {
        guard let team else { return nil }
        let values = [team.tag, team.region]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var matchContext: String {
        if status == .scheduled, let startsAt {
            return startsAt.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            )
        }

        let activeGame = games.first(where: { $0.status == .inProgress })
            ?? games.last(where: { $0.status == .completed })

        if let activeGame {
            return ["Map \(activeGame.number)", activeGame.mapName]
                .compactMap { $0 }
                .joined(separator: " · ")
        }

        if let format, !format.isEmpty {
            return format
        }

        return status.displayName
    }

    private var eventDetail: String {
        [event.stage, event.series]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var heroAccessibilityLabel: String {
        let first = teams.first
        let second = teams.dropFirst().first
        let matchup = "\(first?.name ?? "Team one") versus \(second?.name ?? "Team two")"
        let score = if let firstScore = first?.score, let secondScore = second?.score {
            ", score \(firstScore) to \(secondScore)"
        } else {
            ""
        }
        let date = startsAt.map { ", starts \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        let winner = teams.first(where: \.isWinner).map { ", winner \($0.name)" } ?? ""
        return "\(status.displayName), \(matchup)\(score)\(winner)\(date), \(event.name)"
    }
}

private enum HeroColorSampler {
    /// The first reasonably saturated logo colour, clamped so white hero text stays readable.
    static func color(_ colors: LogoColors?, fallback: Color) -> Color {
        let candidates = [colors?.background, colors?.primary, colors?.secondary, colors?.detail]
            .compactMap { $0 }

        for candidate in candidates {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            guard candidate.getHue(
                &hue,
                saturation: &saturation,
                brightness: &brightness,
                alpha: &alpha
            ), saturation >= 0.12 else {
                continue
            }

            return Color(
                uiColor: UIColor(
                    hue: hue,
                    saturation: min(max(saturation, 0.38), 0.72),
                    brightness: min(max(brightness, 0.34), 0.62),
                    alpha: 1
                )
            )
        }

        return fallback
    }
}

private struct MatchMetadataGrid: View {
    let detail: V3MatchDetail

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            metadata("Event", detail.event.name)
            if let stage = detail.event.stage { metadata("Stage", stage) }
            if let series = detail.event.series { metadata("Series", series) }
            if let format = detail.format { metadata("Format", format) }
            if let patch = detail.patch { metadata("Patch", patch) }
            metadata("Status", detail.status.displayName)
            if let startsAt = detail.startsAt {
                metadata("Starts", startsAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct MapScoreView: View {
    let game: V3Game
    let teams: [V3TeamRef]

    var body: some View {
        HStack(spacing: 12) {
            Text(teams.first?.name ?? "Team 1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(winner == 2 ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(game.score.team1.map(String.init) ?? "–")
                    .foregroundStyle(winner == 2 ? .secondary : .primary)
                Text("–")
                    .foregroundStyle(.tertiary)
                Text(game.score.team2.map(String.init) ?? "–")
                    .foregroundStyle(winner == 1 ? .secondary : .primary)
            }
            .font(.system(.title, design: .rounded, weight: .bold))
            .monospacedDigit()
            .fixedSize()

            Text(teams.dropFirst().first?.name ?? "Team 2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(winner == 1 ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// 1 or 2 once a finished map has a higher score on one side.
    private var winner: Int? {
        guard game.status == .completed,
              let first = game.score.team1, let second = game.score.team2,
              first != second else { return nil }
        return first > second ? 1 : 2
    }
}

private struct SideScoreGrid: View {
    let sideScores: V3MapSideScores
    let teams: [V3TeamRef]

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text("")
                    .gridColumnAlignment(.leading)
                Text("ATK")
                Text("DEF")
                Text("OT")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            sideRow(teams.first?.name ?? "Team 1", sideScores.team1)
            sideRow(teams.dropFirst().first?.name ?? "Team 2", sideScores.team2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attack, defense, and overtime score splits")
    }

    private func sideRow(_ name: String, _ score: V3TeamSideScore) -> some View {
        GridRow {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            scoreCell(score.attack)
            scoreCell(score.defense)
            scoreCell(score.overtime)
        }
    }

    private func scoreCell(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "–")
            .font(.subheadline.monospacedDigit())
    }
}

private struct PlayerStatsRow: View {
    let player: V3MapPlayerStats

    var body: some View {
        Group {
            if let playerID = player.player.id {
                NavigationLink {
                    PlayerProfileView(
                        playerID: playerID,
                        name: player.player.name,
                        source: "match_detail"
                    )
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens player profile")
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.player.name)
                        .font(.body.weight(.bold))
                    if let agent = player.agent {
                        Text(agent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let country = player.countryCode {
                    Text(country.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    stat("Rating", player.rating)
                    stat("ACS", player.averageCombatScore, decimals: 0)
                    stat("K / D / A", kda)
                    stat("KAST", percent(player.kastPercent))
                    stat("ADR", player.averageDamagePerRound, decimals: 0)
                    stat("HS", percent(player.headshotPercent))
                    stat("FK / FD", firsts)
                }
            }
        }
        .padding(12)
        .background(.insetFill, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var kda: String? {
        guard player.kills != nil || player.deaths != nil || player.assists != nil else { return nil }
        return "\(player.kills.map(String.init) ?? "–") / \(player.deaths.map(String.init) ?? "–") / \(player.assists.map(String.init) ?? "–")"
    }

    private var firsts: String? {
        guard player.firstKills != nil || player.firstDeaths != nil else { return nil }
        return "\(player.firstKills.map(String.init) ?? "–") / \(player.firstDeaths.map(String.init) ?? "–")"
    }

    private func percent(_ value: Double?) -> String? {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }
    }

    private func stat(_ label: String, _ value: Double?, decimals: Int = 2) -> some View {
        stat(
            label,
            value.map { $0.formatted(.number.precision(.fractionLength(0...decimals))) }
        )
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit())
        }
        .frame(minHeight: 36)
    }

    private var accessibilitySummary: String {
        [
            player.player.name,
            player.agent.map { "agent \($0)" },
            player.rating.map { "rating \($0)" },
            player.averageCombatScore.map { "average combat score \($0)" },
            kda.map { "kills deaths assists \($0)" },
            percent(player.kastPercent).map { "KAST \($0)" },
            player.averageDamagePerRound.map { "average damage per round \($0)" },
            percent(player.headshotPercent).map { "headshots \($0)" },
            firsts.map { "first kills and deaths \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct AdvancedPerformanceRow: View {
    let player: V3AdvancedPlayerStats

    var body: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                performanceRow("Multi-kills", multiKills)
                performanceRow("Clutches", clutches)
                if let rating = player.economyRating {
                    performanceRow("Economy rating", String(rating))
                }
                if player.plants != nil || player.defuses != nil {
                    performanceRow(
                        "Plants / defuses",
                        "\(player.plants.map(String.init) ?? "–") / \(player.defuses.map(String.init) ?? "–")"
                    )
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(player.player.name)
                    .font(.body.weight(.semibold))
                if let agent = player.agent {
                    Text(agent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var multiKills: String {
        [
            player.multiKills.two.map { "2K \($0)" },
            player.multiKills.three.map { "3K \($0)" },
            player.multiKills.four.map { "4K \($0)" },
            player.multiKills.five.map { "5K \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var clutches: String {
        [
            player.clutches.oneVsOne.map { "1v1 \($0)" },
            player.clutches.oneVsTwo.map { "1v2 \($0)" },
            player.clutches.oneVsThree.map { "1v3 \($0)" },
            player.clutches.oneVsFour.map { "1v4 \($0)" },
            player.clutches.oneVsFive.map { "1v5 \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func performanceRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "–" : value)
                .font(.subheadline.monospacedDigit())
        }
    }
}

private struct RoundRow: View {
    let round: V3Round
    let teams: [V3TeamRef]

    var body: some View {
        HStack(spacing: 12) {
            Text(String(round.number))
                .font(.caption.bold().monospacedDigit())
                .frame(width: 28, height: 28)
                .background(.insetFill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(winnerName)
                    .font(.subheadline.weight(.semibold))
                Text([round.side.displayName, round.method].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(round.scoreAfter.team1.map(String.init) ?? "–") – \(round.scoreAfter.team2.map(String.init) ?? "–")")
                .font(.subheadline.bold().monospacedDigit())
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Round \(round.number), \(outcomeDescription), \(round.method ?? "method unavailable"), score \(round.scoreAfter.team1.map(String.init) ?? "unavailable") to \(round.scoreAfter.team2.map(String.init) ?? "unavailable")"
        )
    }

    private var outcomeDescription: String {
        guard round.winner != .unknown else { return "winner unavailable" }
        guard let side = round.side.displayName else { return "\(winnerName) won" }
        return "\(winnerName) won on \(side.lowercased())"
    }

    private var winnerName: String {
        switch round.winner {
        case .team1: teams.first?.name ?? "Team one"
        case .team2: teams.dropFirst().first?.name ?? "Team two"
        case .unknown: "Winner unavailable"
        }
    }
}

private struct EconomyRowView: View {
    let row: V3EconomyRow
    let teams: [V3TeamRef]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(teamName)
                    .font(.headline)
                Spacer()
                if let pistolWins = row.pistolWins {
                    Text("Pistols \(pistolWins)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Rounds")
                    Text("Wins")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                bucket("Eco", row.eco)
                bucket("Low", row.low)
                bucket("Medium", row.medium)
                bucket("Full", row.full)
            }
        }
        .padding(12)
        .background(.insetFill, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Economy for \(teamName)")
    }

    private var teamName: String {
        teams.first(where: { $0.id != nil && $0.id == row.teamID })?.name
            ?? row.teamTag
            ?? "Team"
    }

    private func bucket(_ name: String, _ bucket: V3EconomyBucket) -> some View {
        GridRow {
            Text(name)
            Text(bucket.rounds.map(String.init) ?? "–")
                .monospacedDigit()
            Text(bucket.wins.map(String.init) ?? "–")
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

private struct HistoryRow: View {
    let match: V3HeadToHead

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(match.teams.map(\.name).joined(separator: " vs "))
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text([match.eventName, match.eventSeries, match.dateText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Text("\(match.score.team1.map(String.init) ?? "–") – \(match.score.team2.map(String.init) ?? "–")")
                .font(.headline.monospacedDigit())
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(match.teams.map(\.name).joined(separator: " versus ")), score \(match.score.team1.map(String.init) ?? "unavailable") to \(match.score.team2.map(String.init) ?? "unavailable"), \(match.eventName ?? "event unavailable")"
        )
    }
}

private extension ShapeStyle where Self == Color {
    /// Fill for rows nested inside a section card.
    static var insetFill: Color { Color(uiColor: .tertiarySystemGroupedBackground) }
}

private extension V3GameStatus {
    var displayName: String {
        switch self {
        case .scheduled: "Scheduled"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .unknown: "Status unavailable"
        }
    }
}

private extension V3Side {
    /// Side label for display; `nil` when the API sent a side the app doesn't know.
    var displayName: String? {
        switch self {
        case .attack: "Attack"
        case .defense: "Defense"
        case .unknown: nil
        }
    }
}
