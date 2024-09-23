//
//  RankingsTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 23/04/2024.
//

import SwiftUI
import UIImageColors

struct RankingsTab: View {
    @State private var primaryTeamColor: Color = Color(red: 0.35, green: 0.35, blue: 0.35)
    @State private var isSheetPresented = false
    
    let team: Rankings
    
    init(team: Rankings) {
        self.team = team
    }
    
    var body: some View {
        HStack(spacing: 17) {
            Text(team.rank)
                .font(.system(size: 17, weight: .bold))
            AsyncImage(
                url: URL(string: "https:\(team.logo)"),
                content: { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 35, maxHeight: 35)
                },
                placeholder: {
                    Image("unknown_team")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 35, maxHeight: 35)
                }
            )
            .onAppear {
                Task {
                    fetchColors()
                }
            }
            Text(team.team)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Text(team.record)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.80))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background(primaryTeamColor.opacity(0.50))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .inset(by: 0.5)
                .stroke(.white.opacity(0.2), lineWidth: 1)
            
        )
        .onTapGesture {
            self.isSheetPresented = true
        }
        .sheet(isPresented: $isSheetPresented, content: {
            VStack {
                Spacer()
                AsyncImage(
                    url: URL(string: "https:\(team.logo)"),
                    content: { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 135, maxHeight: 135)
                            .cornerRadius(10)
                    },
                    placeholder: {
                        ProgressView()
                    }
                )
                Text(team.team)
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                VStack {
                    Text("Earnings")
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.75)
                    Text(team.earnings)
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.vertical, 1)
                VStack {
                    Text("Country")
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.75)
                    Text(team.country)
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.vertical, 1)
                VStack {
                    Text("Last played team")
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.75)
                    Text(team.last_played_team)
                        .font(.system(size: 15, weight: .semibold))
                        .presentationDetents([.fraction(0.5)])
                        .presentationBackground(Material.regular)
                        .presentationDragIndicator(.visible)
                }
                .padding(.vertical, 1)
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 30)
        })
    }
    
    private func fetchColors() {
        if let url = URL(string: "https:\(team.logo)") {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data, let uiImage = UIImage(data: data) {
                    uiImage.getColors { colors in
                        if let backgroundColor = colors?.background {
                            let isCloseToBlack = backgroundColor.isCloseToBlack()
                            
                            // Set the primary team color accordingly
                            if isCloseToBlack {
                                primaryTeamColor = .white
                            } else {
                                primaryTeamColor = Color(backgroundColor)
                            }
                        }
                    }
                }
            }.resume()
        }
    }
}

extension UIColor {
    func isCloseToBlack() -> Bool {
        // Define a threshold value for darkness (adjust as needed)
        let darknessThreshold: CGFloat = 0.2
        
        // Calculate the luminance and saturation of the color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        
        // Check if the color is close to black based on luminance and saturation
        return brightness < darknessThreshold && saturation < 0.1
    }
}


struct RankingsTab_Preview: PreviewProvider {
    static var previews: some View {
        let team = Rankings(
            rank: "1",
            team: "Sentinels",
            country: "Canada",
            last_played: "Last Played Date",
            last_played_team: "Opponent Team Name",
            last_played_team_logo: "URL to Opponent Team Logo",
            record: "3-1",
            earnings: "$1,346,854",
            logo: "//owcdn.net/img/62875027c8e06.png"
        )
        
        return RankingsTab(team: team)
    }
}

