//
//  StatsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 03/02/2025.
//

import SwiftUI

struct StatsView: View {
    @StateObject var statsVM = ShowStats()
    @State private var selectedRegion: String = "All"
    @State private var selectedTimeRange: String = "30 days"
    @State private var isLoading = false
    @State private var selectedStat: PlayerStats? = nil
    @State private var showingPlayerSheet = false
    
    let regions = ["All", "Americas", "EMEA", "Pacific", "China", "International"]
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
                        GlassEffectContainer(spacing: 10) {
                            HStack(spacing: 10) {
                                Menu {
                                    ForEach(regions, id: \.self) { region in
                                        Button {
                                            selectedRegion = region
                                            Task {
                                                await fetchStats()
                                            }
                                        } label: {
                                            if selectedRegion == region {
                                                Label(region, systemImage: "checkmark")
                                            } else {
                                                Text(region)
                                            }
                                        }
                                    }
                                } label: {
                                    Label(selectedRegion, systemImage: "globe")
                                        .fontWeight(.semibold)
                                }
                                .menuIndicator(.visible)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)

                                Menu {
                                    ForEach(timeRanges, id: \.self) { range in
                                        Button {
                                            selectedTimeRange = range
                                            Task {
                                                await fetchStats()
                                            }
                                        } label: {
                                            if selectedTimeRange == range {
                                                Label(range, systemImage: "checkmark")
                                            } else {
                                                Text(range)
                                            }
                                        }
                                    }
                                } label: {
                                    Label(selectedTimeRange, systemImage: "clock")
                                        .fontWeight(.semibold)
                                }
                                .menuIndicator(.visible)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)

                                Spacer()
                            }
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
        let timespan = timeRangeToAPIValue(selectedTimeRange)
        let regionCode = regionToCode(selectedRegion)
        await statsVM.fetch(for: regionCode, for: timespan)
        isLoading = false
    }
    
    private func regionToCode(_ region: String) -> String {
        switch region {
        case "Americas": return "americas"
        case "EMEA": return "emea"
        case "Pacific": return "pacific"
        case "China": return "china"
        case "International": return "intl"
        default: return "all"
        }
    }
    
    private func timeRangeToAPIValue(_ range: String) -> String {
        switch range {
        case "30 days": return "30"
        case "60 days": return "60"
        case "90 days": return "90"
        case "all-time": return "all"
        default: return "30"
        }
    }
}

#Preview {
    StatsView()
}
