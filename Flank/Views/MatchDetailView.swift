//
//  MatchDetailView.swift
//  Flank
//

import EventKit
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
            state = .loaded(result.detail, isStale: result.isStale)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
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

    private let summary: V3Match?
    private let fallbackURL: String?

    init(match: V3Match, repository: V3MatchDetailRepository = .shared) {
        summary = match
        fallbackURL = match.url
        _viewModel = StateObject(
            wrappedValue: MatchDetailViewModel(matchID: match.id, repository: repository)
        )
    }

    init(matchID: Int, fallbackURL: String? = nil, repository: V3MatchDetailRepository = .shared) {
        summary = nil
        self.fallbackURL = fallbackURL
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
                    .accessibilityHint("Opens the match on VLR.GG")
                }
            }
        }
        .task(id: "\(viewModel.matchID)-\(reloadToken)") {
            await viewModel.load(forceRefresh: reloadToken > 0)
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
                        event: summary.event
                    )
                    .padding(.horizontal)
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
                    Button("Try Again") { reloadToken += 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .loaded(let detail, let isStale):
            loadedContent(detail: detail, isStale: isStale)
        }
    }

    private func loadedContent(detail: V3MatchDetail, isStale: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if isStale {
                    Label(
                        "Showing a cached copy. Pull to retry when you’re online.",
                        systemImage: "icloud.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Offline. Showing cached match details.")
                }

                MatchHeroView(
                    status: detail.status,
                    startsAt: detail.startsAt,
                    teams: detail.teams,
                    event: detail.event
                )

                sectionPicker(for: detail)

                Group {
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
            }
            .padding()
        }
        .refreshable { reloadToken += 1 }
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
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    sectionButtons(for: detail, useGlass: true)
                }
            } else {
                sectionButtons(for: detail, useGlass: false)
            }
        }
        .accessibilityLabel("Match detail section")
    }

    private func sectionButtons(for detail: V3MatchDetail, useGlass: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(availableSections(for: detail)) { section in
                Button {
                    withAnimation(.snappy) { selectedSection = section }
                } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedSection == section ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(.capsule)
                }
                .modifier(SectionButtonSurface(selected: selectedSection == section, useGlass: useGlass))
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
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
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
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
                ForEach(detail.notes, id: \.self) { note in
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
                    .accessibilityLabel("\(row.player.name) matchup performance")
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
                ForEach(detail.economy, id: \.identityKey) { row in
                    EconomyRowView(row: row, teams: detail.teams)
                }
            }
        }

        ForEach(detail.games.filter { !$0.economy.isEmpty }) { game in
            MatchDetailCard(
                title: "\(game.mapName ?? "Map \(game.number)") economy",
                symbol: "banknote"
            ) {
                ForEach(game.economy, id: \.identityKey) { row in
                    EconomyRowView(row: row, teams: detail.teams)
                }
            }
        }
    }

    private func history(_ detail: V3MatchDetail) -> some View {
        MatchDetailCard(title: "Previous meetings", symbol: "clock.arrow.circlepath") {
            ForEach(detail.headToHead) { match in
                NavigationLink {
                    MatchDetailView(matchID: match.id, fallbackURL: match.url)
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
        symbol: String
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
                ForEach(streams) { stream in
                    externalRow(
                        name: stream.name,
                        detail: stream.countryCode?.uppercased() ?? "",
                        url: stream.url,
                        symbol: "dot.radiowaves.left.and.right"
                    )

                    if stream.id != streams.last?.id {
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
                    .background(.thinMaterial, in: Capsule())
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
                ForEach(vods) { vod in
                    externalRow(
                        name: vod.name,
                        detail: [vod.platform, vod.mapNumber.map { "Map \($0)" }]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        url: vod.url,
                        symbol: "play.square.stack"
                    )

                    if vod.id != vods.last?.id {
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
                    .background(.thinMaterial, in: Capsule())
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
        let eventStore = EKEventStore()

        func save() {
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
                calendarAlertMessage = "Event added to calendar successfully!"
            } catch {
                calendarAlertMessage = "Failed to save event: \(error.localizedDescription)"
            }
            showingCalendarAlert = true
        }

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            save()
        case .notDetermined:
            eventStore.requestWriteOnlyAccessToEvents { granted, error in
                Task { @MainActor in
                    if granted {
                        save()
                    } else {
                        calendarAlertMessage = error?.localizedDescription
                            ?? "Calendar access was denied."
                        showingCalendarAlert = true
                    }
                }
            }
        case .restricted, .denied:
            calendarAlertMessage = "Calendar access is restricted or denied. Please check Settings."
            showingCalendarAlert = true
        @unknown default:
            calendarAlertMessage = "Calendar access is unavailable."
            showingCalendarAlert = true
        }
    }
}

private struct SectionButtonSurface: ViewModifier {
    let selected: Bool
    let useGlass: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), useGlass {
            content
                .glassEffect(
                    .regular
                        .tint(selected ? Color.accentColor.opacity(0.45) : nil)
                        .interactive(),
                    in: .capsule
                )
        } else {
            content
                .background(
                    selected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08),
                    in: Capsule()
                )
        }
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
            Label(title, systemImage: symbol)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct MatchHeroView: View {
    @Environment(\.colorScheme) private var colorScheme

    let status: V3MatchStatus
    let startsAt: Date?
    let teams: [V3TeamRef]
    let event: V3EventRef

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                statusLabel
                if let startsAt {
                    Text(startsAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                        .font(.subheadline.weight(.semibold))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    team(teams.first)
                    score
                    team(teams.dropFirst().first)
                }
                VStack(spacing: 14) {
                    team(teams.first)
                    score
                    team(teams.dropFirst().first)
                }
            }

            VStack(spacing: 3) {
                Text(event.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text([event.stage, event.series].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background {
            ZStack {
                LinearGradient(
                    colors: [.indigo.opacity(0.35), .orange.opacity(0.18), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .background(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var statusLabel: some View {
        Text(status.displayName.uppercased())
            .font(.caption.weight(.black))
            .foregroundStyle(status == .live ? .red : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }

    private func team(_ team: V3TeamRef?) -> some View {
        VStack(spacing: 8) {
            AsyncImage(url: VLRAPI.imageURL(from: team?.image.preferred(for: colorScheme))) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Image(systemName: "person.2.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            HStack(spacing: 5) {
                Text(team?.name ?? "Team unavailable")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if team?.isWinner == true {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var score: some View {
        HStack(spacing: 7) {
            Text(teams.first?.score.map(String.init) ?? "–")
            Text(teams.first?.score == nil && teams.dropFirst().first?.score == nil ? "VS" : "–")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(teams.dropFirst().first?.score.map(String.init) ?? "–")
        }
        .font(.largeTitle.bold().monospacedDigit())
        .fixedSize()
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
        HStack {
            Text(teams.first?.name ?? "Team 1")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(game.score.team1.map(String.init) ?? "–")
                .font(.title2.bold().monospacedDigit())
            Text("–")
                .foregroundStyle(.secondary)
            Text(game.score.team2.map(String.init) ?? "–")
                .font(.title2.bold().monospacedDigit())
            Text(teams.dropFirst().first?.name ?? "Team 2")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct SideScoreGrid: View {
    let sideScores: V3MapSideScores
    let teams: [V3TeamRef]

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text("")
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
                HStack(spacing: 8) {
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
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
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
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
        }
        .accessibilityLabel("Performance for \(player.player.name)")
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
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(winnerName)
                    .font(.subheadline.weight(.semibold))
                Text([round.side.rawValue.capitalized, round.method].compactMap { $0 }.joined(separator: " · "))
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
            "Round \(round.number), \(winnerName) won on \(round.side.rawValue), \(round.method ?? "method unavailable"), score \(round.scoreAfter.team1.map(String.init) ?? "unavailable") to \(round.scoreAfter.team2.map(String.init) ?? "unavailable")"
        )
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
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
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
