//
//  RankingsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 23/04/2024.
//

import SwiftUI

/// The Teams board of the Rankings tab: VLR.GG team rankings by region. It has no
/// navigation stack of its own; `RankingsHubView` hosts it.
struct RankingsView: View {
    private static let scrollTopID = "rankings-scroll-top"

    private struct RegionOption: Identifiable {
        let id: String
        let name: String
        let image: String
        let color: Color
    }

    @StateObject var rankings = ShowRankings()
    @AppStorage("defaultRegion") private var defaultRegion = "na"
    @State private var selectedRegion: String = ""
    @State private var retryToken = 0
    
    @State private var showingRegionPicker = true
    @State private var searchText = ""

    let scrollToTopTrigger: Int

    init(scrollToTopTrigger: Int = 0) {
        self.scrollToTopTrigger = scrollToTopTrigger
    }
    
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
        VStack(spacing: 0) {
            if showingRegionPicker {
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(regionOptions) { region in
                                    Button {
                                        guard selectedRegion != region.id else { return }
                                        selectedRegion = region.id
                                        Analytics.track(
                                            .filterChanged(surface: "rankings", filter: "region", value: region.id)
                                        )
                                    } label: {
                                        HStack {
                                            Image(region.image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 23, height: 23)
                                                .clipped()
                                            Text(region.name)
                                                .font(.system(size: 17, weight: .semibold))
                                                .foregroundStyle(.primary)
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
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, -8)
                    .transition(
                        .asymmetric(
                            insertion: .push(from: .top),
                            removal: .push(from: .bottom)
                        )
                    )
                }
            }
            
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.scrollTopID)

                    rankingsContent
                }
                .refreshable {
                    await rankings.fetch(for: selectedRegion)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 24)

                        Rectangle()
                            .fill(.black)
                    }
                }
                .onChange(of: scrollToTopTrigger) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        scrollProxy.scrollTo(Self.scrollTopID, anchor: .top)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            searchPill
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .onAppear {
            if selectedRegion.isEmpty {
                selectedRegion = defaultRegion
            }
        }
        .task(id: "\(selectedRegion)-\(retryToken)") {
            guard !selectedRegion.isEmpty else {
                return
            }
            await rankings.fetch(for: selectedRegion)
        }
    }

    @ViewBuilder
    private var rankingsContent: some View {
        if rankings.rankings.isEmpty {
            switch rankings.state {
            case .idle, .loading:
                ProgressView("Loading rankings…")
                    .padding(.top, 50)
            case .failed(let message, let retryable):
                ListFailureView(
                    title: "Rankings unavailable",
                    message: message,
                    retryable: retryable
                ) {
                    Analytics.track(.retryTapped(surface: "rankings"))
                    retryToken += 1
                }
                .padding(.top, 30)
            case .empty, .loaded, .showingSaved:
                ContentUnavailableView(
                    "No rankings for this region",
                    systemImage: "medal",
                    description: Text("VLR.GG didn’t return any ranked teams.")
                )
                .padding(.top, 30)
            }
        } else {
            LazyVStack {
                if case .showingSaved(let message, let isOffline) = rankings.state {
                    SavedDataBanner(
                        offlineText: "Offline — showing saved rankings",
                        failedText: "Couldn’t refresh — showing saved rankings",
                        message: message,
                        isOffline: isOffline
                    )
                    .padding(.horizontal, 8)
                }
                if filteredRankings.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 30)
                }
                ForEach(filteredRankings, id: \.self) { ranking in
                    RankingsTab(team: ranking, searchText: searchText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top)
            .padding(.bottom, 120)
        }
    }

    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search teams", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    guard !searchText.isEmpty else { return }
                    Analytics.track(
                        .searchPerformed(surface: "rankings", resultCount: filteredRankings.count)
                    )
                    if filteredRankings.isEmpty {
                        Analytics.track(.searchZeroResults(surface: "rankings"))
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear team search")
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 360, minHeight: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
    }
    
    private var filteredRankings: [Rankings] {
        if searchText.isEmpty {
            return rankings.rankings
        } else {
            return rankings.rankings.filter { $0.team.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

#Preview {
    NavigationStack {
        RankingsView()
            .navigationTitle("Rankings")
    }
}
