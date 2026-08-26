//
//  PlayerStatTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 11/02/2025.
//

import SwiftUI

struct PlayerStatTab: View {
    let stat: PlayerStats
    
    @State private var presentingDetailedView = false
    
    init(stat: PlayerStats) {
        self.stat = stat
    }
    
    var body: some View {
        Group {
            if let playerID = stat.player_id.flatMap(Int.init) {
                NavigationLink {
                    PlayerProfileView(playerID: playerID, name: stat.player, source: "stats")
                } label: {
                    statCard
                }
                .accessibilityHint("Opens player profile")
            } else {
                Button {
                    presentingDetailedView = true
                } label: {
                    statCard
                }
                .accessibilityHint("Shows available player statistics")
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $presentingDetailedView) {
            VStack(spacing: 0) {
                HStack {
                    VStack {
                        HStack {
                            Text(stat.player)
                                .font(.title)
                                .fontWeight(.bold)
                                .italic()
                            Text(stat.org)
                                .font(.headline)
                                .opacity(0.8)
                            Spacer()
                        }
                        HStack {
                            Text("Rating")
                                .fontWeight(.semibold)
                                .font(.subheadline)
                            Spacer()
                                .frame(width: 20)
                            Text(stat.rating)
                                .opacity(0.8)
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                    Spacer()
                    VStack {
                        Text("Top Agents")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .opacity(0.8)
                        HStack {
                            ForEach(stat.agents, id: \.self) { agent in
                                Image(agent)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 30)
                            }
                        }
                    }
                }
                .padding(.vertical)
                .background(Color(UIColor.systemBackground))
                
                Divider()
                ScrollView {
                    Spacer()
                    HStack {
                        Text("Rounds played")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.rounds_played)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Average combat score")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.average_combat_score)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Kills per round")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.kills_per_round)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Kill/Death ratio")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.kill_deaths)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("KAST")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.kill_assists_survived_traded)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Average damage per round")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.average_damage_per_round)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Assists per round")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.assists_per_round)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("First kills per round")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.first_kills_per_round)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("First deaths per round")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.first_deaths_per_round)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Headshot percentage")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.headshot_percentage)
                            .fontWeight(.light)
                    }
                    HStack {
                        Text("Clutch success rate")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stat.clutch_success_percentage)
                            .fontWeight(.light)
                    }
                }
            }
            .padding()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var statCard: some View {
        VStack(spacing: 20) {
            HStack {
                Text(stat.player)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .italic()
                    .foregroundStyle(.primary)
                Text(stat.org)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stat.rating)
                    .foregroundStyle(.primary)
            }
            HStack {
                compactStat("K/D", stat.kill_deaths)
                Spacer()
                compactStat("ACS", stat.average_combat_score)
                Spacer()
                compactStat("ADR", stat.average_damage_per_round)
                Spacer()
                compactStat("HS%", stat.headshot_percentage)
                Spacer()
                compactStat("Clutch", stat.clutch_success_percentage)
                Spacer()
                compactStat("KPR", stat.kills_per_round)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stat.player), \(stat.org), rating \(stat.rating)")
    }

    private func compactStat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "–" : value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    PlayerStatTab(stat: PlayerStats(
        player: "berryx",
        org: "HVND",
        agents: ["jett", "raze", "neon"],
        rounds_played: "213",
        rating: "1.25",
        average_combat_score: "280.9",
        kill_deaths: "1.38",
        kill_assists_survived_traded: "69%",
        average_damage_per_round: "178.0",
        kills_per_round: "0.99",
        assists_per_round: "0.16",
        first_kills_per_round: "0.18",
        first_deaths_per_round: "0.19",
        headshot_percentage: "26%",
        clutch_success_percentage: "26%"
    ))
}
