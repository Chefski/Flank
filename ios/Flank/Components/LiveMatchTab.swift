//
//  LiveMatchTab.swift
//  Flank
//

import FluidGradient
import SwiftUI

/// Live match card: the shared match card layout on an always-dark surface that
/// slowly blends both teams' colours.
struct LiveMatchTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let match: V3Match

    private static let firstFallback = Color(red: 0.35, green: 0.35, blue: 0.38)
    private static let secondFallback = Color(red: 0.16, green: 0.16, blue: 0.2)

    @State private var firstTeamColor: Color
    @State private var secondTeamColor: Color

    init(match: V3Match) {
        self.match = match
        // Start from already-sampled colours so a reused card doesn't flash the fallback.
        _firstTeamColor = State(initialValue: Self.cardColor(
            LogoColorSampler.cachedColors(for: match.firstTeam?.image.preferred(for: .dark)),
            fallback: Self.firstFallback
        ))
        _secondTeamColor = State(initialValue: Self.cardColor(
            LogoColorSampler.cachedColors(for: match.secondTeam?.image.preferred(for: .dark)),
            fallback: Self.secondFallback
        ))
    }

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
            MatchCardLayout(match: match) {
                LiveBadge()
            } center: {
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Text(score(match.firstTeam))
                        Text("–")
                            .foregroundStyle(.tertiary)
                        Text(score(match.secondTeam))
                    }
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                    if let progress {
                        Text(progress)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .background { surface }
            .matchCardChrome(strokeOpacity: 0.12)
            // The live card is always dark, so text and logos resolve their dark variants.
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(MatchCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens live native match details")
        .task(id: "\(firstTeamLogo ?? "")|\(secondTeamLogo ?? "")") {
            async let first = LogoColorSampler.colors(for: firstTeamLogo)
            async let second = LogoColorSampler.colors(for: secondTeamLogo)
            let colors = await (first, second)
            guard !Task.isCancelled else { return }
            let firstColor = Self.cardColor(colors.0, fallback: Self.firstFallback)
            let secondColor = Self.cardColor(colors.1, fallback: Self.secondFallback)
            guard firstColor != firstTeamColor || secondColor != secondTeamColor else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                firstTeamColor = firstColor
                secondTeamColor = secondColor
            }
        }
    }

    private var surface: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)

            FluidGradient(
                blobs: [firstTeamColor, secondTeamColor],
                highlights: [firstTeamColor, secondTeamColor, secondTeamColor, firstTeamColor],
                speed: reduceMotion ? 0 : 0.6,
                blur: 0.8
            )
            .opacity(0.6)

            // Settles the bottom so the team names stay crisp over bright logo colours.
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func score(_ team: V3TeamRef?) -> String {
        team?.score.map(String.init) ?? "–"
    }

    /// Extra progress from the API (e.g. the current map), skipping the bare "LIVE"
    /// that the badge already shows.
    private var progress: String? {
        guard let text = match.statusText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.caseInsensitiveCompare("live") != .orderedSame else { return nil }
        return text
    }

    private var accessibilityLabel: String {
        "Live, \(match.firstTeam?.name ?? "team one") versus \(match.secondTeam?.name ?? "team two"), score \(score(match.firstTeam)) to \(score(match.secondTeam)), \(match.event.name)"
    }

    private static func cardColor(_ colors: LogoColors?, fallback: Color) -> Color {
        colors?.background.map(Color.init) ?? fallback
    }
}
