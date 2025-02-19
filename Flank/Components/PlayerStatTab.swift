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
        HStack {
            Button(action: {
                self.presentingDetailedView = true
            }) {
                VStack(spacing: 20) {
                    HStack {
                        Text(stat.player)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .italic()
                            .foregroundColor(.white)
                        Text(stat.org)
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(stat.rating)
                            .foregroundColor(.white)
                    }
                    HStack() {
                        VStack {
                            Text("KDA")
                                .font(.caption)
                                .opacity(0.8)
                                .foregroundColor(.white)
                            Text(stat.kill_deaths)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack {
                            Text("ACS")
                                .font(.caption)
                                .opacity(0.8)
                                .foregroundColor(.white)
                            Text(stat.kill_deaths)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack {
                            Text("ADR")
                                .font(.caption)
                                .opacity(0.8)
                                .foregroundColor(.white)
                            Text(stat.kill_deaths)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack {
                            Text("HS%")
                                .font(.caption)
                                .opacity(0.8)
                                .foregroundColor(.white)
                            Text(stat.kill_deaths)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack {
                            Text("Clutch")
                                .font(.caption)
                                .opacity(0.8)
                                .foregroundColor(.white)
                            Text(stat.kill_deaths)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack {
                            Text("KPR")
                                .font(.caption)
                                .opacity(0.8)
                                .foregroundColor(.white)
                            Text(stat.kill_deaths)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(red: 0.18, green: 0.18, blue: 0.18))
                .cornerRadius(10)
            }
        }
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
                        Text("Kill/Death/Assist")
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
