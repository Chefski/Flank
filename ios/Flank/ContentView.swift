//
//  ContentView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .matches
    @State private var rankingsScrollToTopTrigger = 0
    @State private var hasTrackedInitialTab = false
    
    enum Tab {
        case matches
        case rankings
        case news
        case stats
    }
    
    var body: some View {
        TabView(selection: tabSelection) {
            HomeView()
                .tabItem {
                    Label(NSLocalizedString("nav_matches", comment: ""), systemImage: "gamecontroller.fill")
                }
                .tag(Tab.matches)
            RankingsView(scrollToTopTrigger: rankingsScrollToTopTrigger)
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
        .onAppear {
            guard !hasTrackedInitialTab else { return }
            hasTrackedInitialTab = true
            Analytics.track(.primaryTabViewed(tab: selectedTab.analyticsName))
        }
    }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard newTab != selectedTab else {
                    if newTab == .rankings {
                        rankingsScrollToTopTrigger += 1
                    }
                    return
                }
                if newTab == .rankings {
                    rankingsScrollToTopTrigger += 1
                }
                selectedTab = newTab
                Analytics.track(.primaryTabViewed(tab: newTab.analyticsName))
            }
        )
    }
}

private extension ContentView.Tab {
    var analyticsName: String {
        switch self {
        case .matches: "matches"
        case .rankings: "rankings"
        case .news: "news"
        case .stats: "stats"
        }
    }
}

#Preview {
    ContentView()
}
