//
//  EventDetailView.swift
//  Flank
//

import SwiftUI

struct EventDetailView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case overview
        case stages
        case matches
        case stats

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .stages: "Stages"
            case .matches: "Matches"
            case .stats: "Stats"
            }
        }
    }

    @StateObject private var viewModel: EventDetailViewModel
    @State private var selectedSection: Section = .overview
    /// A stage picked by the user; `nil` shows the stage the overview came with.
    @State private var selectedStage: String?
    @State private var reloadToken = 0

    private let eventID: Int
    private let fallbackName: String
    private let fallbackLogo: String?

    init(eventID: Int, name: String, logo: String?) {
        self.eventID = eventID
        fallbackName = name
        fallbackLogo = logo
        _viewModel = StateObject(wrappedValue: EventDetailViewModel(eventID: eventID))
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 16) {
                    EventHeaderCard(
                        detail: viewModel.detail,
                        fallbackName: fallbackName,
                        fallbackLogo: fallbackLogo
                    )

                    Picker("Event section", selection: $selectedSection) {
                        ForEach(Section.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)

                    sectionContent
                }
                .padding()
                .padding(.bottom, 24)
            }
            .refreshable { await refresh() }
            // Match rows take missing logos from the event's own team lists before
            // asking the API for each match.
            .environment(\.teamLogoDirectory, viewModel.teamLogoDirectory)
        }
        .navigationTitle(viewModel.detail?.name ?? fallbackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let url = VLRAPI.pageURL(from: viewModel.detail?.url ?? "/event/\(eventID)") {
                    Link(destination: url) {
                        Label("View on VLR.GG", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
        .task(id: reloadToken) {
            await viewModel.fetchDetail()
        }
        .task(id: "\(selectedSection.rawValue)-\(reloadToken)") {
            switch selectedSection {
            case .matches: await viewModel.fetchMatches()
            case .stats: await viewModel.fetchStats()
            case .overview, .stages: break
            }
        }
        .task(id: "\(selectedStage ?? "")-\(reloadToken)") {
            guard let selectedStage else { return }
            await viewModel.fetchStage(selectedStage)
        }
    }

    private func refresh() async {
        async let detail: Void = viewModel.fetchDetail()
        switch selectedSection {
        case .overview:
            break
        case .stages:
            if let selectedStage {
                await viewModel.fetchStage(selectedStage, force: true)
            }
        case .matches:
            await viewModel.fetchMatches(force: true)
        case .stats:
            await viewModel.fetchStats(force: true)
        }
        await detail
    }

    // MARK: Sections

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .overview:
            detailGate { detail in
                EventOverviewSection(detail: detail)
            }
        case .stages:
            detailGate { detail in
                stagesSection(detail)
            }
        case .matches:
            EventMatchesSection(
                matches: viewModel.matches,
                state: viewModel.matchesState
            ) {
                Task { await viewModel.fetchMatches(force: true) }
            }
        case .stats:
            EventStatsSection(
                players: viewModel.stats,
                state: viewModel.statsState
            ) {
                Task { await viewModel.fetchStats(force: true) }
            }
        }
    }

    /// Shows the overview's load state until there's a detail to build the section from.
    @ViewBuilder
    private func detailGate<Content: View>(@ViewBuilder content: (V3EventDetail) -> Content) -> some View {
        if let detail = viewModel.detail {
            if case .showingSaved(let message, let isOffline) = viewModel.detailState {
                SavedDataBanner(
                    offlineText: "Offline — showing saved event",
                    failedText: "Couldn’t refresh — showing saved event",
                    message: message,
                    isOffline: isOffline
                )
            }
            content(detail)
        } else {
            switch viewModel.detailState {
            case .failed(let message, let retryable):
                ListFailureView(title: "Event unavailable", message: message, retryable: retryable) {
                    reloadToken += 1
                }
            default:
                ProgressView("Loading event…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
    }

    private var currentStageSlug: String? {
        selectedStage ?? viewModel.defaultStageSlug
    }

    @ViewBuilder
    private func stagesSection(_ detail: V3EventDetail) -> some View {
        let stages = detail.stages
        if stages.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stages) { stage in
                        stageChip(stage)
                    }
                }
            }
            .scrollClipDisabled()
        }

        if let selectedStage, selectedStage != viewModel.defaultStageSlug {
            if let stageDetail = viewModel.stageDetails[selectedStage] {
                if case .showingSaved(let message, let isOffline) = viewModel.stageStates[selectedStage] {
                    SavedDataBanner(
                        offlineText: "Offline — showing saved stage",
                        failedText: "Couldn’t refresh — showing saved stage",
                        message: message,
                        isOffline: isOffline
                    )
                }
                EventStageContent(detail: stageDetail)
            } else if case .failed(let message, let retryable) = viewModel.stageStates[selectedStage] {
                ListFailureView(title: "Stage unavailable", message: message, retryable: retryable) {
                    reloadToken += 1
                }
            } else {
                ProgressView("Loading stage…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        } else {
            EventStageContent(detail: detail)
        }
    }

    private func stageChip(_ stage: V3EventStage) -> some View {
        let isSelected = stage.slug != nil && stage.slug == currentStageSlug
        return Button {
            guard let slug = stage.slug, slug != currentStageSlug else { return }
            selectedStage = slug == viewModel.defaultStageSlug ? nil : slug
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.name)
                    .font(.subheadline.weight(.semibold))
                if let dates = stage.dateText?.nilIfBlank {
                    Text(dates)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(isSelected ? Color.accentColor.opacity(0.25) : nil).interactive(),
            in: .capsule
        )
        .disabled(stage.slug == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Header

private struct EventHeaderCard: View {
    let detail: V3EventDetail?
    let fallbackName: String
    let fallbackLogo: String?

    var body: some View {
        VStack(spacing: 12) {
            EventLogo(image: detail?.image ?? .emptyValue, fallback: fallbackLogo, size: 76)

            VStack(spacing: 4) {
                Text(detail?.name ?? fallbackName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                if let series = detail?.series?.nilIfBlank, series != detail?.name {
                    Text(series)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let detail {
                let facts = facts(for: detail)
                if !facts.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(facts, id: \.title) { fact in
                            factTile(fact)
                        }
                    }
                }

                if let subtitle = detail.subtitle?.nilIfBlank {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private struct Fact {
        let title: String
        let value: String
        let symbol: String
    }

    private func facts(for detail: V3EventDetail) -> [Fact] {
        var facts: [Fact] = []
        if let dates = detail.dateText?.nilIfBlank {
            facts.append(Fact(title: String(localized: "Dates"), value: dates, symbol: "calendar"))
        }
        if let prize = detail.prize.displayText {
            facts.append(Fact(title: String(localized: "Prize pool"), value: prize, symbol: "dollarsign.circle"))
        }
        if let location = detail.location?.nilIfBlank {
            let flag = countryFlag(detail.regionCode).map { "\($0) " } ?? ""
            facts.append(Fact(title: String(localized: "Location"), value: flag + location, symbol: "mappin.and.ellipse"))
        }
        return facts
    }

    private func factTile(_ fact: Fact) -> some View {
        VStack(spacing: 4) {
            Image(systemName: fact.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(fact.value)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Text(fact.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

private struct EventCard<Content: View>: View {
    let title: Text
    var trailing: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Pushes the team's profile when it has an ID; otherwise just shows the content.
private struct EventTeamLink<Content: View>: View {
    let team: V3TeamRef?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let team, let teamID = team.id {
            NavigationLink {
                TeamProfileView(
                    teamID: teamID,
                    name: team.name,
                    logo: team.image.preferred(for: colorScheme),
                    source: "event_detail"
                )
            } label: {
                content()
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens team profile")
        } else {
            content()
        }
    }
}

private struct EventSectionHeader: View {
    let title: LocalizedStringKey
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Overview

private struct EventOverviewSection: View {
    let detail: V3EventDetail

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        if detail.prizes.isEmpty && detail.teams.isEmpty {
            ContentUnavailableView(
                "No event details yet",
                systemImage: "trophy",
                description: Text("VLR.GG hasn’t listed prizes or teams for this event.")
            )
        }

        if !detail.prizes.isEmpty {
            EventCard(title: Text("Prize Distribution")) {
                VStack(spacing: 0) {
                    ForEach(Array(detail.prizes.enumerated()), id: \.offset) { index, prize in
                        if index > 0 { Divider() }
                        prizeRow(prize)
                    }
                }
            }
        }

        if !detail.teams.isEmpty {
            EventCard(title: Text("Teams"), trailing: String(detail.teams.count)) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(detail.teams.enumerated()), id: \.offset) { _, entry in
                        teamTile(entry)
                    }
                }
            }
        }
    }

    private func prizeRow(_ prize: V3EventPrize) -> some View {
        EventTeamLink(team: prize.team) {
            HStack(spacing: 12) {
                Text(prize.placement)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let team = prize.team {
                    MatchTeamLogo(team: team, matchID: nil, teamPosition: 0, size: 28)
                    Text(team.name)
                        .font(.subheadline)
                        .lineLimit(1)
                } else {
                    Text("TBD")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let amount = prize.prize.displayText {
                    Text(amount)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func teamTile(_ entry: V3EventTeam) -> some View {
        EventTeamLink(team: entry.team) {
            HStack(spacing: 10) {
                MatchTeamLogo(team: entry.team, matchID: nil, teamPosition: 0, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.team.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let qualification = entry.qualification?.nilIfBlank {
                        Text(qualification)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stages

private struct EventStageContent: View {
    let detail: V3EventDetail

    var body: some View {
        if !detail.hasStageContent {
            ContentUnavailableView(
                "No standings or bracket yet",
                systemImage: "list.number",
                description: Text("VLR.GG hasn’t published groups or a bracket for this stage.")
            )
        }

        ForEach(Array(detail.groups.enumerated()), id: \.offset) { _, group in
            EventGroupCard(group: group)
        }

        ForEach(Array(detail.standings.enumerated()), id: \.offset) { _, table in
            if !table.rows.isEmpty {
                EventStandingTableCard(table: table)
            }
        }

        let titles = bracketTitles
        ForEach(Array(detail.brackets.enumerated()), id: \.offset) { index, bracket in
            if !bracket.rounds.isEmpty {
                EventBracketCard(title: titles[index], bracket: bracket)
            }
        }
    }

    /// "Upper Bracket", "Lower Bracket"…, numbered when a stage has several of a kind
    /// (e.g. one per group), since the API doesn't name them.
    private var bracketTitles: [String] {
        let types = detail.brackets.map { $0.type.lowercased() }
        var seen: [String: Int] = [:]
        return types.map { type in
            let base: String = switch type {
            case "upper": String(localized: "Upper Bracket")
            case "lower": String(localized: "Lower Bracket")
            case "main", "": String(localized: "Bracket")
            default: String(localized: "\(type.capitalized) Bracket")
            }
            guard types.filter({ $0 == type }).count > 1 else { return base }
            seen[type, default: 0] += 1
            return "\(base) \(seen[type] ?? 1)"
        }
    }
}

private struct EventGroupCard: View {
    let group: V3EventGroup

    private static let numberColumn: CGFloat = 44

    var body: some View {
        EventCard(title: Text(verbatim: group.name)) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("#")
                        .frame(width: 22, alignment: .leading)
                    Text("Team")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("W–L").frame(width: Self.numberColumn, alignment: .trailing)
                    Text("Maps").frame(width: Self.numberColumn, alignment: .trailing)
                    Text("RD").frame(width: Self.numberColumn, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                ForEach(Array(group.teams.enumerated()), id: \.offset) { _, row in
                    Divider()
                    EventTeamLink(team: row.team) {
                        HStack(spacing: 8) {
                            Text("\(row.rank)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(rankColor(row.state))
                                .frame(width: 22, alignment: .leading)
                            HStack(spacing: 8) {
                                MatchTeamLogo(team: row.team, matchID: nil, teamPosition: 0, size: 22)
                                Text(row.team.name)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(pair(row.seriesWins, row.seriesLosses))
                                .frame(width: Self.numberColumn, alignment: .trailing)
                            Text(pair(row.mapsWon, row.mapsLost))
                                .frame(width: Self.numberColumn, alignment: .trailing)
                            Text(row.roundDifferential.map(signed) ?? "–")
                                .frame(width: Self.numberColumn, alignment: .trailing)
                        }
                        .font(.subheadline)
                        .monospacedDigit()
                        .opacity(row.state == .eliminated ? 0.55 : 1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(row))
                }
            }
        }
    }

    private func rankColor(_ state: V3EventGroupTeamState) -> Color {
        switch state {
        case .advanced: .green
        case .eliminated: .red
        case .active, .unknown: .primary
        }
    }

    private func pair(_ first: Int?, _ second: Int?) -> String {
        guard let first, let second else { return "–" }
        return "\(first)–\(second)"
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func accessibilityLabel(_ row: V3EventGroupTeam) -> String {
        var parts = ["\(row.rank)", row.team.name]
        if let wins = row.seriesWins, let losses = row.seriesLosses {
            parts.append(String(localized: "\(wins) wins, \(losses) losses"))
        }
        if let diff = row.roundDifferential {
            parts.append(String(localized: "round difference \(signed(diff))"))
        }
        switch row.state {
        case .advanced: parts.append(String(localized: "advanced"))
        case .eliminated: parts.append(String(localized: "eliminated"))
        case .active, .unknown: break
        }
        return parts.joined(separator: ", ")
    }
}

private struct EventStandingTableCard: View {
    let table: V3EventStandingTable

    var body: some View {
        EventCard(title: table.stage?.nilIfBlank.map { Text(verbatim: $0) } ?? Text("Standings")) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                            Text(column)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        GridRow {
                            ForEach(Array(table.columns.indices), id: \.self) { index in
                                Text((row.indices.contains(index) ? row[index] : nil) ?? "–")
                                    .lineLimit(1)
                            }
                        }
                        .font(.subheadline)
                        .monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct EventBracketCard: View {
    let title: String
    let bracket: V3EventBracket

    var body: some View {
        EventCard(title: Text(verbatim: title)) {
            // Lazy, so rows still missing a logo only look it up once they scroll into view.
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(bracket.rounds.enumerated()), id: \.offset) { _, round in
                    if !round.matches.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            Text(round.name)
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .kerning(0.5)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(round.matches) { match in
                                EventBracketMatchRow(match: match)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct EventBracketMatchRow: View {
    let match: V3EventMatch

    var body: some View {
        NavigationLink {
            MatchDetailView(matchID: match.id, fallbackURL: match.url, source: "event_bracket")
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    teamLine(match.firstTeam, position: 0)
                    teamLine(match.secondTeam, position: 1)
                }
                if let status = statusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(MatchCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens native match details")
    }

    private var hasWinner: Bool { match.teams.contains { $0.isWinner } }

    private var statusText: String? {
        if let startsAt = match.startsAt, !hasWinner, match.teams.allSatisfy({ $0.score == nil }) {
            return startsAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return match.statusText?.nilIfBlank ?? match.dateText?.nilIfBlank
    }

    private func teamLine(_ team: V3TeamRef?, position: Int) -> some View {
        let isLoser = hasWinner && team?.isWinner != true
        return HStack(spacing: 8) {
            MatchTeamLogo(team: team, matchID: match.id, teamPosition: position, size: 20)
            Text(team?.name ?? "TBD")
                .font(.subheadline.weight(team?.isWinner == true ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(team?.score.map(String.init) ?? "–")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(isLoser ? .secondary : .primary)
    }

    private var accessibilityLabel: String {
        let first = match.firstTeam
        let second = match.secondTeam
        var label = "\(first?.name ?? "TBD") \(first?.score.map(String.init) ?? "") versus \(second?.name ?? "TBD") \(second?.score.map(String.init) ?? "")"
        if let statusText { label += ", \(statusText)" }
        return label
    }
}

// MARK: - Matches

private struct EventMatchesSection: View {
    let matches: [V3Match]
    let state: ListLoadState
    let retry: () -> Void

    var body: some View {
        if case .showingSaved(let message, let isOffline) = state {
            SavedDataBanner(
                offlineText: "Offline — showing saved matches",
                failedText: "Couldn’t refresh — showing saved matches",
                message: message,
                isOffline: isOffline
            )
        }

        if matches.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView("Loading matches…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .failed(let message, let retryable):
                ListFailureView(title: "Matches unavailable", message: message, retryable: retryable, retry: retry)
            case .empty, .loaded, .showingSaved:
                ContentUnavailableView(
                    "No matches yet",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("VLR.GG hasn’t scheduled any matches for this event.")
                )
            }
        } else {
            let live = matches.filter { $0.status == .live }
            let upcoming = matches.filter { $0.status == .scheduled || $0.status == .unknown }
            // Listed oldest first by VLR.GG; the latest results matter most.
            let results = matches.filter { $0.status == .completed }.reversed()

            if !live.isEmpty {
                EventSectionHeader(title: "Live", count: live.count)
                ForEach(live) { match in
                    LiveMatchTab(match: match)
                }
            }
            if !upcoming.isEmpty {
                EventSectionHeader(title: "Upcoming", count: upcoming.count)
                ForEach(upcoming) { match in
                    EventScheduledMatchCard(match: match)
                }
            }
            if !results.isEmpty {
                EventSectionHeader(title: "Results", count: results.count)
                ForEach(Array(results)) { match in
                    MatchResultsTab(match: match)
                }
            }
        }
    }
}

/// Event match pages give a display date and time but often no timestamp, which
/// `UpcomingMatchTab` needs, so this card falls back to the display strings.
private struct EventScheduledMatchCard: View {
    let match: V3Match

    var body: some View {
        if match.startsAt != nil {
            UpcomingMatchTab(match: match)
        } else {
            MatchListCard(
                match: match,
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: "Opens native match details"
            ) {
                if let relative = match.display.relative?.nilIfBlank {
                    Label(relative, systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            } center: {
                VStack(spacing: 3) {
                    Text(match.display.time?.nilIfBlank ?? String(localized: "vs"))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let date = match.display.date?.nilIfBlank {
                        Text(date)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }

    private var accessibilityLabel: String {
        let schedule = [match.display.date, match.display.time].compactMap { $0?.nilIfBlank }.joined(separator: " ")
        return "\(match.firstTeam?.name ?? "Team one") versus \(match.secondTeam?.name ?? "Team two"), \(schedule.isEmpty ? match.status.displayName : schedule), \(match.event.name)"
    }
}

// MARK: - Stats

private enum EventStatSort: String, CaseIterable, Identifiable {
    case rating
    case averageCombatScore
    case killDeathRatio
    case averageDamagePerRound
    case kast
    case kills

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .rating: "Rating"
        case .averageCombatScore: "ACS"
        case .killDeathRatio: "K/D"
        case .averageDamagePerRound: "ADR"
        case .kast: "KAST"
        case .kills: "Kills"
        }
    }

    func value(_ stats: V3EventPlayerStats) -> Double? {
        switch self {
        case .rating: stats.rating
        case .averageCombatScore: stats.averageCombatScore
        case .killDeathRatio: stats.killDeathRatio
        case .averageDamagePerRound: stats.averageDamagePerRound
        case .kast: stats.kastPercent
        case .kills: stats.kills.map(Double.init)
        }
    }

    func formatted(_ stats: V3EventPlayerStats) -> String {
        guard let value = value(stats) else { return "–" }
        switch self {
        case .rating, .killDeathRatio:
            return value.formatted(.number.precision(.fractionLength(2)))
        case .averageCombatScore, .kills:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .averageDamagePerRound:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .kast:
            return "\(value.formatted(.number.precision(.fractionLength(0))))%"
        }
    }
}

private struct EventStatsSection: View {
    let players: [V3EventPlayerStats]
    let state: ListLoadState
    let retry: () -> Void

    @State private var sort: EventStatSort = .rating

    private var sortedPlayers: [V3EventPlayerStats] {
        players.sorted { lhs, rhs in
            switch (sort.value(lhs), sort.value(rhs)) {
            case let (left?, right?): left > right
            case (.some, nil): true
            case (nil, _): false
            }
        }
    }

    var body: some View {
        if case .showingSaved(let message, let isOffline) = state {
            SavedDataBanner(
                offlineText: "Offline — showing saved stats",
                failedText: "Couldn’t refresh — showing saved stats",
                message: message,
                isOffline: isOffline
            )
        }

        if players.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView("Loading stats…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .failed(let message, let retryable):
                ListFailureView(title: "Stats unavailable", message: message, retryable: retryable, retry: retry)
            case .empty, .loaded, .showingSaved:
                ContentUnavailableView(
                    "No player stats yet",
                    systemImage: "chart.bar",
                    description: Text("Stats appear once matches in this event have been played.")
                )
            }
        } else {
            HStack {
                EventSectionHeader(title: "Players", count: players.count)
                Picker("Sort by", selection: $sort) {
                    ForEach(EventStatSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            ForEach(Array(sortedPlayers.enumerated()), id: \.element.id) { index, player in
                EventPlayerStatRow(rank: index + 1, stats: player, sort: sort)
            }
        }
    }
}

private struct EventPlayerStatRow: View {
    let rank: Int
    let stats: V3EventPlayerStats
    let sort: EventStatSort

    var body: some View {
        Group {
            if let playerID = stats.player.id {
                NavigationLink {
                    PlayerProfileView(playerID: playerID, name: stats.player.name, source: "event_stats")
                } label: {
                    content
                }
                .buttonStyle(MatchCardButtonStyle())
                .accessibilityHint("Opens player profile")
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let flag = countryFlag(stats.countryCode) {
                        Text(flag)
                            .font(.caption)
                    }
                    Text(stats.player.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(sort.formatted(stats))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text(sort.title)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    /// Organisation plus the stats not being sorted by.
    private var secondaryLine: String {
        var parts: [String] = []
        if let organization = stats.organization?.nilIfBlank { parts.append(organization) }
        for option in [EventStatSort.rating, .averageCombatScore, .killDeathRatio, .averageDamagePerRound]
        where option != sort && option.value(stats) != nil {
            parts.append("\(option.label) \(option.formatted(stats))")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = ["\(rank)", stats.player.name]
        if let organization = stats.organization?.nilIfBlank { parts.append(organization) }
        for option in EventStatSort.allCases where option.value(stats) != nil {
            parts.append("\(option.label) \(option.formatted(stats))")
        }
        return parts.joined(separator: ", ")
    }
}

private extension EventStatSort {
    /// Plain-text abbreviation for joined captions and accessibility labels.
    var label: String {
        switch self {
        case .rating: String(localized: "Rating")
        case .averageCombatScore: "ACS"
        case .killDeathRatio: "K/D"
        case .averageDamagePerRound: "ADR"
        case .kast: "KAST"
        case .kills: String(localized: "Kills")
        }
    }
}

#Preview {
    NavigationStack {
        EventDetailView(eventID: 2283, name: "Valorant Champions 2025", logo: nil)
    }
}
