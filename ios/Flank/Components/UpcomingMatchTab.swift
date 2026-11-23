//
//  UpcomingMatchTab.swift
//  Flank
//

import SwiftUI

struct UpcomingMatchTab: View {
    let match: V3Match

    var body: some View {
        NavigationLink {
            MatchDetailView(match: match)
        } label: {
            VStack(spacing: 14) {
                Text(scheduleText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))

                HStack(spacing: 10) {
                    MatchTeamSummary(
                        team: match.firstTeam,
                        logoSize: 46,
                        matchID: match.id,
                        teamPosition: 0
                    )

                    HStack(spacing: 7) {
                        flag(match.firstTeam?.countryCode)
                        Text("vs")
                            .font(.subheadline.weight(.bold))
                            .fixedSize()
                        flag(match.secondTeam?.countryCode)
                    }
                    .foregroundStyle(.white)

                    MatchTeamSummary(
                        team: match.secondTeam,
                        logoSize: 46,
                        matchID: match.id,
                        teamPosition: 1
                    )
                }

                VStack(spacing: 2) {
                    Text(match.event.name)
                        .font(.caption.weight(.semibold))
                    Text([match.event.stage, match.event.series].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 175)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                ZStack {
                    Color(red: 0.08, green: 0.08, blue: 0.08)
                    LinearGradient(
                        colors: [.clear, Color(red: 0.42, green: 0.3, blue: 0.17).opacity(0.28)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens native match details")
    }

    private var scheduleText: String {
        if let relative = match.display.relative, !relative.isEmpty {
            if let startsAt = match.startsAt {
                return "\(relative) (@ \(startsAt.formatted(date: .omitted, time: .shortened)))"
            }
            return relative
        }
        if let startsAt = match.startsAt {
            return startsAt.formatted(date: .abbreviated, time: .shortened)
        }
        return match.statusText ?? match.status.displayName
    }

    @ViewBuilder
    private func flag(_ countryCode: String?) -> some View {
        if let countryCode, !countryCode.isEmpty {
            Text(countryFlag(countryCode))
                .font(.body)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.1), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.1), lineWidth: 0.5) }
                .accessibilityLabel(countryCode.uppercased())
        }
    }

    private func countryFlag(_ code: String) -> String {
        let scalars = code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127_397 + Int($0.value))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private var accessibilityLabel: String {
        "\(match.firstTeam?.name ?? "Team one") versus \(match.secondTeam?.name ?? "Team two"), \(scheduleText), \(match.event.name)"
    }
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

    @State private var hydratedTeam: V3TeamRef?

    private var logo: String? {
        hydratedTeam?.image.preferred(for: .dark)
            ?? team?.image.preferred(for: .dark)
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

    private var hydrationTaskID: String {
        "\(matchID ?? -1)|\(team?.name ?? "")|\(logo ?? "")"
    }

    @MainActor
    private func hydrateMissingLogo() async {
        guard VLRAPI.imageURL(from: logo) == nil, let matchID else { return }

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
