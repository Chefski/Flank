//
//  HomeView.swift
//  Flank
//

import SwiftUI

struct HomeView: View {
    @AppStorage("defaultTab") private var defaultTab = "Upcoming"
    @State private var selectedTab = ""
    @State private var searchText = ""
    @State private var listRetryToken = 0
    @State private var showingSettings = false
    @State private var lastTrackedSearchContext = ""
    @AppStorage("matchesFavoritesOnly") private var favoritesOnly = false
    @Environment(\.scenePhase) private var scenePhase

    private var favorites: FavoriteTeamsStore { .shared }

    /// The favourites filter only applies while there are favourites to filter by.
    private var isFilteringFavorites: Bool {
        favoritesOnly && !favorites.ids.isEmpty
    }

    @StateObject private var pastResults = ShowResults()
    @StateObject private var upcomingMatches = ShowUpcoming()
    @StateObject private var liveMatches = ShowLive()

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
                                emptyTitle: isFilteringFavorites
                                    ? "No upcoming matches for your teams"
                                    : searchText.isEmpty
                                    ? "No upcoming matches"
                                    : "No upcoming matches found",
                                card: { UpcomingMatchTab(match: $0) }
                            )
                        } else {
                            matchList(
                                matches: filteredPastResults,
                                state: pastResults.state,
                                emptyTitle: isFilteringFavorites
                                    ? "No recent results for your teams"
                                    : searchText.isEmpty
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
                }
                .task(id: "\(selectedTab)-\(listRetryToken)") {
                    if selectedTab == "Upcoming" {
                        await upcomingMatches.fetch()
                    } else if selectedTab == "Results" {
                        await pastResults.fetch()
                    }
                }
                .task(id: scenePhase) {
                    // Refresh live scores while Matches is on screen and the app is in
                    // the foreground. Coming back to the foreground after the interval
                    // refreshes straight away.
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        let interval = LiveScorePolling.interval(
                            hasLiveMatches: !liveMatches.matches.isEmpty,
                            state: liveMatches.state
                        )
                        let elapsed = liveMatches.lastFetchFinishedAt.map { Date().timeIntervalSince($0) } ?? 0
                        if elapsed < interval {
                            do {
                                try await Task.sleep(for: .seconds(interval - elapsed))
                            } catch {
                                return
                            }
                            continue
                        }
                        await liveMatches.fetch()
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
                if case .showingSaved(let message, let isOffline) = liveMatches.state {
                    cachedBanner(message, isOffline: isOffline)
                }
            }
        }
    }

    private var tabSelector: some View {
        HStack(spacing: 15) {
            tabButton("Upcoming")
            tabButton("Results")
            Spacer()
            if !favorites.ids.isEmpty {
                favoritesFilterButton
            }
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

    private var favoritesFilterButton: some View {
        Button {
            favoritesOnly.toggle()
            Analytics.track(
                .filterChanged(surface: "matches", filter: "favorites", value: favoritesOnly ? "on" : "off")
            )
        } label: {
            Label("Favourite Teams", systemImage: favoritesOnly ? "star.fill" : "star")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(favoritesOnly ? .yellow : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: favoritesOnly)
        .accessibilityLabel("Show only favourite teams")
        .accessibilityAddTraits(favoritesOnly ? .isSelected : [])
    }

    @ViewBuilder
    private func matchList<Card: View>(
        matches: [V3Match],
        state: ListLoadState,
        emptyTitle: String,
        @ViewBuilder card: @escaping (V3Match) -> Card
    ) -> some View {
        if case .showingSaved(let message, let isOffline) = state {
            cachedBanner(message, isOffline: isOffline)
        }

        if matches.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView("Loading matches…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            case .failed(let message, let retryable):
                ListFailureView(title: "Matches unavailable", message: message, retryable: retryable) {
                    Analytics.track(.retryTapped(surface: "matches_\(selectedTab.lowercased())"))
                    listRetryToken += 1
                }
            case .empty, .loaded, .showingSaved:
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: isFilteringFavorites
                        ? "star"
                        : searchText.isEmpty ? "calendar.badge.exclamationmark" : "magnifyingglass"
                )
            }
        } else {
            ForEach(matches) { match in
                card(match)
                    .padding(.horizontal)
            }
        }
    }

    private func cachedBanner(_ message: String, isOffline: Bool) -> some View {
        SavedDataBanner(
            offlineText: "Offline — showing saved matches",
            failedText: "Couldn’t refresh — showing saved matches",
            message: message,
            isOffline: isOffline
        )
        .padding(.horizontal)
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
        var matches = matches
        if isFilteringFavorites {
            let ids = favorites.ids
            matches = matches.filter { match in
                match.teams.contains { $0.id.map(ids.contains) == true }
            }
        }
        guard !searchText.isEmpty else { return matches }
        return matches.filter { match in
            match.teams.contains { $0.name.localizedCaseInsensitiveContains(searchText) }
                || match.event.name.localizedCaseInsensitiveContains(searchText)
                || match.event.stage?.localizedCaseInsensitiveContains(searchText) == true
                || match.event.series?.localizedCaseInsensitiveContains(searchText) == true
        }
    }
}

/// How often the Matches tab refreshes live scores, counted from when the last fetch
/// finished.
enum LiveScorePolling {
    /// The API's edge cache holds live scores for 30 s, so polling at that rate adds no
    /// load on vlr.gg.
    static let liveInterval: TimeInterval = 30
    /// Nothing live, or the last refresh failed (offline, rate limited, server down).
    static let idleInterval: TimeInterval = 120

    static func interval(hasLiveMatches: Bool, state: ListLoadState) -> TimeInterval {
        if state.isFailing || !hasLiveMatches {
            return idleInterval
        }
        return liveInterval
    }
}

/// Notice for list screens showing their saved copy after a refresh failed. It only
/// says "Offline" when the connection was the problem; otherwise it shows the reason,
/// such as a server error, so a broken data service isn't mistaken for no signal.
struct SavedDataBanner: View {
    let offlineText: LocalizedStringKey
    let failedText: LocalizedStringKey
    let message: String
    let isOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                isOffline ? offlineText : failedText,
                systemImage: isOffline ? "icloud.slash" : "exclamationmark.icloud"
            )
            if !isOffline {
                Text(message)
                    .font(.caption)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Error state for list screens with nothing cached to show.
struct ListFailureView: View {
    let title: String
    let message: String
    let retryable: Bool
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if retryable {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
