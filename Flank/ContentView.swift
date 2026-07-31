//
//  ContentView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .matches
    
    enum Tab {
        case matches
        case rankings
        case news
        case stats
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label(NSLocalizedString("nav_matches", comment: ""), systemImage: "gamecontroller.fill")
                }
                .tag(Tab.matches)
            RankingsView()
                .tabItem {
                    Label(NSLocalizedString("nav_rankings", comment: ""), systemImage: "medal.fill")
                }
                .tag(Tab.rankings)
            
            NewsView()
                .tabItem {
                    Label(NSLocalizedString("nav_news", comment: ""), systemImage: "newspaper.fill")
                }
                .tag(Tab.news)
            StatsView()
                .tabItem {
                    Label(NSLocalizedString("nav_stats", comment: ""), systemImage: "chart.bar.fill")
                }
                .tag(Tab.stats)
        }
        .tint(.primary)
    }
}

#Preview {
    ContentView()
}
