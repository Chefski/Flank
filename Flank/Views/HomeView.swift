//
//  HomeView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import WhatsNewKit

struct HomeView: View {
    @AppStorage("defaultTab") private var defaultTab = "Upcoming"
    @State private var selectedTab = ""
    @State private var searchText = ""
    
    @ObservedObject var pastResults = ShowResults()
    @ObservedObject var upcomingMatches = ShowUpcoming()
    @ObservedObject var liveMatches = ShowLive()
    
    @State private var showWhatsNew = false
    
    @State var whatsNew: WhatsNew? = WhatsNew(
        title: "What's new?",
        features: [
            .init(
                image: .init(
                    systemName: "magnifyingglass",
                    foregroundColor: .blue
                ),
                title: "Search for matches",
                subtitle: "Find upcoming and past matches with the search bar instead of scrolling!"
            ),
            .init(
                image: .init(
                    systemName: "sparkles",
                    foregroundColor: .purple
                ),
                title: "Redesigned result tabs",
                subtitle: "Result tabs have been redesigned to a more colorful and modern look!"
            ),
            .init(
                image: .init(
                    systemName: "slider.horizontal.3",
                    foregroundColor: .green
                ),
                title: "Choose your defaults",
                subtitle: "You can choose to see the upcoming matches or results at launch. You can also pick your favorite region!"
            ),
        ]
    )
    
    var filteredUpcomingMatches: [UpcomingMatch] {
        if searchText.isEmpty {
            return upcomingMatches.upcomingMatches
        } else {
            return upcomingMatches.upcomingMatches.filter { match in
                match.team1.localizedCaseInsensitiveContains(searchText) ||
                match.team2.localizedCaseInsensitiveContains(searchText) ||
                match.match_event.localizedCaseInsensitiveContains(searchText) ||
                match.match_series.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var filteredPastResults: [Match] {
        if searchText.isEmpty {
            return pastResults.matches
        } else {
            return pastResults.matches.filter { match in
                match.team1.localizedCaseInsensitiveContains(searchText) ||
                match.team2.localizedCaseInsensitiveContains(searchText) ||
                match.tournament_name.localizedCaseInsensitiveContains(searchText) ||
                match.round_info.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    Spacer()
                }
                .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    if !liveMatches.liveMatches.isEmpty {
                        HStack {
                            Text("Live")
                                .font(.system(size: 24, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(liveMatches.liveMatches, id: \.self) { match in
                                    LiveMatchTab(match: match)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    Spacer()
                        .padding(.vertical, 4)
                    
                    HStack(spacing: 15) {
                        Button(action: {
                            selectedTab = "Upcoming"
                        }) {
                            Text("Upcoming")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .opacity(selectedTab == "Upcoming" ? 1.0 : 0.5)
                        
                        Button(action: {
                            selectedTab = "Results"
                        }) {
                            Text("Results")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .opacity(selectedTab == "Results" ? 1.0 : 0.5)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    if selectedTab == "Upcoming" {
                        if filteredUpcomingMatches.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 50))
                                    .foregroundColor(.white.opacity(0.5))
                                Text("No upcoming matches found")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 12) {
                                    ForEach(filteredUpcomingMatches, id: \.self) { match in
                                        UpcomingMatchTab(match: match)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    } else {
                        if filteredPastResults.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 50))
                                    .foregroundColor(.white.opacity(0.5))
                                Text("No match results found")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 15) {
                                    ForEach(filteredPastResults, id: \.self) { match in
                                        MatchResultsTab(match: match)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .refreshable {
                    Task {
                        await self.liveMatches.fetch()
                        await self.upcomingMatches.fetch()
                        await self.pastResults.fetch()
                    }
                }
                .onAppear {
                    Task {
                        if selectedTab.isEmpty {
                            selectedTab = defaultTab
                        }
                        
                        await self.liveMatches.fetch()
                        await self.upcomingMatches.fetch()
                        await self.pastResults.fetch()
                        
                        checkAndShowWhatsNew()
                    }
                }
                .sheet(isPresented: $showWhatsNew) {
                    WhatsNewView(whatsNew: whatsNew!)
                }
                .navigationTitle("Matches")
                .searchable(text: $searchText, prompt: "Search matches...")
            }
        }
    }
    
    private func checkAndShowWhatsNew() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let lastVersionPrompted = UserDefaults.standard.string(forKey: "LastWhatsNewVersion")
        
        if lastVersionPrompted != currentVersion {
            showWhatsNew = true
            UserDefaults.standard.set(currentVersion, forKey: "LastWhatsNewVersion")
        }
    }
}


#Preview {
    HomeView()
}
