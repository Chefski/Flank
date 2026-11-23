//
//  MatchReplayView.swift
//  Flank
//
//  Round-by-round replay of one map: round strip, round result, timeline of kills
//  and spike events, a 2D plot of positions, and each team's buy.
//

import SwiftUI

struct MatchReplayView: View {
    @StateObject private var viewModel: MatchReplayViewModel
    @State private var selectedRoundNumber: Int?
    @State private var eventIndex = 0
    @State private var reloadToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let mapName: String?
    private let teams: [V3TeamRef]

    /// - Parameters:
    ///   - matchID: vlr.gg match ID.
    ///   - gameID: vlr.gg game (map) ID, `V3Game.id`.
    ///   - mapName: Shown in the title; the payload's map slug is used when `nil`.
    ///   - teams: The match's teams in API order, for names and logos.
    ///   - isMapInProgress: Whether the map is still being played, so a saved replay
    ///     is refreshed on every open instead of reused.
    init(matchID: Int, gameID: Int, mapName: String?, teams: [V3TeamRef], isMapInProgress: Bool = false) {
        self.mapName = mapName
        self.teams = teams
        _viewModel = StateObject(wrappedValue: MatchReplayViewModel(
            matchID: matchID,
            gameID: gameID,
            isMapInProgress: isMapInProgress
        ))
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadToken) {
            // The first load may reuse a saved copy; "Try Again" and "Check Again" don't.
            await viewModel.load(force: reloadToken > 0)
        }
    }

    private var title: String {
        if let mapName, !mapName.isEmpty {
            return "\(mapName) replay"
        }
        if case .loaded(let replay, _) = viewModel.state, let slug = replay.map, !slug.isEmpty {
            return "\(slug.capitalized) replay"
        }
        return "Round replay"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView("Loading round replay…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label("No replay yet", systemImage: "film.stack")
            } description: {
                Text("VLR.GG hasn’t published a round-by-round replay for this map.")
            } actions: {
                Button("Check Again") { reloadToken += 1 }
                    .buttonStyle(.bordered)
            }
        case .failed(let message, let retryable):
            ContentUnavailableView {
                Label("Replay unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                if retryable {
                    Button("Try Again") { reloadToken += 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .loaded(let replay, let refreshFailure):
            loadedContent(replay, refreshFailure: refreshFailure)
        }
    }

    // MARK: - Loaded

    private func loadedContent(_ replay: MatchReplay, refreshFailure: RefreshFailure?) -> some View {
        let teamInfo = ReplayTeamInfo(replay: replay, teams: teams)
        let round = selectedRound(in: replay)
        let canvasSize = replay.canvasSize

        return ScrollView {
            VStack(spacing: 16) {
                if let refreshFailure {
                    SavedDataBanner(
                        offlineText: "Offline — showing saved replay",
                        failedText: "Couldn’t refresh — showing saved replay",
                        message: refreshFailure.message,
                        isOffline: refreshFailure.isOffline
                    )
                }

                ReplayCard(title: "Rounds", symbol: "circle.grid.3x3.fill") {
                    ReplayRoundStrip(
                        rounds: replay.rounds,
                        selection: round?.number,
                        teamInfo: teamInfo
                    ) { number in
                        selectRound(number)
                    }
                }

                if let round {
                    roundHeader(round, rounds: replay.rounds, teamInfo: teamInfo)

                    let plotSize = round.events.contains(where: \.hasPlotData) ? canvasSize : nil
                    if let plotSize {
                        plotCard(round, canvasSize: plotSize, teamInfo: teamInfo)
                    }

                    timelineCard(round, teamInfo: teamInfo, isInteractive: plotSize != nil)

                    if !round.economy.isEmpty {
                        buyCard(round, teamInfo: teamInfo)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await viewModel.load(force: true) }
        .sensoryFeedback(.selection, trigger: selectedRoundNumber)
    }

    private func selectedRound(in replay: MatchReplay) -> ReplayRound? {
        if let selectedRoundNumber,
           let round = replay.rounds.first(where: { $0.number == selectedRoundNumber }) {
            return round
        }
        return replay.rounds.first
    }

    private func selectRound(_ number: Int) {
        guard number != selectedRoundNumber else { return }
        if reduceMotion {
            selectedRoundNumber = number
        } else {
            withAnimation(.snappy(duration: 0.25)) { selectedRoundNumber = number }
        }
        eventIndex = 0
    }

    // MARK: Round header

    private func roundHeader(_ round: ReplayRound, rounds: [ReplayRound], teamInfo: ReplayTeamInfo) -> some View {
        let index = rounds.firstIndex(where: { $0.number == round.number })
        let previous = index.flatMap { $0 > 0 ? rounds[$0 - 1] : nil }
        let next = index.flatMap { $0 + 1 < rounds.count ? rounds[$0 + 1] : nil }

        return ReplayCard(title: "Round \(round.number)", symbol: "flag.checkered") {
            HStack(spacing: 12) {
                ReplayTeamScore(slot: .team1, round: round, teamInfo: teamInfo)
                Text("–")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                ReplayTeamScore(slot: .team2, round: round, teamInfo: teamInfo)
            }

            HStack(spacing: 8) {
                Image(systemName: endReasonSymbol(round.endReason))
                    .foregroundStyle(ReplayPalette.color(for: round.winner))
                VStack(alignment: .leading, spacing: 2) {
                    Text(round.winner == .unknown ? "Winner unavailable" : "\(teamInfo.name(round.winner)) won")
                        .font(.subheadline.weight(.semibold))
                    Text([round.endReason, round.phase.displayName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ControlGroup {
                    Button {
                        if let previous { selectRound(previous.number) }
                    } label: {
                        Label("Previous round", systemImage: "chevron.left")
                    }
                    .disabled(previous == nil)
                    Button {
                        if let next { selectRound(next.number) }
                    } label: {
                        Label("Next round", systemImage: "chevron.right")
                    }
                    .disabled(next == nil)
                }
                .controlGroupStyle(.navigation)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
            .padding(12)
            .background(.insetFill, in: .rect(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .contain)
    }

    private func endReasonSymbol(_ reason: String?) -> String {
        let reason = reason?.lowercased() ?? ""
        if reason.contains("defuse") { return "scissors" }
        if reason.contains("spike") || reason.contains("detonat") || reason.contains("explo") { return "burst.fill" }
        if reason.contains("time") { return "timer" }
        if reason.contains("elim") { return "xmark.circle.fill" }
        return "flag.checkered"
    }

    // MARK: Plot

    private func plotCard(_ round: ReplayRound, canvasSize: Double, teamInfo: ReplayTeamInfo) -> some View {
        let events = round.events
        let current = min(eventIndex, max(events.count - 1, 0))
        let event = events[current]

        return ReplayCard(title: "Positions", symbol: "scope") {
            ReplayPlot(round: round, eventIndex: current, canvasSize: canvasSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Map positions at \(event.time ?? "unknown time")")
                .accessibilityValue(plotAccessibilityValue(event, teamInfo: teamInfo))

            VStack(alignment: .leading, spacing: 8) {
                Text(ReplayEventText.summary(event, teamInfo: teamInfo))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)

                HStack(spacing: 10) {
                    Button {
                        stepEvent(by: -1, count: events.count)
                    } label: {
                        Label("Previous event", systemImage: "backward.frame.fill")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(current == 0)

                    if events.count > 1 {
                        Slider(
                            value: Binding(
                                get: { Double(current) },
                                set: { eventIndex = Int($0.rounded()) }
                            ),
                            in: 0...Double(events.count - 1),
                            step: 1
                        )
                        .accessibilityLabel("Round timeline")
                        .accessibilityValue("Event \(current + 1) of \(events.count), \(event.time ?? "")")
                    } else {
                        Spacer()
                    }

                    Button {
                        stepEvent(by: 1, count: events.count)
                    } label: {
                        Label("Next event", systemImage: "forward.frame.fill")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(current >= events.count - 1)
                }

                Text("Event \(current + 1) of \(events.count) · \(event.time ?? "–")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .sensoryFeedback(.selection, trigger: current)

            ReplayLegend(teamInfo: teamInfo)
        }
    }

    private func stepEvent(by delta: Int, count: Int) {
        eventIndex = min(max(eventIndex + delta, 0), max(count - 1, 0))
    }

    private func plotAccessibilityValue(_ event: ReplayEvent, teamInfo: ReplayTeamInfo) -> String {
        let alive = event.positions.map(\.player).filter { !$0.isEmpty }
        let summary = ReplayEventText.spoken(event, teamInfo: teamInfo)
        guard !alive.isEmpty else { return summary }
        return "\(summary). Alive: \(alive.joined(separator: ", "))"
    }

    // MARK: Timeline

    private func timelineCard(_ round: ReplayRound, teamInfo: ReplayTeamInfo, isInteractive: Bool) -> some View {
        let alive = ReplayAliveCounts.after(round)
        let agents = round.agentsByPlayer

        return ReplayCard(title: "Timeline", symbol: "list.bullet.rectangle") {
            if round.events.isEmpty {
                Text("No kills or spike events were recorded for this round.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(round.events.enumerated()), id: \.offset) { index, event in
                        let isCurrent = isInteractive && index == min(eventIndex, round.events.count - 1)
                        let row = ReplayEventRow(
                            event: event,
                            teamInfo: teamInfo,
                            agents: agents,
                            alive: alive[index],
                            isCurrent: isCurrent
                        )
                        if isInteractive {
                            Button {
                                eventIndex = index
                            } label: {
                                row
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                            .accessibilityHint("Shows this moment on the map")
                        } else {
                            row
                        }

                        if index < round.events.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: Buys

    private func buyCard(_ round: ReplayRound, teamInfo: ReplayTeamInfo) -> some View {
        ReplayCard(title: "Buys", symbol: "creditcard.fill") {
            ForEach([ReplayTeamSlot.team1, .team2], id: \.self) { slot in
                let buys = round.buys(for: slot)
                if !buys.isEmpty {
                    ReplayTeamBuy(slot: slot, round: round, buys: buys, teamInfo: teamInfo)
                }
            }
        }
    }
}

// MARK: - Team info

/// Names, tags and logos for the two teams, preferring the replay's own names and
/// falling back to the match's team list.
private struct ReplayTeamInfo {
    let replay: MatchReplay
    let teams: [V3TeamRef]

    func team(_ slot: ReplayTeamSlot) -> V3TeamRef? {
        switch slot {
        case .team1: teams.first
        case .team2: teams.dropFirst().first
        case .unknown: nil
        }
    }

    func name(_ slot: ReplayTeamSlot) -> String {
        if let name = replay.teams[slot]?.name, !name.isEmpty { return name }
        if let name = team(slot)?.name, !name.isEmpty { return name }
        switch slot {
        case .team1: return "Team 1"
        case .team2: return "Team 2"
        case .unknown: return "Unknown team"
        }
    }

    func tag(_ slot: ReplayTeamSlot) -> String {
        if let tag = replay.teams[slot]?.tag, !tag.isEmpty { return tag }
        if let tag = team(slot)?.tag, !tag.isEmpty { return tag }
        return name(slot)
    }

    func side(_ slot: ReplayTeamSlot, in round: ReplayRound) -> String? {
        guard slot != .unknown, round.attackingSide != .unknown else { return nil }
        return round.attackingSide == slot ? "ATK" : "DEF"
    }
}

private enum ReplayPalette {
    static func color(for slot: ReplayTeamSlot) -> Color {
        switch slot {
        case .team1: .teal
        case .team2: .orange
        case .unknown: .gray
        }
    }
}

private extension ReplayRound.Phase {
    var displayName: String {
        switch self {
        case .firstHalf: "First half"
        case .secondHalf: "Second half"
        case .overtime: "Overtime"
        }
    }
}

private extension ReplayEvent {
    var hasPlotData: Bool {
        !positions.isEmpty || position?.cgPoint != nil
    }
}

private extension ReplayPoint {
    var cgPoint: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }
}

private extension ReplayPosition {
    var cgPoint: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }
}

private enum ReplayAgent {
    /// Asset name for an agent slug from vlr.gg, e.g. `"kay/o"` -> `"kayo"`, if the app bundles it.
    static func assetName(_ agent: String?) -> String? {
        guard let agent else { return nil }
        let name = agent.lowercased().filter { $0.isLetter }
        guard !name.isEmpty, UIImage(named: name) != nil else { return nil }
        return name
    }
}

/// Players alive on each team after each event of a round.
private enum ReplayAliveCounts {
    struct Count {
        let team1: Int
        let team2: Int
    }

    static func after(_ round: ReplayRound) -> [Count] {
        let rosterOne = round.buys(for: .team1).count
        let rosterTwo = round.buys(for: .team2).count
        var team1 = rosterOne > 0 ? rosterOne : 5
        var team2 = rosterTwo > 0 ? rosterTwo : 5
        return round.events.map { event in
            if event.kind == .kill {
                switch event.victimSlot {
                case .team1: team1 = max(team1 - 1, 0)
                case .team2: team2 = max(team2 - 1, 0)
                case .unknown: break
                }
            }
            return Count(team1: team1, team2: team2)
        }
    }
}

private enum ReplayEventText {
    static func actor(_ event: ReplayEvent) -> String {
        event.player.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown player"
    }

    static func victim(_ event: ReplayEvent) -> String {
        event.victim.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown player"
    }

    /// Short visible description, e.g. "fluxx killed Garv".
    static func summary(_ event: ReplayEvent, teamInfo: ReplayTeamInfo) -> String {
        switch event.kind {
        case .kill:
            if event.isSpikeKill { return "\(victim(event)) killed by the spike" }
            return "\(actor(event)) killed \(victim(event))"
        case .plant:
            return event.site.map { "\(actor(event)) planted on \($0)" } ?? "\(actor(event)) planted the spike"
        case .defuse:
            return event.site.map { "\(actor(event)) defused on \($0)" } ?? "\(actor(event)) defused the spike"
        case .unknown:
            return "Round event"
        }
    }

    /// Full sentence for VoiceOver, including teams, weapon and headshot.
    static func spoken(_ event: ReplayEvent, teamInfo: ReplayTeamInfo) -> String {
        let time = event.time.map { "\($0), " } ?? ""
        switch event.kind {
        case .kill:
            if event.isSpikeKill {
                return "\(time)\(victim(event)) of \(teamInfo.name(event.victimSlot)) killed by the spike"
            }
            var sentence = "\(time)\(actor(event)) of \(teamInfo.name(event.slot)) killed \(victim(event)) of \(teamInfo.name(event.victimSlot))"
            if let source = event.source, !source.isEmpty {
                sentence += " with \(source)"
            }
            if event.headshot == true {
                sentence += ", headshot"
            }
            return sentence
        case .plant:
            let site = event.site.map { " on site \($0)" } ?? ""
            return "\(time)\(actor(event)) of \(teamInfo.name(event.slot)) planted the spike\(site)"
        case .defuse:
            let site = event.site.map { " on site \($0)" } ?? ""
            return "\(time)\(actor(event)) of \(teamInfo.name(event.slot)) defused the spike\(site)"
        case .unknown:
            return "\(time)round event"
        }
    }
}

// MARK: - Components

private struct ReplayCard<Content: View>: View {
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

private struct ReplayRoundStrip: View {
    let rounds: [ReplayRound]
    let selection: Int?
    let teamInfo: ReplayTeamInfo
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(rounds.enumerated()), id: \.element.number) { index, round in
                        if index > 0, rounds[index - 1].phase != round.phase {
                            separator(round.phase)
                        }
                        chip(round)
                            .id(round.number)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
            .onChange(of: selection) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rounds")
    }

    private func separator(_ phase: ReplayRound.Phase) -> some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 22)
            Text(phase == .overtime ? "OT" : "2H")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }

    private func chip(_ round: ReplayRound) -> some View {
        let isSelected = round.number == selection
        let color = ReplayPalette.color(for: round.winner)

        return Button {
            onSelect(round.number)
        } label: {
            Text(String(round.number))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 36, height: 40)
                .background(color.opacity(isSelected ? 0.45 : 0.2), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(color)
                        .frame(width: 18, height: 3)
                        .padding(.bottom, 4)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.primary, lineWidth: 2)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(round))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(_ round: ReplayRound) -> String {
        let winner = round.winner == .unknown ? "winner unavailable" : "won by \(teamInfo.name(round.winner))"
        return [("Round \(round.number), \(winner)"), round.endReason].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct ReplayTeamScore: View {
    @Environment(\.colorScheme) private var colorScheme

    let slot: ReplayTeamSlot
    let round: ReplayRound
    let teamInfo: ReplayTeamInfo

    var body: some View {
        let isWinner = round.winner == slot
        let score = slot == .team1 ? round.score.team1 : round.score.team2

        VStack(spacing: 6) {
            AsyncImage(url: VLRAPI.imageURL(from: teamInfo.team(slot)?.image.preferred(for: colorScheme))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "shield.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(ReplayPalette.color(for: slot).opacity(0.6))
                    .padding(6)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            Text(teamInfo.tag(slot))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 6) {
                if let side = teamInfo.side(slot, in: round) {
                    Text(side)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ReplayPalette.color(for: slot))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ReplayPalette.color(for: slot).opacity(0.15), in: Capsule())
                }
                Text(score.map(String.init) ?? "–")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(isWinner || round.winner == .unknown ? .primary : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(score: score, isWinner: isWinner))
    }

    private func accessibilityLabel(score: Int?, isWinner: Bool) -> String {
        var parts = [teamInfo.name(slot)]
        if let side = teamInfo.side(slot, in: round) {
            parts.append(side == "ATK" ? "attacking" : "defending")
        }
        parts.append("score \(score.map(String.init) ?? "unavailable")")
        if isWinner {
            parts.append("won the round")
        }
        return parts.joined(separator: ", ")
    }
}

private struct ReplayEventRow: View {
    let event: ReplayEvent
    let teamInfo: ReplayTeamInfo
    let agents: [String: String]
    let alive: ReplayAliveCounts.Count
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(event.time ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            icon
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                headline
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if event.kind == .kill {
                Text("\(alive.team1)v\(alive.team2)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.insetFill, in: Capsule())
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch event.kind {
        case .kill:
            if !event.isSpikeKill, let asset = ReplayAgent.assetName(event.player.flatMap { agents[$0] }) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
            } else {
                symbol(event.isSpikeKill ? "burst.fill" : "scope", color: ReplayPalette.color(for: event.slot))
            }
        case .plant:
            symbol("exclamationmark.triangle.fill", color: ReplayPalette.color(for: event.slot))
        case .defuse:
            symbol("scissors", color: ReplayPalette.color(for: event.slot))
        case .unknown:
            symbol("circle.fill", color: .secondary)
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 26, height: 26)
            .background(color.opacity(0.15), in: .rect(cornerRadius: 6, style: .continuous))
    }

    private var headline: Text {
        let actor = Text(ReplayEventText.actor(event)).foregroundStyle(ReplayPalette.color(for: event.slot))
        let victim = Text(ReplayEventText.victim(event)).foregroundStyle(ReplayPalette.color(for: event.victimSlot))
        switch event.kind {
        case .kill:
            if event.isSpikeKill {
                return Text("Spike \(Image(systemName: "arrow.right")) \(victim)")
            }
            return Text("\(actor) \(Image(systemName: "arrow.right")) \(victim)")
        case .plant:
            return Text("\(actor) planted\(event.site.map { " on \($0)" } ?? "")")
        case .defuse:
            return Text("\(actor) defused\(event.site.map { " on \($0)" } ?? "")")
        case .unknown:
            return Text("Round event")
        }
    }

    private var detail: String? {
        switch event.kind {
        case .kill:
            var parts: [String] = []
            if !event.isSpikeKill, let source = event.source, !source.isEmpty {
                parts.append(source)
            }
            if event.headshot == true {
                parts.append("Headshot")
            }
            if let agent = event.victim.flatMap({ agents[$0] }) {
                parts.append("\(agent.capitalized) down")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .plant:
            return "Spike planted"
        case .defuse:
            return "Spike defused"
        case .unknown:
            return nil
        }
    }

    private var spokenLabel: String {
        var label = ReplayEventText.spoken(event, teamInfo: teamInfo)
        if event.kind == .kill {
            label += ". \(alive.team1) versus \(alive.team2) remaining"
        }
        return label
    }
}

private struct ReplayTeamBuy: View {
    let slot: ReplayTeamSlot
    let round: ReplayRound
    let buys: [ReplayBuy]
    let teamInfo: ReplayTeamInfo

    var body: some View {
        let spent = buys.compactMap(\.spent).reduce(0, +)
        let left = buys.compactMap(\.credits).reduce(0, +)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(ReplayPalette.color(for: slot))
                    .frame(width: 8, height: 8)
                Text(teamInfo.name(slot))
                    .font(.headline)
                    .lineLimit(1)
                if let side = teamInfo.side(slot, in: round) {
                    Text(side)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Spent \(spent.formatted()) · Left \(left.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(teamInfo.name(slot))\(teamInfo.side(slot, in: round).map { $0 == "ATK" ? ", attacking" : ", defending" } ?? ""). Spent \(spent) credits, \(left) left"
            )
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(buys.enumerated()), id: \.offset) { _, buy in
                ReplayBuyRow(buy: buy)
            }
        }
        .padding(12)
        .background(.insetFill, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

private struct ReplayBuyRow: View {
    let buy: ReplayBuy

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let asset = ReplayAgent.assetName(buy.agent) {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(.rect(cornerRadius: 5, style: .continuous))

            Text(buy.player.isEmpty ? "Unknown player" : buy.player)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(buy.weapon.flatMap { $0.isEmpty ? nil : $0 } ?? "–")
                .font(.caption)
                .lineLimit(1)

            Image(systemName: buy.armor.symbol)
                .font(.caption)
                .foregroundStyle(buy.armor == .none ? .tertiary : .secondary)
                .frame(width: 18)

            Text(buy.credits.map { $0.formatted() } ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [buy.player.isEmpty ? "Unknown player" : buy.player]
        if let agent = buy.agent, !agent.isEmpty { parts.append(agent.capitalized) }
        if let weapon = buy.weapon, !weapon.isEmpty { parts.append(weapon) }
        if let armor = buy.armor.spokenName { parts.append(armor) }
        if let spent = buy.spent { parts.append("spent \(spent) credits") }
        if let credits = buy.credits { parts.append("\(credits) credits left") }
        return parts.joined(separator: ", ")
    }
}

private extension ReplayArmor {
    var symbol: String {
        switch self {
        case .heavy: "shield.fill"
        case .light: "shield.lefthalf.filled"
        case .regen: "arrow.trianglehead.2.clockwise.rotate.90.circle"
        case .none, .unknown: "shield.slash"
        }
    }

    var spokenName: String? {
        switch self {
        case .heavy: "heavy armor"
        case .light: "light armor"
        case .regen: "regen shield"
        case .none: "no armor"
        case .unknown: nil
        }
    }
}

private struct ReplayLegend: View {
    let teamInfo: ReplayTeamInfo

    var body: some View {
        HStack(spacing: 14) {
            item(Circle().fill(ReplayPalette.color(for: .team1)), teamInfo.tag(.team1))
            item(Circle().fill(ReplayPalette.color(for: .team2)), teamInfo.tag(.team2))
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.heavy))
                Text("Death")
            }
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text("Spike")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func item(_ swatch: some View, _ label: String) -> some View {
        HStack(spacing: 4) {
            swatch.frame(width: 8, height: 8)
            Text(label).lineLimit(1)
        }
    }
}

/// Positions of one moment of the round on a neutral square: living players as
/// dots, deaths so far as crosses, the current kill as a line from killer to victim,
/// and the spike once planted.
private struct ReplayPlot: View {
    let round: ReplayRound
    let eventIndex: Int
    let canvasSize: Double

    var body: some View {
        let events = round.events
        let current = events.indices.contains(eventIndex) ? events[eventIndex] : nil
        let earlierDeaths = events.prefix(eventIndex).filter { $0.kind == .kill }
        let spike = spikePoint(upTo: eventIndex)
        let team1 = ReplayPalette.color(for: .team1)
        let team2 = ReplayPalette.color(for: .team2)
        let unknown = ReplayPalette.color(for: .unknown)

        Canvas { context, size in
            let side = min(size.width, size.height)
            let scale = side / canvasSize
            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x * scale, y: point.y * scale)
            }
            func color(_ slot: ReplayTeamSlot) -> Color {
                switch slot {
                case .team1: team1
                case .team2: team2
                case .unknown: unknown
                }
            }

            // Grid
            var grid = Path()
            for step in 1..<8 {
                let offset = side * CGFloat(step) / 8
                grid.move(to: CGPoint(x: offset, y: 0))
                grid.addLine(to: CGPoint(x: offset, y: side))
                grid.move(to: CGPoint(x: 0, y: offset))
                grid.addLine(to: CGPoint(x: side, y: offset))
            }
            context.stroke(grid, with: .style(.separator), lineWidth: 0.5)

            // Deaths before this moment
            for death in earlierDeaths {
                guard let point = death.position?.cgPoint else { continue }
                drawCross(at: place(point), size: 5, color: color(death.victimSlot).opacity(0.5), in: &context)
            }

            // Spike
            if let spike {
                let center = place(spike)
                var diamond = Path()
                diamond.move(to: CGPoint(x: center.x, y: center.y - 7))
                diamond.addLine(to: CGPoint(x: center.x + 7, y: center.y))
                diamond.addLine(to: CGPoint(x: center.x, y: center.y + 7))
                diamond.addLine(to: CGPoint(x: center.x - 7, y: center.y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(.red))
            }

            guard let current else { return }

            // Current kill: line from killer to victim
            if current.kind == .kill, let victimPoint = current.position?.cgPoint {
                if let origin = current.origin?.cgPoint {
                    var line = Path()
                    line.move(to: place(origin))
                    line.addLine(to: place(victimPoint))
                    context.stroke(
                        line,
                        with: .color(color(current.slot)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3])
                    )
                }
                drawCross(at: place(victimPoint), size: 8, color: color(current.victimSlot), in: &context)
                if let victim = current.victim, !victim.isEmpty {
                    context.draw(
                        Text(victim).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary),
                        at: CGPoint(x: place(victimPoint).x, y: place(victimPoint).y + 13)
                    )
                }
            }

            // Living players
            for player in current.positions {
                guard let point = player.cgPoint else { continue }
                let center = place(point)
                let isActor = player.player == current.player
                let radius: CGFloat = isActor ? 7 : 5.5
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color(player.slot)))
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .style(.background),
                    lineWidth: isActor ? 2 : 1
                )
                if isActor {
                    context.stroke(
                        Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                        with: .color(color(player.slot)),
                        lineWidth: 1.5
                    )
                }
                context.draw(
                    Text(player.player).font(.system(size: 9, weight: isActor ? .bold : .medium)).foregroundStyle(.primary),
                    at: CGPoint(x: center.x, y: center.y - radius - 7)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(.insetFill, in: .rect(cornerRadius: 14, style: .continuous))
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }

    /// Where the spike lies at `index`: planted at or before it, and either not yet
    /// defused or being defused at this very event.
    private func spikePoint(upTo index: Int) -> CGPoint? {
        var point: CGPoint?
        for (offset, event) in round.events.prefix(index + 1).enumerated() {
            switch event.kind {
            case .plant: point = event.position?.cgPoint
            case .defuse: point = offset == index ? (point ?? event.position?.cgPoint) : nil
            case .kill, .unknown: break
            }
        }
        return point
    }

    private func drawCross(at center: CGPoint, size: CGFloat, color: Color, in context: inout GraphicsContext) {
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - size, y: center.y - size))
        cross.addLine(to: CGPoint(x: center.x + size, y: center.y + size))
        cross.move(to: CGPoint(x: center.x + size, y: center.y - size))
        cross.addLine(to: CGPoint(x: center.x - size, y: center.y + size))
        context.stroke(cross, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}

private extension ShapeStyle where Self == Color {
    /// Fill for rows nested inside a section card.
    static var insetFill: Color { Color(uiColor: .tertiarySystemGroupedBackground) }
}
