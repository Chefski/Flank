//
//  RankingsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 23/04/2024.
//

import SwiftUI

struct RankingsView: View {
    private struct RegionOption: Identifiable {
        let id: String
        let name: String
        let image: String
        let color: Color
    }

    @StateObject var rankings = ShowRankings()
    @AppStorage("defaultRegion") private var defaultRegion = "na"
    @State private var selectedRegion: String = ""
    @State private var isLoading = false
    
    @State private var showingRegionPicker = true
    @State private var searchText = ""
    
    private let regionOptions = [
        RegionOption(id: "na", name: "North America", image: "NA", color: Color(red: 0.05, green: 0.7, blue: 0.59)),
        RegionOption(id: "eu", name: "Europe", image: "EU", color: Color(red: 0.83, green: 1, blue: 0.12)),
        RegionOption(id: "br", name: "Brazil", image: "AMER", color: Color(red: 1, green: 0.34, blue: 0.05)),
        RegionOption(id: "ap", name: "Asia-Pacific", image: "AP", color: Color(red: 0, green: 0.82, blue: 0.84)),
        RegionOption(id: "la-s", name: "LA South", image: "AMER", color: Color(red: 1, green: 0.34, blue: 0.05)),
        RegionOption(id: "kr", name: "Korea", image: "AP", color: Color(red: 0, green: 0.82, blue: 0.84)),
        RegionOption(id: "cn", name: "China", image: "CN", color: Color(red: 0.91, green: 0.19, blue: 0.34)),
        RegionOption(id: "gc", name: "Game Changers", image: "GC", color: Color(red: 0.88, green: 0.59, blue: 0)),
        RegionOption(id: "la-n", name: "LA North", image: "LA", color: Color(red: 0.05, green: 0.7, blue: 0.59)),
        RegionOption(id: "mn", name: "Mena", image: "MN", color: Color(red: 1, green: 0.75, blue: 0.24))
    ]

    var body: some View {
        NavigationStack {
            if showingRegionPicker {
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(regionOptions) { region in
                                    Button {
                                        selectedRegion = region.id
                                        fetchRankings()
                                    } label: {
                                        HStack {
                                            Image(region.image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 23, height: 23)
                                                .clipped()
                                            Text(region.name)
                                                .font(.system(size: 17, weight: .semibold))
                                                .foregroundStyle(region.color)
                                        }
                                        .padding(.horizontal, 21)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(
                                        .regular
                                            .tint(selectedRegion == region.id ? region.color.opacity(0.25) : nil)
                                            .interactive(),
                                        in: .capsule
                                    )
                                    .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .push(from: .top),
                            removal: .push(from: .bottom)
                        )
                    )
                }
            }
            
            ScrollView(showsIndicators: false) {
                if isLoading {
                    ProgressView()
                        .padding()
                } else {
                    LazyVStack {
                        ForEach(filteredRankings, id: \.self) { ranking in
                            RankingsTab(team: ranking, searchText: searchText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top)
                }
            }
            .searchable(text: $searchText, prompt: "Search for a team")
            .navigationTitle("Rankings")
        }
        .onAppear {
            if selectedRegion.isEmpty {
                selectedRegion = defaultRegion
            }
            fetchRankings()
        }
    }
    
    private var filteredRankings: [Rankings] {
        if searchText.isEmpty {
            return rankings.rankings
        } else {
            return rankings.rankings.filter { $0.team.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    private func fetchRankings() {
        isLoading = true
        Task {
            await rankings.fetch(for: selectedRegion)
            isLoading = false
        }
    }
}

#Preview {
    RankingsView()
}
