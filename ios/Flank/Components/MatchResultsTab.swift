//
//  MatchResultsTab.swift
//  Flank
//

import SwiftUI
import UIImageColors

struct MatchResultsTab: View {
    let match: V3Match

    @State private var eventColor = Color(red: 0.2, green: 0.2, blue: 0.22)

    private var eventLogo: String? {
        match.event.image.preferred(for: .dark)
    }

    var body: some View {
        NavigationLink {
            MatchDetailView(match: match)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    resultTeam(match.firstTeam, teamPosition: 0, leadingWinnerGradient: true)
                    resultTeam(match.secondTeam, teamPosition: 1, leadingWinnerGradient: false)
                }
                .background(Color.black.opacity(0.94))

                HStack(spacing: 12) {
                    AsyncImage(url: VLRAPI.imageURL(from: eventLogo)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.event.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if !eventDetail.isEmpty {
                            Text(eventDetail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.74))
                                .lineLimit(2)
                        }
                        if let completedText {
                            Text(completedText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(16)
                .background {
                    LinearGradient(
                        colors: [.black, eventColor.opacity(0.48)],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                }
            }
            .foregroundStyle(.white)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens completed native match details")
        .task(id: eventLogo) {
            let color = await sampledColor(from: eventLogo)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                eventColor = color
            }
        }
    }

    private func resultTeam(
        _ team: V3TeamRef?,
        teamPosition: Int,
        leadingWinnerGradient: Bool
    ) -> some View {
        VStack(spacing: 9) {
            Text(team?.name ?? "Team unavailable")
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                MatchTeamLogo(
                    team: team,
                    matchID: match.id,
                    teamPosition: teamPosition,
                    size: 48
                )

                Text(team?.score.map(String.init) ?? "–")
                    .font(.title.weight(.bold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if team?.isWinner == true {
                LinearGradient(
                    colors: [.black.opacity(0.2), .green.opacity(0.72)],
                    startPoint: leadingWinnerGradient ? .topTrailing : .topLeading,
                    endPoint: leadingWinnerGradient ? .bottomLeading : .bottomTrailing
                )
            }
        }
    }

    private var eventDetail: String {
        [match.event.stage, match.event.series].compactMap { $0 }.joined(separator: " · ")
    }

    private var completedText: String? {
        if let relative = match.display.relative, !relative.isEmpty { return relative }
        return match.startsAt?.formatted(date: .abbreviated, time: .shortened)
    }

    private var accessibilityLabel: String {
        let first = match.firstTeam
        let second = match.secondTeam
        return "Completed, \(first?.name ?? "team one") \(first?.score.map(String.init) ?? "score unavailable"), \(second?.name ?? "team two") \(second?.score.map(String.init) ?? "score unavailable"), \(match.event.name)"
    }

    private func sampledColor(from logo: String?) async -> Color {
        let fallback = Color(red: 0.2, green: 0.2, blue: 0.22)
        guard let url = VLRAPI.imageURL(from: logo) else { return fallback }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let image = UIImage(data: data) else {
                return fallback
            }
            return await withCheckedContinuation { continuation in
                image.getColors { colors in
                    continuation.resume(returning: colors?.background.map(Color.init) ?? fallback)
                }
            }
        } catch {
            return fallback
        }
    }
}
