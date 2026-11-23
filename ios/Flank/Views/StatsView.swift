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
    @State private var retryToken = 0
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
                        
                        statsContent
                    }
                }
                .refreshable {
                    await fetchStats()
                }
            }
            .navigationBarTitle("Stats")
        }
        .task(id: "\(selectedRegion)|\(selectedTimeRange)|\(retryToken)") {
            await fetchStats()
        }
    }

    @ViewBuilder
    private var statsContent: some View {
        if statsVM.stats.isEmpty {
            switch statsVM.state {
            case .idle, .loading:
                ProgressView("Loading stats…")
                    .padding(.top, 50)
            case .failed(let message, let retryable):
                ListFailureView(title: "Stats unavailable", message: message, retryable: retryable) {
                    Analytics.track(.retryTapped(surface: "stats"))
                    retryToken += 1
                }
                .padding(.top, 30)
            case .empty, .loaded, .showingSaved:
                ContentUnavailableView(
                    "No player stats",
                    systemImage: "chart.bar",
                    description: Text("Try another region or time range.")
                )
                .padding(.top, 30)
            }
        } else {
            if case .showingSaved(let message, let isOffline) = statsVM.state {
                SavedDataBanner(
                    offlineText: "Offline — showing saved stats",
                    failedText: "Couldn’t refresh — showing saved stats",
                    message: message,
                    isOffline: isOffline
                )
                .padding(.horizontal)
            }
            ForEach(statsVM.stats, id: \.identityKey) { stat in
                PlayerStatTab(stat: stat)
                    .padding(.horizontal)
            }
        }
    }

    private func fetchStats() async {
        await statsVM.fetch(
            for: regionToCode(selectedRegion),
            for: timeRangeToAPIValue(selectedTimeRange)
        )
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
