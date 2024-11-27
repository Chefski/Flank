//
//  LiveMatchTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import FluidGradient
import BetterSafariView
import UIImageColors

struct LiveMatchTab: View {
    let match: LiveMatch
    
    init(match: LiveMatch) {
        self.match = match
    }
    
    @State private var team1Color: Color = Color(red: 0.35, green: 0.35, blue: 0.35)
    @State private var team2Color: Color = Color(red: 0.06, green: 0.06, blue: 0.06)
    
    @State private var presentingSafariView = false
    
    var body: some View {
        VStack {
            VStack {
                ZStack {
                    FluidGradient(blobs: [team1Color, team2Color],
                                  highlights: [team1Color, team2Color, team2Color, team1Color],
                                  speed: 1.00,
                                  blur: 0.75)
                    .background(.quaternary)
                    .opacity(0.75)
                    .frame(height: 138)
                    HStack {
                        Spacer()
                        VStack {
                            AsyncImage(
                                url: URL(string: match.team1_logo),
                                content: { image in
                                    image.resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 70, height: 70)
                                },
                                placeholder: {
                                    Image("unknown_team")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 70, height: 70)
                                }
                            )
                            .onAppear {
                                if let url = URL(string: match.team1_logo) {
                                    URLSession.shared.dataTask(with: url) { data, _, _ in
                                        if let data = data, let uiImage = UIImage(data: data) {
                                            uiImage.getColors { colors in
                                                if let backgroundColor = colors?.background {
                                                    team1Color = Color(backgroundColor)
                                                }
                                            }
                                        }
                                    }.resume()
                                }
                            }
                            Text(match.team1)
                                .font(.system(size: 11, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.top, 5)
                                .frame(width: 70, alignment: .top)
                        }
                        Spacer()
                        VStack(spacing: 4) {
                            Text("(\(getRoundScore(t1: match.team1_round_t, t2: match.team2_round_t, ct1: match.team1_round_ct, ct2: match.team2_round_ct)))")
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(0.8)
                            Text("\(match.score1) - \(match.score2)")
                                .font(.system(size: 15, weight: .bold))
                            Text(match.current_map)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.32))
                                .cornerRadius(10)
                        }
                        Spacer()
                        VStack {
                            AsyncImage(
                                url: URL(string: match.team2_logo),
                                content: { image in
                                    image.resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 70, height: 70)
                                },
                                placeholder: {
                                    Image("unknown_team")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 70, height: 70)
                                }
                            )
                            .onAppear {
                                if let url = URL(string: match.team2_logo) {
                                    URLSession.shared.dataTask(with: url) { data, _, _ in
                                        if let data = data, let uiImage = UIImage(data: data) {
                                            uiImage.getColors { colors in
                                                if let backgroundColor = colors?.background {
                                                    team2Color = Color(backgroundColor)
                                                }
                                            }
                                        }
                                    }.resume()
                                }
                            }
                            Text(match.team2)
                                .font(.system(size: 11, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.top, 5)
                                .frame(width: 70, alignment: .top)
                        }
                        Spacer()
                    }
                }
                HStack {
                    VStack {
                        Text(match.match_event)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        
                            .frame(width: 190, alignment: .topLeading)
                        Text(match.match_series)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                        
                            .frame(width: 190, alignment: .topLeading)
                    }
                    Spacer()
                    Button(action: {
                        self.presentingSafariView = true
                    }) {
                        Text("More")
                            .bold()
                        Image(systemName: "arrow.up.forward.app.fill")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 25)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.25))
                    .background(.ultraThickMaterial)
                    .cornerRadius(40)
                    .sheet(isPresented: $presentingSafariView) {
                        SafariView(
                            url: URL(string: match.match_page)!,
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
                .padding(.horizontal)
                .padding(.vertical, 5)
                Spacer()
            }
            .frame(width: 365)
            .background(Color(red: 0.18, green: 0.18, blue: 0.18))
            .cornerRadius(20)
        }
    }
    
    private func getTeamImage(for teamName: String) -> UIImage {
        if let image = UIImage(named: teamName) {
            return image
        } else if teamName.hasSuffix("GC"), let image = UIImage(named: String(teamName.dropLast(2)).trimmingCharacters(in: .whitespaces)) {
            return image
        } else {
            return UIImage(named: "unknown_team")!
        }
    }
    
    private func getRoundScore(t1: String, t2: String, ct1: String, ct2: String) -> String {
        if t1 != "N/A" && ct2 != "N/A" {
            return "\(t1) - \(ct2)"
        } else if ct1 != "N/A" && t2 != "N/A" {
            return "\(ct1) - \(t2)"
        } else {
            return "0 - 0"
        }
    }
}

struct LiveMatchTab_Previews: PreviewProvider {
    static var previews: some View {
        let match = LiveMatch(team1: "FNATIC", team2: "Cloud9", flag1: "10", flag2: "5", score1: "10", score2: "5", team1_logo: "https://owcdn.net/img/62a40cc2b5e29.png", team2_logo: "https://owcdn.net/img/628addcbd509e.png", team1_round_ct: "N/A", team1_round_t: "8", team2_round_ct: "12", team2_round_t: "N/A", map_number: "2", current_map: "Bind", time_until_match: "team1_round_ct", match_series: "Regular Season: Week 3", match_event: "Champions Tour 2024: Americas Stage 1", unix_timestamp: "648379", match_page: "match_page")
        LiveMatchTab(match: match)
    }
}
