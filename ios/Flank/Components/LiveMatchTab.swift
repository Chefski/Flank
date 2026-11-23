//
//  LiveMatchTab.swift
//  Flank
//

import FluidGradient
import SwiftUI
import UIImageColors

struct LiveMatchTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let match: V3Match

    @State private var firstTeamColor = Color(red: 0.35, green: 0.35, blue: 0.35)
    @State private var secondTeamColor = Color(red: 0.08, green: 0.08, blue: 0.1)

    private var firstTeamLogo: String? {
        match.firstTeam?.image.preferred(for: .dark)
    }

    private var secondTeamLogo: String? {
        match.secondTeam?.image.preferred(for: .dark)
    }

    var body: some View {
        NavigationLink {
            MatchDetailView(match: match)
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    FluidGradient(
                        blobs: [firstTeamColor, secondTeamColor],
                        highlights: [firstTeamColor, secondTeamColor, secondTeamColor, firstTeamColor],
                        speed: reduceMotion ? 0 : 1,
                        blur: 0.75
                    )
                    .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                    .opacity(0.78)

                    HStack(spacing: 12) {
                        MatchTeamSummary(
                            team: match.firstTeam,
                            logoSize: 58,
                            matchID: match.id,
                            teamPosition: 0
                        )

                        VStack(spacing: 5) {
                            Text(scoreText)
                                .font(.headline.weight(.bold))
                                .monospacedDigit()
                            Text(match.statusText ?? "LIVE")
                                .font(.caption2.weight(.bold))
                                .textCase(.uppercase)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.25), in: Capsule())
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        MatchTeamSummary(
                            team: match.secondTeam,
                            logoSize: 58,
                            matchID: match.id,
                            teamPosition: 1
                        )
                    }
                    .padding(.horizontal, 14)
                }
                .frame(minHeight: 138)

                HStack(spacing: 12) {
                    eventLogo

                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.event.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if !eventDetail.isEmpty {
                            Text(eventDetail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(
                    .regular.tint(.black.opacity(0.18)),
                    in: .rect(cornerRadius: 0)
                )
            }
            .foregroundStyle(.white)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
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
        .accessibilityHint("Opens live native match details")
        .task(id: "\(firstTeamLogo ?? "")|\(secondTeamLogo ?? "")") {
            async let first = sampledColor(
                from: firstTeamLogo,
                fallback: Color(red: 0.35, green: 0.35, blue: 0.35)
            )
            async let second = sampledColor(
                from: secondTeamLogo,
                fallback: Color(red: 0.08, green: 0.08, blue: 0.1)
            )
            let colors = await (first, second)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                firstTeamColor = colors.0
                secondTeamColor = colors.1
            }
        }
    }

    private var eventLogo: some View {
        AsyncImage(url: VLRAPI.imageURL(from: match.event.image.preferred(for: .dark))) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "trophy.fill")
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var scoreText: String {
        "\(match.firstTeam?.score.map(String.init) ?? "–") - \(match.secondTeam?.score.map(String.init) ?? "–")"
    }

    private var eventDetail: String {
        [match.event.stage, match.event.series].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        "Live, \(match.firstTeam?.name ?? "team one") versus \(match.secondTeam?.name ?? "team two"), score \(scoreText), \(match.event.name)"
    }

    private func sampledColor(from logo: String?, fallback: Color) async -> Color {
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
