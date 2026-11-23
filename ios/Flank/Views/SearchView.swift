//
//  SearchView.swift
//  Flank
//

import BetterSafariView
import SwiftUI

/// Global search across VLR.GG teams, players and events, plus matches already
/// loaded by the Matches tab.
///
/// The search field itself belongs to the root `TabView` (see `ContentView`), so on
/// iOS 26 the Search tab shows as its own button beside the tab bar and expands
/// into the bottom search field. This view reads and writes that query.
struct SearchView: View {
    /// Rows shown per section before "Show all".
    private static let collapsedRowLimit = 5

    @StateObject private var viewModel = SearchViewModel()
    @Binding var query: String
    @State private var retryToken = 0
    @State private var expandedSections: Set<SearchCategory> = []
    @State private var lastTaskQuery = ""
    /// A series (or other non-event) hit being shown on VLR.GG.
    @State private var safariEntity: SearchEntity?

    private var trimmedQuery: String { SearchQuery.normalized(query) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .onSubmit(of: .search) {
                    viewModel.recordRecentSearch(query)
                }
                .task(id: "\(trimmedQuery)|\(retryToken)") {
                    // A new query waits out the debounce; a retry of the same query doesn't.
                    let isNewQuery = trimmedQuery != lastTaskQuery
                    lastTaskQuery = trimmedQuery
                    if isNewQuery {
                        expandedSections = []
                    }
                    await viewModel.search(trimmedQuery, debounce: isNewQuery)
                }
                .onAppear {
                    viewModel.reloadLocalMatches()
                }
                .safariView(item: $safariEntity) { entity in
                    SafariView(
                        url: entity.url ?? VLRAPI.websiteURL,
                        configuration: SafariView.Configuration(
                            entersReaderIfAvailable: false,
                            barCollapsingEnabled: true
                        )
                    )
                    .preferredBarAccentColor(.clear)
                    .preferredControlAccentColor(.accentColor)
                    .dismissButtonStyle(.done)
                }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            recentSearchesContent
        } else if trimmedQuery.count < SearchQuery.minimumLength {
            ContentUnavailableView(
                "Keep typing",
                systemImage: "character.cursor.ibeam",
                description: Text("Enter at least \(SearchQuery.minimumLength) characters to search.")
            )
        } else if !viewModel.sections.isEmpty {
            // Earlier results stay up while the next query waits out the debounce.
            resultsList
        } else if viewModel.resultsQuery == trimmedQuery, case .failed(let message, let retryable) = viewModel.state {
            ListFailureView(title: "Search unavailable", message: message, retryable: retryable) {
                retry()
            }
        } else if viewModel.resultsQuery == trimmedQuery, viewModel.state == .empty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// True while the list on screen doesn't yet answer the current query.
    private var isSearching: Bool {
        viewModel.resultsQuery != trimmedQuery || viewModel.state == .loading
    }

