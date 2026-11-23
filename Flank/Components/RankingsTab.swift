//
//  RankingsTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 23/04/2024.
//

import SwiftUI

struct RankingsTab: View {
    @Environment(\.colorScheme) private var colorScheme
    private static let fallbackColor = Color(red: 0.35, green: 0.35, blue: 0.35)

    @State private var primaryTeamColor: Color
    @State private var isSheetPresented = false
    @Namespace private var sheetTransitionNamespace
    
    let team: Rankings
    let searchText: String

    private let sheetTransitionID = "team-details"
    
    init(team: Rankings, searchText: String) {
        self.team = team
        self.searchText = searchText
        // Start from an already-sampled colour so scrolling back doesn't flash the fallback.
        // The dark logo is a guess here; the task below corrects it for the real scheme.
        let cached = LogoColorSampler.cachedColors(
            for: VLRAPI.preferredLogo(fallback: team.logo, light: team.logo_light, dark: team.logo_dark, for: .dark)
        ) ?? LogoColorSampler.cachedColors(
            for: VLRAPI.preferredLogo(fallback: team.logo, light: team.logo_light, dark: team.logo_dark, for: .light)
        )
        _primaryTeamColor = State(initialValue: Self.tint(from: cached) ?? Self.fallbackColor)
    }

    private var logo: String? {
        VLRAPI.preferredLogo(
            fallback: team.logo,
            light: team.logo_light,
            dark: team.logo_dark,
            for: colorScheme
        )
    }

    private var teamTint: Color {
        primaryTeamColor.opacity(colorScheme == .dark ? 0.42 : 0.18)
    }
    
    var body: some View {
        HStack(spacing: 17) {
            Text(team.rank)
                .font(.system(size: 17, weight: .bold))
            AsyncImage(
                url: VLRAPI.imageURL(from: logo),
                content: { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 35, maxHeight: 35)
                },
                placeholder: {
                    Image(systemName: "person.2.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 35, maxHeight: 35)
                        .foregroundStyle(.secondary)
                }
            )
            .task(id: logo) {
                if let color = Self.tint(from: await LogoColorSampler.colors(for: logo)),
                   !Task.isCancelled {
                    primaryTeamColor = color
                }
            }
            Text(team.team)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Text(team.record)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(teamTint)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .inset(by: 0.5)
                .stroke(.primary.opacity(0.14), lineWidth: 1)
        )
        .matchedTransitionSource(id: sheetTransitionID, in: sheetTransitionNamespace) { source in
            source.clipShape(.rect(cornerRadius: 20))
        }
        .onTapGesture {
            self.isSheetPresented = true
        }
        .sheet(isPresented: $isSheetPresented, content: {
            VStack {
                Spacer()
                AsyncImage(
                    url: VLRAPI.imageURL(from: logo),
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
                }
                .padding(.vertical, 1)
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 30)
            .navigationTransition(.zoom(sourceID: sheetTransitionID, in: sheetTransitionNamespace))
            .presentationDetents([.fraction(0.5)])
            .presentationBackground {
                ZStack {
                    Rectangle()
                        .fill(.thinMaterial)
                    Rectangle()
                        .fill(teamTint)
                }
            }
            .presentationDragIndicator(.visible)
        })
    }
    
    /// Card tint for a logo's colours; near-black logos get grey so the tint stays visible.
    private static func tint(from colors: LogoColors?) -> Color? {
        guard let background = colors?.background else { return nil }
        return background.isCloseToBlack() ? .gray : Color(background)
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
            logo: "//owcdn.net/img/62875027c8e06.png",
            logo_light: "//owcdn.net/img/62875027c8e06.png",
            logo_dark: nil
        )
        
        return RankingsTab(team: team, searchText: "")
    }
}
