//
//  StatsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 03/02/2025.
//

import SwiftUI

struct StatsView: View {
    @StateObject var statsVM = ShowStats()
    @State private var selectedRegion: String = "Europe"
    @State private var selectedTimeRange: String = "30d"
    @State private var isLoading = false
    @State private var selectedStat: PlayerStats? = nil
    @State private var showingPlayerSheet = false
    
    let regions = ["Europe", "North America", "South America", "Asia Pacific", "Latin America", "Japan", "Oceania", "Mena"]
    let timeRanges = ["30 days", "60 days", "90 days", "all-time"]
    
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
                    VStack() {
                        HStack(spacing: 10) {
                            Menu {
                                ForEach(regions, id: \.self) { region in
                                    Button(action: {
                                        selectedRegion = region
                                        Task {
                                            await fetchStats()
                                        }
                                    }) {
                                        Text(region)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "globe")
                                        .foregroundColor(.black)
                                    Text(selectedRegion)
                                        .foregroundColor(.black)
                                        .fontWeight(.semibold)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .foregroundColor(.black)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.white))
                                .cornerRadius(6)
                            }
                            
                            Menu {
                                ForEach(timeRanges, id: \.self) { range in
                                    Button(action: {
                                        selectedTimeRange = range
                                        Task {
                                            await fetchStats()
                                        }
                                    }) {
                                        Text(range)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundColor(.black)
                                    Text(selectedTimeRange)
                                        .foregroundColor(.black)
                                        .fontWeight(.semibold)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .foregroundColor(.black)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.white))
                                .cornerRadius(6)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        ForEach(statsVM.stats, id: \.self) { stat in
                            PlayerStatTab(stat: stat)
                                .padding(.horizontal)
                                .onTapGesture {
                                    selectedStat = stat
                                    showingPlayerSheet = true
                                }
                        }
                    }
                }
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.4))
                }
            }
            .navigationBarTitle("Stats")
        }
        .refreshable {
            await fetchStats()
        }
        .onAppear {
            Task {
                await fetchStats()
            }
        }
    }
    
    func fetchStats() async {
        isLoading = true
        let timespan = timeRangeToInt(selectedTimeRange)
        let regionCode = regionToCode(selectedRegion)
        await statsVM.fetch(for: regionCode, for: timespan)
        isLoading = false
    }
    
    private func regionToCode(_ region: String) -> String {
        switch region {
        case "Europe": return "eu"
        case "North America": return "na"
        case "Asia Pacific": return "ap"
        case "Latin America": return "sa"
        case "Japan": return "jp"
        case "Oceania": return "oce"
        case "Mena": return "mena"
        default: return "eu"
        }
    }
    
    private func timeRangeToInt(_ range: String) -> Int {
        switch range {
        case "30 days": return 30
        case "60 days": return 60
        case "90 days": return 90
        case "all-time": return 365 // Should be all
        default: return 30
        }
    }
}

#Preview {
    StatsView()
}
