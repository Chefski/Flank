//
//  HomeView.swift
//  Flank
//

import SwiftUI
import WhatsNewKit

struct HomeView: View {
    @AppStorage("defaultTab") private var defaultTab = "Upcoming"
    @State private var selectedTab = ""
    @State private var searchText = ""
    @State private var listRetryToken = 0
    @State private var showingSettings = false
    @State private var lastTrackedSearchContext = ""

    @StateObject private var pastResults = ShowResults()
    @StateObject private var upcomingMatches = ShowUpcoming()
    @StateObject private var liveMatches = ShowLive()

    @State private var showWhatsNew = false

    @State private var whatsNew: WhatsNew? = WhatsNew(
        title: "What's new?",
        features: [
            .init(
                image: .init(systemName: "magnifyingglass", foregroundColor: .blue),
                title: "Search for matches",
                subtitle: "Find upcoming and past matches with the search bar instead of scrolling!"
            ),
            .init(
                image: .init(systemName: "sparkles", foregroundColor: .purple),
                title: "Redesigned result tabs",
                subtitle: "Result tabs have been redesigned to a more colorful and modern look!"
            ),
            .init(
                image: .init(systemName: "slider.horizontal.3", foregroundColor: .green),
                title: "Choose your defaults",
                subtitle: "You can choose to see upcoming matches or results at launch."
            )
        ]
    )

    private var filteredUpcomingMatches: [V3Match] {
        filtered(upcomingMatches.matches)
    }

    private var filteredPastResults: [V3Match] {
        filtered(pastResults.matches)
    }

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
                    LazyVStack(spacing: 14) {
                        liveSection
                        tabSelector

                        if selectedTab == "Upcoming" {
                            matchList(
                                matches: filteredUpcomingMatches,
                                state: upcomingMatches.state,
                                emptyTitle: searchText.isEmpty
                                    ? "No upcoming matches"
                                    : "No upcoming matches found",
                                card: { UpcomingMatchTab(match: $0) }
                            )
                        } else {
                            matchList(
                                matches: filteredPastResults,
                                state: pastResults.state,
                                emptyTitle: searchText.isEmpty
                                    ? "No completed matches"
                                    : "No match results found",
                                card: { MatchResultsTab(match: $0) }
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable {
                    async let live: Void = liveMatches.fetch()
                    async let upcoming: Void = upcomingMatches.fetch()
                    async let results: Void = pastResults.fetch()
                    _ = await (live, upcoming, results)
                }
                .task {
                    if selectedTab.isEmpty {
                        selectedTab = defaultTab == "Results" ? "Results" : "Upcoming"
                    }
                    await liveMatches.fetch()
                    guard !Task.isCancelled else { return }
                    checkAndShowWhatsNew()
                }
                .task(id: "\(selectedTab)-\(listRetryToken)") {
                    if selectedTab == "Upcoming" {
                        await upcomingMatches.fetch()
                    } else if selectedTab == "Results" {
                        await pastResults.fetch()
                    }
                }
                .task {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(300))
                        } catch {
                            return
                        }
                        await liveMatches.fetch()
                    }
                }
                .sheet(isPresented: $showWhatsNew) {
                    if let whatsNew {
                        WhatsNewView(whatsNew: whatsNew)
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }
                .navigationTitle("Matches")
                .searchable(text: $searchText, prompt: "Search matches…")
                .task(id: "\(selectedTab)|\(searchText)") {
                    guard !searchText.isEmpty else {
                        lastTrackedSearchContext = ""
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(600))
                    } catch {
                        return
                    }
                    let context = "\(selectedTab)|\(searchText)"
                    guard context != lastTrackedSearchContext else { return }
                    lastTrackedSearchContext = context
                    let resultCount = selectedTab == "Upcoming"
                        ? filteredUpcomingMatches.count
                        : filteredPastResults.count
                    Analytics.track(.searchPerformed(surface: "matches", resultCount: resultCount))
                    if resultCount == 0 {
                        Analytics.track(.searchZeroResults(surface: "matches"))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                                .labelStyle(.iconOnly)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Opens app settings")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var liveSection: some View {
        switch liveMatches.state {
        case .loading where liveMatches.matches.isEmpty:
            ProgressView("Checking live matches…")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        case .failed(let message, let retryable) where liveMatches.matches.isEmpty:
            compactStatus(message: message, retryable: retryable) {
                Analytics.track(.retryTapped(surface: "matches_live"))
                Task { await liveMatches.fetch() }
            }
        default:
            if !liveMatches.matches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Live")
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal)
                        .accessibilityAddTraits(.isHeader)

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(liveMatches.matches) { match in
                                LiveMatchTab(match: match)
                                    .containerRelativeFrame(.horizontal) { length, _ in
                                        max(0, length - 32)
                                    }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                }
                if case .cachedOffline(let message) = liveMatches.state {
                    cachedBanner(message)
                }
            }
        }
    }

    private var tabSelector: some View {
        HStack(spacing: 15) {
            tabButton("Upcoming")
            tabButton("Results")
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func tabButton(_ title: String) -> some View {
        Button {
            guard selectedTab != title else { return }
            selectedTab = title
            Analytics.track(.filterChanged(surface: "matches", filter: "list", value: title.lowercased()))
        } label: {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(selectedTab == title ? .primary : .secondary)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == title ? .isSelected : [])
    }

    @ViewBuilder
    private func matchList<Card: View>(
        matches: [V3Match],
        state: V3MatchListLoadState,
        emptyTitle: String,
        @ViewBuilder card: @escaping (V3Match) -> Card
    ) -> some View {
        if case .cachedOffline(let message) = state {
            cachedBanner(message)
        }

        if matches.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView("Loading matches…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            case .failed(let message, let retryable):
                ContentUnavailableView {
                    Label("Matches unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    if retryable {
                        Button("Try Again") {
                            Analytics.track(.retryTapped(surface: "matches_\(selectedTab.lowercased())"))
                            listRetryToken += 1
                        }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .empty, .loaded, .cachedOffline:
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: searchText.isEmpty ? "calendar.badge.exclamationmark" : "magnifyingglass"
                )
            }
        } else {
            ForEach(matches) { match in
                card(match)
                    .padding(.horizontal)
            }
        }
    }

    private func cachedBanner(_ message: String) -> some View {
        Label("Offline — showing saved matches", systemImage: "icloud.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .accessibilityHint(message)
    }

    private func compactStatus(
        message: String,
        retryable: Bool,
        retry: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
            Text("Live scores unavailable")
                .font(.subheadline)
            Spacer()
            if retryable {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .accessibilityHint(message)
    }

    private func filtered(_ matches: [V3Match]) -> [V3Match] {
        guard !searchText.isEmpty else { return matches }
        return matches.filter { match in
            match.teams.contains { $0.name.localizedCaseInsensitiveContains(searchText) }
                || match.event.name.localizedCaseInsensitiveContains(searchText)
                || match.event.stage?.localizedCaseInsensitiveContains(searchText) == true
                || match.event.series?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private func checkAndShowWhatsNew() {
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let lastVersionPrompted = UserDefaults.standard.string(forKey: "LastWhatsNewVersion")

        if lastVersionPrompted != currentVersion {
            showWhatsNew = true
            UserDefaults.standard.set(currentVersion, forKey: "LastWhatsNewVersion")
        }
    }
}
