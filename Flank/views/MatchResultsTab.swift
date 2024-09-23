//
//  MatchResultsTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import SmoothGradient
import UIImageColors

struct MatchResultsTab: View {
    @State private var team1Color: Color = Color(red: 0.35, green: 0.35, blue: 0.35)
    @State private var team2Color: Color = Color(red: 0.06, green: 0.06, blue: 0.06)
    
    let match: Match
    
    init(match: Match) {
        self.match = match
    }
    
    var body: some View {
        LazyVStack {
            Spacer()
            HStack{
                VStack {
                    let teamName = match.team1.hasSuffix(" GC") ? String(match.team1.dropLast(3)) : match.team1
                    Image(uiImage: UIImage(named: teamName) ?? UIImage(named: "unknown_team")!)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                    Text(match.team1)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 125)
                        .multilineTextAlignment(.center)
                }
                .opacity(Int(match.score1) ?? 0 > Int(match.score2) ?? 0 ? 1.0 : 0.8)
                Text(match.score1)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 24, height: 24)
                    .padding(3)
//                    .background(.white.opacity(0.1))
                    .background(Int(match.score1) ?? 0 > Int(match.score2) ?? 0 ? .green.opacity(0.7) : .red.opacity(0.4))
                    .cornerRadius(49)
                    .overlay(
                        RoundedRectangle(cornerRadius: 49)
                            .inset(by: 0.25)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                        
                    )
                Text("vs")
                    .font(.system(size: 15, weight: .bold))
                    .frame(minWidth: 24, maxWidth: 40)
                    .fixedSize(horizontal: true, vertical: false)
                Text(match.score2)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 24, height: 24)
                    .padding(3)
//                    .background(.white.opacity(0.1))
                    .background(Int(match.score1) ?? 0 < Int(match.score2) ?? 0 ? .green.opacity(0.7) : .red.opacity(0.4))
                    .cornerRadius(49)
                    .overlay(
                        RoundedRectangle(cornerRadius: 49)
                            .inset(by: 0.25)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                        
                    )
                VStack {
                    let teamName = match.team2.hasSuffix(" GC") ? String(match.team2.dropLast(3)) : match.team2
                    Image(uiImage: UIImage(named: teamName) ?? UIImage(named: "unknown_team")!)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                    Text(match.team2)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 125)
                        .multilineTextAlignment(.center)
                }
                .opacity(Int(match.score1) ?? 0 > Int(match.score2) ?? 0 ? 0.8 : 1.0)
            }
            Spacer()
            Spacer()
            VStack {
                Text(match.tournament_name)
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.75)
                Text(match.round_info)
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.75)
            }
        }
        .frame(height: 175)
        .background(
            LinearGradient(
                stops: [
                    Gradient.Stop(color: leftGradientColor, location: 0.00),
                    Gradient.Stop(color: rightGradientColor, location: 1.00),
                ],
                startPoint: UnitPoint(x: 0, y: 0.5),
                endPoint: UnitPoint(x: 1, y: 0.5)
            )
        )
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
        
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .inset(by: 0.5)
                .stroke(.white.opacity(0.1), lineWidth: 1)
            
        )
    }
    
    private var leftGradientColor: Color {
        Int(match.score1) ?? 0 > Int(match.score2) ?? 0 ? winColor : loseColor
    }
    
    private var rightGradientColor: Color {
        Int(match.score2) ?? 0 > Int(match.score1) ?? 0 ? winColor : loseColor
    }
    
    private let winColor = Color(red: 0.24, green: 1, blue: 0.18).opacity(0.2)
    private let loseColor = Color(red: 0.06, green: 0.06, blue: 0.06)
}

struct MatchResultsTab_Preview: PreviewProvider {
    static var previews: some View {
        let match = Match(
            team1: "Sentinels",
            team2: "Rex Regum Qeon",
            score1: "2",
            score2: "1",
            flag1: "Flag A",
            flag2: "Flag B",
            time_completed: "2024-04-13 15:30",
            round_info: "Promotion Cup-Upper Semifinals",
            tournament_name: "Challengers League 2024 East Surge: Split 2",
            match_page: "/381352/esc-gaming-vs-genziary-challengers-league-2024-east-surge-split-2-promotion-cup-ubsf",
            tournament_icon: "https://owcdn.net/img/63a1b49fcf14b.png"
        )
        
        return MatchResultsTab(match: match)
    }
}