    @ViewBuilder
    private var recentSearchesContent: some View {
        if viewModel.recentSearches.isEmpty {
            ContentUnavailableView(
                "Search VLR.GG",
                systemImage: "magnifyingglass",
                description: Text("Find teams, players, events and matches.")
            )
        } else {
            List {
                Section {
                    ForEach(viewModel.recentSearches, id: \.self) { recent in
                        Button {
                            query = recent
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Search for \(recent)")
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                viewModel.removeRecentSearch(recent)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Searches")
                        Spacer()
                        Button("Clear") {
                            viewModel.clearRecentSearches()
                        }
                        .font(.subheadline)
                        .textCase(nil)
                        .accessibilityLabel("Clear recent searches")
                    }
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching VLR.GG…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if case .failed(let message, let retryable) = viewModel.state {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn’t search VLR.GG", systemImage: "wifi.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if retryable {
                            Button("Try Again") { retry() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            ForEach(viewModel.sections) { section in
                Section {
                    rows(for: section)
                    if section.count > Self.collapsedRowLimit {
                        let isExpanded = expandedSections.contains(section.category)
                        Button(isExpanded ? "Show fewer" : "Show all \(section.count)") {
                            withAnimation {
                                if isExpanded {
                                    expandedSections.remove(section.category)
                                } else {
                                    expandedSections.insert(section.category)
                                }
                            }
                        }
                        .accessibilityLabel(
                            isExpanded
                                ? "Show fewer \(section.category.title.lowercased())"
                                : "Show all \(section.count) \(section.category.title.lowercased())"
                        )
                    }
                } header: {
                    Text(section.category.title)
                } footer: {
                    if section.category == .matches {
                        Text("From matches loaded in the Matches tab.")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func rows(for section: SearchSection) -> some View {
        let limit = expandedSections.contains(section.category) ? Int.max : Self.collapsedRowLimit
        switch section.rows {
        case .entities(let entities):
            ForEach(entities.prefix(limit)) { entity in
                entityRow(entity)
            }
        case .matches(let matches):
            ForEach(matches.prefix(limit)) { match in
                NavigationLink {
                    MatchDetailView(match: match)
                } label: {
                    SearchMatchRow(match: match)
                }
                .simultaneousGesture(TapGesture().onEnded { recordCurrentQuery() })
                .accessibilityHint("Opens match details")
            }
        }
    }

    @ViewBuilder
    private func entityRow(_ entity: SearchEntity) -> some View {
        switch entity.category {
        case .teams:
            NavigationLink {
                TeamProfileView(teamID: entity.vlrID, name: entity.name, logo: entity.image, source: "search")
            } label: {
                SearchEntityRow(entity: entity)
            }
            .simultaneousGesture(TapGesture().onEnded { recordCurrentQuery() })
            .accessibilityHint("Opens team profile")
        case .players:
            NavigationLink {
                PlayerProfileView(playerID: entity.vlrID, name: entity.name, source: "search")
            } label: {
                SearchEntityRow(entity: entity)
            }
            .simultaneousGesture(TapGesture().onEnded { recordCurrentQuery() })
            .accessibilityHint("Opens player profile")
        case .events where entity.opensEventDetail:
            NavigationLink {
                EventDetailView(eventID: entity.vlrID, name: entity.name, logo: entity.image)
            } label: {
                SearchEntityRow(entity: entity)
            }
            .simultaneousGesture(TapGesture().onEnded { recordCurrentQuery() })
            .accessibilityHint("Opens event details")
        case .events:
            // Series have no page in the app; show them on VLR.GG.
            Button {
                recordCurrentQuery()
                Analytics.track(
                    .externalLinkOpened(
                        destination: "vlr",
                        type: .event,
                        id: String(entity.vlrID),
                        source: "search_series"
                    )
                )
                safariEntity = entity
            } label: {
                SearchEntityRow(entity: entity, opensExternally: true)
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Opens the series on VLR.GG")
        case .matches:
            EmptyView()
        }
    }

    private func recordCurrentQuery() {
        viewModel.recordRecentSearch(trimmedQuery)
    }

    private func retry() {
        retryToken += 1
    }
}

// MARK: - Rows

private struct SearchEntityRow: View {
    let entity: SearchEntity
    /// Shows an external-link mark in place of a disclosure chevron.
    var opensExternally = false

    var body: some View {
        HStack(spacing: 12) {
            SearchThumbnail(
                url: VLRAPI.imageURL(from: entity.image),
                placeholderSymbol: placeholderSymbol,
                isCircular: entity.category == .players
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entity.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if entity.isInactive {
                        Text("Inactive")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let subtitle = entity.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if opensExternally {
                Image(systemName: "arrow.up.right.square")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var placeholderSymbol: String {
        switch entity.category {
        case .teams: "person.2.fill"
        case .players: "person.fill"
        case .events, .matches: "trophy.fill"
        }
    }

    private var accessibilityText: String {
        let kind = entity.eventKind == .series ? String(localized: "Series") : nil
        return [entity.name, kind, entity.isInactive ? "Inactive" : nil, entity.subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct SearchMatchRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let match: V3Match

    private var title: String {
        let names = match.teams.map(\.name)
        return names.isEmpty ? match.event.name : names.joined(separator: " vs ")
    }

    private var subtitle: String {
        var parts = [match.event.name]
        if let series = match.event.series, !series.isEmpty {
            parts.append(series)
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String? {
        switch match.status {
        case .live:
            return "Live"
        case .completed:
            guard let first = match.firstTeam?.score, let second = match.secondTeam?.score else {
                return "Final"
            }
            return "\(first)–\(second)"
        case .scheduled:
            return match.display.relative ?? match.display.date
        case .unknown:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            SearchThumbnail(
                url: VLRAPI.imageURL(from: match.event.image.preferred(for: colorScheme)),
                placeholderSymbol: "gamecontroller.fill",
                isCircular: false
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            if let statusText {
                Text(statusText)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(match.status == .live ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle, statusText].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct SearchThumbnail: View {
    let url: URL?
    let placeholderSymbol: String
    let isCircular: Bool

    var body: some View {
        AsyncImage(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: isCircular ? .fill : .fit)
        } placeholder: {
            Image(systemName: placeholderSymbol)
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: 40)
        // Player photos sit in a filled circle; team, event and match logos are
        // shown bare, like everywhere else in the app.
        .background(isCircular ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(Rectangle()))
        .accessibilityHidden(true)
    }
}

#Preview {
    @Previewable @State var query = ""
    SearchView(query: $query)
}
