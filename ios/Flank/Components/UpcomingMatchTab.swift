//
//  UpcomingMatchTab.swift
//  Flank
//

import SwiftUI

struct UpcomingMatchTab: View {
    let match: V3Match

    var body: some View {
        MatchListCard(
            match: match,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: "Opens native match details"
        ) {
            if let relative {
                countdownPill(relative)
            }
        } center: {
            VStack(spacing: 3) {
                if let startsAt = match.startsAt {
                    Text(startsAt, format: .dateTime.hour().minute())
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(dayLabel(for: startsAt))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("vs")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var relative: String? {
        guard let relative = match.display.relative, !relative.isEmpty else { return nil }
        return relative
    }

    /// Starting within the hour, so the countdown gets an accent instead of the neutral fill.
    private var startsSoon: Bool {
        guard let startsAt = match.startsAt else { return false }
        return startsAt.timeIntervalSinceNow < 3600
    }

    private func countdownPill(_ text: String) -> some View {
        Label(text, systemImage: "clock")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(startsSoon ? Color.orange : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                startsSoon ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06),
                in: Capsule()
            )
    }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var scheduleText: String {
        if let startsAt = match.startsAt {
            let time = startsAt.formatted(date: .abbreviated, time: .shortened)
            return relative.map { "\($0), \(time)" } ?? time
        }
        return relative ?? match.statusText ?? match.status.displayName
    }

    private var accessibilityLabel: String {
        "\(match.firstTeam?.name ?? "Team one") versus \(match.secondTeam?.name ?? "Team two"), \(scheduleText), \(match.event.name)"
    }
}

/// Shared layout for the Upcoming and Results list cards: an event header with a
/// trailing accessory, then both teams either side of a centre slot (kick-off time
/// or final score), on a surface softly tinted with the event's brand colour.
struct MatchListCard<Accessory: View, Center: View>: View {
    let match: V3Match
    let accessibilityLabel: String
    let accessibilityHint: String
    /// Team slot to fade back, e.g. the loser of a completed match.
    var dimmedTeamPosition: Int?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let center: () -> Center

    @Environment(\.colorScheme) private var colorScheme
    @State private var accent: Color?

    init(
        match: V3Match,
        accessibilityLabel: String,
        accessibilityHint: String,
        dimmedTeamPosition: Int? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder center: @escaping () -> Center
    ) {
        self.match = match
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.dimmedTeamPosition = dimmedTeamPosition
        self.accessory = accessory
        self.center = center
        // Start from an already-sampled colour so a reused card doesn't pop its tint in.
        _accent = State(initialValue: MatchCardAccent.color(
            from: LogoColorSampler.cachedColors(for: match.event.image.preferred(for: .dark))
        ))
    }

    /// Sampled from the dark variant so the tint matches across appearances and
    /// shares the sampler cache with the live cards and match detail.
    private var sampledEventLogo: String? {
        match.event.image.preferred(for: .dark)
    }

    var body: some View {
        NavigationLink {
            MatchDetailView(match: match)
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .center, spacing: 6) {
                    team(match.firstTeam, position: 0)
                    center()
                        .frame(minWidth: 88)
                    team(match.secondTeam, position: 1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { surface }
            .clipShape(.rect(cornerRadius: MatchCardMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MatchCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: MatchCardMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(MatchCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .task(id: sampledEventLogo) {
            let color = MatchCardAccent.color(from: await LogoColorSampler.colors(for: sampledEventLogo))
            guard !Task.isCancelled, color != accent else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                accent = color
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AsyncImage(url: VLRAPI.imageURL(from: match.event.image.preferred(for: colorScheme))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "trophy.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(match.event.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if !eventDetail.isEmpty {
                    Text(eventDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            accessory()
        }
    }

    private func team(_ team: V3TeamRef?, position: Int) -> some View {
        VStack(spacing: 8) {
            MatchTeamLogo(team: team, matchID: match.id, teamPosition: position, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    if let flag = countryFlag(team?.countryCode) {
                        Text(flag)
                            .font(.system(size: 11))
                            .frame(width: 18, height: 18)
                            .background(Color(.secondarySystemBackground), in: Circle())
                            .offset(x: 5, y: 4)
                            .accessibilityHidden(true)
                    }
                }

            Text(team?.name ?? "TBD")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .opacity(dimmedTeamPosition == position ? 0.45 : 1)
    }

    private var surface: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let accent {
                LinearGradient(
                    colors: [accent.opacity(colorScheme == .dark ? 0.3 : 0.16), accent.opacity(0)],
                    startPoint: .topLeading,
                    endPoint: UnitPoint(x: 0.75, y: 1)
                )
            }
        }
    }

    private var eventDetail: String {
        [match.event.stage, match.event.series].compactMap { $0 }.joined(separator: " · ")
    }
}

enum MatchCardMetrics {
    static let cornerRadius: CGFloat = 24
}

/// Soft press-down feedback for tappable match cards.
struct MatchCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// Picks a card tint from a logo's colours: the most vivid one, or none for
/// monochrome logos, whose greys would only muddy the surface.
enum MatchCardAccent {
    static func color(from colors: LogoColors?) -> Color? {
        guard let colors else { return nil }
        let scored = [colors.background, colors.primary, colors.secondary, colors.detail]
            .compactMap { $0 }
            .map { color -> (color: UIColor, score: CGFloat) in
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
                    return (color, 0)
                }
                return (color, saturation * min(brightness * 1.5, 1))
            }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0.25 else { return nil }
        return Color(uiColor: best.color)
    }
}

func countryFlag(_ code: String?) -> String? {
    guard let code, code.count == 2 else { return nil }
    let scalars = code.uppercased().unicodeScalars.compactMap {
        UnicodeScalar(127_397 + Int($0.value))
    }
    guard scalars.count == 2 else { return nil }
    return String(String.UnicodeScalarView(scalars))
}

struct MatchTeamSummary: View {
    let team: V3TeamRef?
    let logoSize: CGFloat
    let matchID: Int?
    let teamPosition: Int

    var body: some View {
        VStack(spacing: 7) {
            MatchTeamLogo(
                team: team,
                matchID: matchID,
                teamPosition: teamPosition,
                size: logoSize
            )

            HStack(spacing: 4) {
                Text(team?.name ?? "Team unavailable")
                    .font(.caption.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                if team?.isWinner == true {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Winner")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }
}

struct MatchTeamLogo: View {
    let team: V3TeamRef?
    let matchID: Int?
    let teamPosition: Int
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var hydratedTeam: V3TeamRef?

    private var logo: String? {
        hydratedTeam?.image.preferred(for: colorScheme)
            ?? team?.image.preferred(for: colorScheme)
    }

    var body: some View {
        AsyncImage(url: VLRAPI.imageURL(from: logo)) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Image("unknown_team")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: hydrationTaskID) {
            await hydrateMissingLogo()
        }
    }

    /// Undecided bracket slots ("TBD") have no logo in the match detail either, so
    /// fetching the detail for them is wasted work.
    private var isPlaceholderTeam: Bool {
        let name = team?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.caseInsensitiveCompare("TBD") == .orderedSame
    }

    private var hydrationTaskID: String {
        "\(matchID ?? -1)|\(team?.name ?? "")|\(logo ?? "")"
    }

    @MainActor
    private func hydrateMissingLogo() async {
        guard VLRAPI.imageURL(from: logo) == nil, let matchID, !isPlaceholderTeam else { return }

        do {
            let result = try await V3MatchDetailRepository.shared.detail(id: matchID)
            try Task.checkCancellation()

            let matchingTeam = result.detail.teams.first { detailTeam in
                if let teamID = team?.id, let detailTeamID = detailTeam.id {
                    return teamID == detailTeamID
                }
                return detailTeam.name.compare(
                    team?.name ?? "",
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            let positionalTeam = result.detail.teams.indices.contains(teamPosition)
                ? result.detail.teams[teamPosition]
                : nil

            hydratedTeam = matchingTeam ?? positionalTeam
        } catch {
            // Keep the bundled unknown-team logo when hydration is unavailable.
        }
    }
}
