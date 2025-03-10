//
//  MatchResultsTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import SmoothGradient
import UIImageColors
import BetterSafariView

struct MatchResultsTab: View {
    @State private var tournamentColor: Color = Color(red: 0, green: 0, blue: 0)
    @State private var presentingSafariView = false
    
    let match: Match
    
    private static var colorCache: [String: Color] = [:]
    
    init(match: Match) {
        self.match = match
    }
    
    var body: some View {
        LazyVStack {
            Button(action: {
                self.presentingSafariView = true
            }) {
                ZStack {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            HStack {
                                Spacer()
                                VStack {
                                    Text(match.team1)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    HStack {
                                        Image(uiImage: UIImage(named: match.team1) ?? UIImage(named: "unknown_team")!)
                                            .resizable()
                                            .frame(width: 50, height: 50)
                                        Text(match.score1)
                                            .font(.system(size: 28, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                Spacer()
                            }
                            .frame(height: 90)
                            .padding()
                            .background(
                                Int(match.score1) ?? 0 > Int(match.score2) ?? 0 ?
                                LinearGradient(
                                    stops: [
                                        Gradient.Stop(color: .black, location: 0.00),
                                        Gradient.Stop(color: .green, location: 1.00),
                                    ],
                                    startPoint: UnitPoint(x: 1, y: 1),
                                    endPoint: UnitPoint(x: 0, y: -1)
                                )
                                : nil
                            )
                            .cornerRadius(20)
                            .overlay(
                                Int(match.score1) ?? 0 > Int(match.score2) ?? 0 ?
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                                : nil
                            )
                            HStack {
                                Spacer()
                                VStack {
                                    Text(match.team2)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    HStack {
                                        Image(uiImage: UIImage(named: match.team2) ?? UIImage(named: "unknown_team")!)
                                            .resizable()
                                            .frame(width: 50, height: 50)
                                        Text(match.score2)
                                            .font(.system(size: 28, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    
                                }
                                Spacer()
                            }
                            .frame(height: 90)
                            .padding()
                            .background(
                                Int(match.score2) ?? 0 > Int(match.score1) ?? 0 ?
                                LinearGradient(
                                    stops: [
                                        Gradient.Stop(color: .black, location: 0.00),
                                        Gradient.Stop(color: .green, location: 1.00),
                                    ],
                                    startPoint: UnitPoint(x: 0, y: 1),
                                    endPoint: UnitPoint(x: 1, y: -1)
                                )
                                : nil
                            )
                            .cornerRadius(20)
                            .overlay(
                                Int(match.score2) ?? 0 > Int(match.score1) ?? 0 ?
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                                : nil
                            )
                        }
                        .background(
                            ZStack {
                                Color.black
                                LinearGradient(
                                    stops: [
                                        Gradient.Stop(color: .white.opacity(0.1), location: 0.00),
                                        Gradient.Stop(color: .black, location: 1.00),
                                    ],
                                    startPoint: UnitPoint(x: 0, y: 0),
                                    endPoint: UnitPoint(x: 0, y: 2)
                                )
                            }
                        )
                        .cornerRadius(20)
                        HStack {
                            AsyncImage(
                                url: URL(string: match.tournament_icon),
                                content: { image in
                                    image.resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 34, height: 34)
                                },
                                placeholder: {
                                    Image("unknown_team")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 30, height: 30)
                                }
                            )
                            VStack {
                                HStack {
                                    Text(match.tournament_name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                HStack {
                                    Text(match.round_info)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                HStack {
                                    Text(match.time_completed)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.75))
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                        .cornerRadius(20)
                        
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .inset(by: 0.5)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
                    .cornerRadius(20)
                    .onAppear {
                        fetchColors()
                    }
                }
                .background(
                    ZStack {
                        LinearGradient(
                            stops: [
                                Gradient.Stop(color: .black, location: 0.00),
                                Gradient.Stop(color: tournamentColor.opacity(0.4), location: 1.00),
                            ],
                            startPoint: UnitPoint(x: 1, y: 0),
                            endPoint: UnitPoint(x: 0, y: 2)
                        )
                        Color.white.opacity(0.05)
                    }
                )
                .cornerRadius(20)
            }
            .sheet(isPresented: $presentingSafariView) {
                SafariView(
                    url: URL(string: "https://vlr.gg\(match.match_page)")!,
                    configuration: SafariView.Configuration(
                        entersReaderIfAvailable: false,
                        barCollapsingEnabled: true
                    )
                )
                .preferredBarAccentColor(.clear)
                .preferredControlAccentColor(.accentColor)
                .dismissButtonStyle(.done)
            }

        }
    }
    
    private func fetchColors() {
        if let cachedColor = MatchResultsTab.colorCache[match.tournament_icon] {
            self.tournamentColor = cachedColor
            return
        }
        
        if let url = URL(string: match.tournament_icon) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data, let uiImage = UIImage(data: data) {
                    uiImage.getColors { colors in
                        if let backgroundColor = colors?.background {
                            DispatchQueue.main.async {
                                let color = Color(backgroundColor)
                                tournamentColor = color
                                MatchResultsTab.colorCache[match.tournament_icon] = color
                            }
                        }
                    }
                }
            }
            .resume()
        }
    }
}

struct MatchResultsTab_Preview: PreviewProvider {
    static var previews: some View {
        let match = Match(
            team1: "Sentinels",
            team2: "Rex Regum Qeon",
            score1: "2",
            score2: "0",
            flag1: "flag_eu",
            flag2: "flag_fi",
            time_completed: "2024-04-13 15:30",
            round_info: "Promotion Cup-Upper Semifinals",
            tournament_name: "Challengers League 2024 East Surge: Split 2",
            match_page: "/381352/esc-gaming-vs-genziary-challengers-league-2024-east-surge-split-2-promotion-cup-ubsf",
            tournament_icon: "https://owcdn.net/img/63a1b49fcf14b.png"
        )
        
        return MatchResultsTab(match: match)
    }
}
