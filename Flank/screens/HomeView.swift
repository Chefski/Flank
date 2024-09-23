//
//  HomeView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
//import WhatsNewKit

struct HomeView: View {
    @State private var showSettingsPopover = false
    @State private var selectedTab = "Upcoming"
    
    @ObservedObject var pastResults = ShowResults()
    @ObservedObject var upcomingMatches = ShowUpcoming()
    @ObservedObject var liveMatches = ShowLive()
    
//    @State private var showWhatsNew = false
//    
//    @State var whatsNew: WhatsNew? = WhatsNew(
//        title: "What's new?",
//        features: [
//            .init(
//                image: .init(
//                    systemName: "envelope.fill",
//                    foregroundColor: .orange
//                ),
//                title: "Contact via email",
//                subtitle: "You can now get in contact quickly"
//            ),
//        ]
//    )
    
    var body: some View {
        NavigationStack {
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
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 12) {
                            ForEach(upcomingMatches.upcomingMatches, id: \.self) { match in
                                UpcomingMatchTab(match: match)
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 15) {
                            ForEach(pastResults.matches, id: \.self) { match in
                                MatchResultsTab(match: match)
                            }
                        }
                        .padding(.horizontal)
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
                    await self.liveMatches.fetch()
                    await self.upcomingMatches.fetch()
                    await self.pastResults.fetch()
                    
//                    checkAndShowWhatsNew()
                }
            }
//            .sheet(isPresented: $showWhatsNew) {
//                WhatsNewView(whatsNew: whatsNew!)
//            }
            .navigationTitle("Matches")
//            .background(Color(red: 0.13, green: 0.12, blue: 0.11))
        }
    }
    
//    private func checkAndShowWhatsNew() {
//        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
//        let lastVersionPrompted = UserDefaults.standard.string(forKey: "LastWhatsNewVersion")
//        
//        if lastVersionPrompted != currentVersion {
//            showWhatsNew = true
//            UserDefaults.standard.set(currentVersion, forKey: "LastWhatsNewVersion")
//        }
//    }
}


#Preview {
    HomeView()
}
