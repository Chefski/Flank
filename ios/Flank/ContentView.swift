//
//  ContentView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab: PrimaryTab = .matches
    @State private var rankingsScrollToTopTrigger = 0
    @State private var hasTrackedInitialTab = false
    @State private var searchQuery = ""

    // Not named `Tab`, which would shadow SwiftUI's `Tab` used below.
    enum PrimaryTab: Hashable {
        case matches
        case events
        /// Team rankings and player stats, switched inside the tab.
        case rankings
        case news
        case search
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Matches", systemImage: "gamecontroller.fill", value: PrimaryTab.matches) {
                HomeView()
            }
            Tab("Events", systemImage: "trophy.fill", value: PrimaryTab.events) {
                EventsView()
            }
            Tab("Rankings", systemImage: "medal.fill", value: PrimaryTab.rankings) {
                RankingsHubView(scrollToTopTrigger: rankingsScrollToTopTrigger)
            }
            Tab("News", systemImage: "newspaper.fill", value: PrimaryTab.news) {
                NewsView()
            }
            Tab(value: PrimaryTab.search, role: .search) {
                SearchView(query: $searchQuery)
            }
        }
        // Search lives on the TabView, and selecting the search-role tab activates it,
        // so iOS 26 shows Search as its own button beside the tab bar that expands
        // into the bottom search field. Without `.searchTabSelection` it renders as
        // an ordinary fifth tab.
        .searchable(text: $searchQuery, prompt: "Teams, players, events")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .tabViewSearchActivation(.searchTabSelection)
        .tint(.primary)
        .onAppear {
            guard !hasTrackedInitialTab else { return }
            hasTrackedInitialTab = true
            Analytics.track(.primaryTabViewed(tab: selectedTab.analyticsName))
        }
    }

    private var tabSelection: Binding<PrimaryTab> {
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

private extension ContentView.PrimaryTab {
    var analyticsName: String {
        switch self {
        case .matches: "matches"
        case .events: "events"
        case .rankings: "rankings"
        case .news: "news"
        case .search: "search"
        }
    }
}

#Preview {
    ContentView()
}
