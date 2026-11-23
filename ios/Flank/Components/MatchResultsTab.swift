//
//  MatchResultsTab.swift
//  Flank
//

import SwiftUI

struct MatchResultsTab: View {
    let match: V3Match

    var body: some View {
        MatchListCard(
            match: match,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: "Opens completed native match details",
            dimmedTeamPosition: loserPosition
        ) {
            if let completedText {
                Text(completedText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } center: {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    score(match.firstTeam, position: 0)
                    Text("–")
                        .foregroundStyle(.tertiary)
                    score(match.secondTeam, position: 1)
                }
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()

                Text("Final")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func score(_ team: V3TeamRef?, position: Int) -> some View {
        Text(team?.score.map(String.init) ?? "–")
            .foregroundStyle(loserPosition == position ? .secondary : .primary)
    }

    /// The non-winning slot, when the API marks exactly one side as the winner.
    private var loserPosition: Int? {
        switch (match.firstTeam?.isWinner == true, match.secondTeam?.isWinner == true) {
        case (true, false): 1
        case (false, true): 0
        default: nil
        }
    }

    private var completedText: String? {
        if let relative = match.display.relative, !relative.isEmpty { return relative }
        return match.startsAt?.formatted(date: .abbreviated, time: .omitted)
    }

    private var accessibilityLabel: String {
        let first = match.firstTeam
        let second = match.secondTeam
        return "Completed, \(first?.name ?? "team one") \(first?.score.map(String.init) ?? "score unavailable"), \(second?.name ?? "team two") \(second?.score.map(String.init) ?? "score unavailable"), \(match.event.name)"
    }
}
