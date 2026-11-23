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
    let regions = ["All", "Americas", "EMEA", "Pacific", "China", "International"]
    let timeRanges = ["30 days", "60 days", "90 days", "all-time"]
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    LinearGradient(
                        colors: [.primary.opacity(0.08), .clear],
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
                                            guard selectedRegion != region else { return }
                                            selectedRegion = region
                                            Analytics.track(
                                                .filterChanged(
                                                    surface: "stats",
                                                    filter: "region",
                                                    value: regionToCode(region)
                                                )
                                            )
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
                                            guard selectedTimeRange != range else { return }
                                            selectedTimeRange = range
                                            Analytics.track(
                                                .filterChanged(
                                                    surface: "stats",
                                                    filter: "time_range",
                                                    value: timeRangeToAPIValue(range)
                                                )
                                            )
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
                        
                        ForEach(statsVM.stats, id: \.identityKey) { stat in
                            PlayerStatTab(stat: stat)
                                .padding(.horizontal)
                        }
                    }
                }
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationBarTitle("Stats")
        }
        .refreshable {
            await fetchStats(region: selectedRegion, timeRange: selectedTimeRange)
        }
        .task(id: "\(selectedRegion)|\(selectedTimeRange)") {
            await fetchStats(region: selectedRegion, timeRange: selectedTimeRange)
        }
    }
    
    private func fetchStats(region: String, timeRange: String) async {
        isLoading = true
        let timespan = timeRangeToAPIValue(timeRange)
        let regionCode = regionToCode(region)
        await statsVM.fetch(for: regionCode, for: timespan)

        guard !Task.isCancelled,
              selectedRegion == region,
              selectedTimeRange == timeRange else {
            return
        }
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
