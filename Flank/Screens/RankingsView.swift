//
//  RankingsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 23/04/2024.
//

import SwiftUI

struct RankingsView: View {
    @StateObject var rankings = ShowRankings()
    @State private var selectedRegion: String = "na"
    @State private var isLoading = false
    
    @State private var showingRegionPicker = true
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            if showingRegionPicker {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button(action: {
                            selectedRegion = "na"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("NA")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("North America")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0.05, green: 0.7, blue: 0.59))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(
    selectedRegion == "na" ? Color(red: 0.05, green: 0.7, blue: 0.59).opacity(0.3) : Color.white.opacity(0.12)
)
.cornerRadius(10)
.animation(.easeInOut(duration: 0.3), value: selectedRegion)

                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "eu"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("EU")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("Europe")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0.83, green: 1, blue: 0.12))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "eu" ? Color(red: 0.83, green: 1, blue: 0.12).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "br"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("AMER")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("Brazil")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 1, green: 0.34, blue: 0.05))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "br" ? Color(red: 1, green: 0.34, blue: 0.05).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "ap"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("AP")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("Asia-pacific")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0, green: 0.82, blue: 0.84))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "ap" ? Color(red: 0, green: 0.82, blue: 0.84).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "la-s"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("AMER")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("LA South")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 1, green: 0.34, blue: 0.05))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "la-s" ? Color(red: 1, green: 0.34, blue: 0.05).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "kr"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("AP")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("Korea")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0, green: 0.82, blue: 0.84))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "kr" ? Color(red: 0, green: 0.82, blue: 0.84).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "cn"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("CN")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("China")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0.91, green: 0.19, blue: 0.34))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "cn" ? Color(red: 0.91, green: 0.19, blue: 0.34).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "gc"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("GC")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("Game Changers")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0.88, green: 0.59, blue: 0))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "gc" ? Color(red: 0.88, green: 0.59, blue: 0).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "la-n"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("LA")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("LA North")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 0.05, green: 0.7, blue: 0.59))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "la-n" ? Color(red: 0.05, green: 0.7, blue: 0.59).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        Button(action: {
                            selectedRegion = "mn"
                            fetchRankings()
                        }) {
                            HStack {
                                Image("MN")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 23, height: 23)
                                    .clipped()
                                Text("Mena")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(red: 1, green: 0.75, blue: 0.24))
                            }
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .background(selectedRegion == "mn" ? Color(red: 1, green: 0.75, blue: 0.24).opacity(0.3) : Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .animation(.easeInOut(duration: 0.3), value: selectedRegion)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .inset(by: 0.5)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal)
                    
                }
                .transition(
                    .asymmetric(
                        insertion: .push(from: .top),
                        removal: .push(from: .bottom)
                    )
                )
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
