//
//  EventsView.swift
//  Flank
//

import SwiftUI

struct EventsView: View {
    @State private var selectedQuery: V3EventListQuery = .upcoming

    @StateObject private var liveEvents = EventListStore(query: .live)
    @StateObject private var upcomingEvents = EventListStore(query: .upcoming)
    @StateObject private var completedEvents = EventListStore(query: .completed)

    private var store: EventListStore {
        switch selectedQuery {
        case .live: liveEvents
        case .upcoming: upcomingEvents
        case .completed: completedEvents
        }
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
                    LazyVStack(spacing: 10) {
                        Picker("Event status", selection: $selectedQuery) {
                            ForEach(V3EventListQuery.allCases) { query in
                                Text(query.title).tag(query)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 6)

                        EventListContent(store: store) {
                            Analytics.track(.retryTapped(surface: "events_\(store.query.rawValue)"))
                            let store = store
                            Task { await store.fetch() }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await store.fetch()
                }
            }
            .navigationTitle("Events")
            .task(id: selectedQuery) {
                // Segments keep what they loaded; only pull-to-refresh and retry reload.
                await store.fetchIfNeeded()
            }
        }
    }
}

/// The rows of one segment, observing its store so pagination updates redraw.
private struct EventListContent: View {
    @ObservedObject var store: EventListStore
    let retry: () -> Void

    var body: some View {
        if case .showingSaved(let message, let isOffline) = store.state {
            SavedDataBanner(
                offlineText: "Offline — showing saved events",
                failedText: "Couldn’t refresh — showing saved events",
                message: message,
                isOffline: isOffline
            )
        }

        if store.events.isEmpty {
            switch store.state {
            case .idle, .loading:
                ProgressView("Loading events…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            case .failed(let message, let retryable):
                ListFailureView(title: "Events unavailable", message: message, retryable: retryable, retry: retry)
                    .padding(.top, 30)
            case .empty, .loaded, .showingSaved:
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "trophy",
                    description: Text("VLR.GG didn’t list any events here.")
                )
                .padding(.top, 30)
            }
        } else {
            ForEach(store.events) { event in
                EventRow(event: event, isLive: store.query == .live)
            }
            if store.query.supportsPagination {
                loadMoreFooter
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch store.query {
        case .live: "No live events"
        case .upcoming: "No upcoming events"
        case .completed: "No completed events"
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if store.isLoadingMore {
            ProgressView("Loading more events…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if let error = store.loadMoreError {
            VStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await store.loadMore() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if store.canLoadMore {
            Button {
                Task { await store.loadMore() }
            } label: {
                Text("Load More Events")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .padding(.vertical, 8)
            .onAppear {
                Task { await store.loadMore() }
            }
        }
    }
}

struct EventRow: View {
    let event: V3EventSummary
    var isLive = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationLink {
            EventDetailView(eventID: event.id, name: event.name, logo: event.image.preferred(for: colorScheme))
        } label: {
            HStack(alignment: .center, spacing: 14) {
                EventLogo(image: event.image, size: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    EventMetaLine(
                        dateText: event.dateText,
                        prize: event.prize.displayText,
                        regionCode: event.regionCode
                    )
                }

                Spacer(minLength: 4)

                statusBadge
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .matchCardChrome(strokeOpacity: colorScheme == .dark ? 0.08 : 0.05)
        }
        .buttonStyle(MatchCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens event details")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isLive {
            LiveBadge()
        } else if event.status == .ongoing {
            EventStatusPill(text: "Ongoing", tint: .green)
        }
    }

    private var accessibilityLabel: String {
        var parts = [event.name]
        if isLive {
            parts.append(String(localized: "Live"))
        } else if event.status == .ongoing {
            parts.append(String(localized: "Ongoing"))
        }
        if let dates = event.dateText?.nilIfBlank { parts.append(dates) }
        if let prize = event.prize.displayText {
            parts.append(String(localized: "Prize pool \(prize)"))
        }
        if let region = event.regionCode?.nilIfBlank { parts.append(region.uppercased()) }
        return parts.joined(separator: ", ")
    }
}

/// Dates, prize pool and region as one wrapping line of captions.
struct EventMetaLine: View {
    let dateText: String?
    let prize: String?
    let regionCode: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { items }
            VStack(alignment: .leading, spacing: 3) { items }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var items: some View {
        if let dateText = dateText?.nilIfBlank {
            Label(dateText, systemImage: "calendar")
        }
        if let prize {
            Label(prize, systemImage: "dollarsign.circle")
        }
        if let region = regionCode?.nilIfBlank {
            if let flag = countryFlag(region) {
                Text(flag)
            } else {
                Text(region.uppercased())
                    .fontWeight(.semibold)
            }
        }
    }
}

struct EventStatusPill: View {
    let text: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// An event logo that follows the colour scheme, with a trophy while it loads.
struct EventLogo: View {
    let image: V3Image
    var fallback: String?
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AsyncImage(url: VLRAPI.imageURL(from: image.preferred(for: colorScheme) ?? fallback)) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "trophy.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    EventsView()
}
