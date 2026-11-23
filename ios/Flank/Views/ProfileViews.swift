//
//  ProfileViews.swift
//  Flank
//

import Foundation
import SwiftUI

struct V2ProfileCollection<Value: Decodable & Sendable>: Decodable, Sendable {
    let segments: [Value]
}

struct V2TeamRating: Decodable, Sendable {
    let rank: String?
    let rating: String?
    let peakRating: String?
    let streak: String?

    enum CodingKeys: String, CodingKey {
        case rank, rating, streak
        case peakRating = "peak_rating"
    }
}

struct V2TeamRosterMember: Decodable, Sendable {
    let id: String?
    let url: String?
    let alias: String
    let realName: String?
    let avatar: String?
    let country: String?
    let isCaptain: Bool?
    let role: String?
    let isStaff: Bool?
    /// Only sent by `/v2/team/{id}/roster` for former and benched members.
    let dateJoined: String?
    let dateLeft: String?

    enum CodingKeys: String, CodingKey {
        case id, url, alias, avatar, country, role
        case realName = "real_name"
        case isCaptain = "is_captain"
        case isStaff = "is_staff"
        case dateJoined = "date_joined"
        case dateLeft = "date_left"
    }

    var identityKey: String { id ?? url ?? alias }
}

struct V2EventPlacement: Decodable, Sendable {
    let event: String
    let series: String?
    let placement: String?
    let prize: String?
    let team: String?
    let date: String?
    let url: String?

    var identityKey: String {
        "\(url ?? "")|\(event)|\(series ?? "")|\(placement ?? "")|\(team ?? "")|\(date ?? "")"
    }
}

struct V2TeamProfile: Decodable, Sendable {
    let id: String
    let name: String
    let tag: String?
    let logo: String?
    let logoLight: String?
    let logoDark: String?
    let country: String?
    let countryName: String?
    let description: String?
    let rating: V2TeamRating?
    let roster: [V2TeamRosterMember]?
    let eventPlacements: [V2EventPlacement]?
    let totalWinnings: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tag, logo, country, description, rating, roster
        case logoLight = "logo_light"
        case logoDark = "logo_dark"
        case countryName = "country_name"
        case eventPlacements = "event_placements"
        case totalWinnings = "total_winnings"
    }
}

struct V2PlayerTeam: Decodable, Sendable {
    let name: String?
    let joined: String?
}

struct V2PlayerAgentStat: Decodable, Sendable {
    let agent: String
    let usagePercent: String?
    let rating: String?
    let averageCombatScore: String?
    let killDeathRatio: String?
    let averageDamagePerRound: String?

    enum CodingKeys: String, CodingKey {
        case agent, rating
        case usagePercent = "usage_pct"
        case averageCombatScore = "acs"
        case killDeathRatio = "kd"
        case averageDamagePerRound = "adr"
    }
}

struct V2PlayerProfile: Decodable, Sendable {
    let id: String
    let name: String
    let realName: String?
    let avatar: String?
    let country: String?
    let currentTeam: V2PlayerTeam?
    let agentStats: [V2PlayerAgentStat]?
    let eventPlacements: [V2EventPlacement]?
    let totalWinnings: String?

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, country
        case realName = "real_name"
        case currentTeam = "current_team"
        case agentStats = "agent_stats"
        case eventPlacements = "event_placements"
        case totalWinnings = "total_winnings"
    }
}

struct V2ProfileMatchTeam: Decodable, Sendable {
    let name: String
}

struct V2ProfileMatch: Decodable, Sendable {
    let matchID: String
    let url: String?
    let event: String?
    let date: String?
    let time: String?
    let team1: V2ProfileMatchTeam
    let team2: V2ProfileMatchTeam
    let score: String?
    let result: String?

    enum CodingKeys: String, CodingKey {
        case url, event, date, time, score, result, team1, team2
        case matchID = "match_id"
    }

    var identityKey: String { matchID }
    var numericID: Int? { Int(matchID) }
}

extension VLRAPIClient {
    func fetchTeamProfile(id: Int) async throws -> V2TeamProfile? {
        let data = try await fetchV2(
            V2ProfileCollection<V2TeamProfile>.self,
            path: "team",
            queryItems: [
                URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "q", value: "profile")
            ]
        )
        guard let profile = data.segments.first else { return nil }
        guard Int(profile.id) == id else { throw VLRAPIError.invalidResponse }
        return profile
    }

    func fetchTeamMatches(id: Int) async throws -> [V2ProfileMatch] {
        let data = try await fetchV2(
            V2ProfileCollection<V2ProfileMatch>.self,
            path: "team",
            queryItems: [
                URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "q", value: "matches"),
                URLQueryItem(name: "page", value: "1")
            ]
        )
        return data.segments
    }

    func fetchPlayerProfile(id: Int) async throws -> V2PlayerProfile? {
        let data = try await fetchV2(
            V2ProfileCollection<V2PlayerProfile>.self,
            path: "player",
            queryItems: [
                URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "q", value: "profile"),
                URLQueryItem(name: "timespan", value: "90d")
            ]
        )
        guard let profile = data.segments.first else { return nil }
        guard Int(profile.id) == id else { throw VLRAPIError.invalidResponse }
        return profile
    }

    func fetchPlayerMatches(id: Int) async throws -> [V2ProfileMatch] {
        let data = try await fetchV2(
            V2ProfileCollection<V2ProfileMatch>.self,
            path: "player",
            queryItems: [
                URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "q", value: "matches"),
                URLQueryItem(name: "page", value: "1")
            ]
        )
        return data.segments
    }
}

func capturedProfileRequest<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, VLRAPIError> {
    do {
        return .success(try await operation())
    } catch is CancellationError {
        return .failure(.transport(.cancelled))
    } catch let error as VLRAPIError {
        return .failure(error)
    } catch {
        return .failure(.requestFailed(error.localizedDescription))
    }
}

@MainActor
final class TeamProfileViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(
            profile: V2TeamProfile?,
            matches: [V2ProfileMatch],
            profileIssue: String?,
            matchIssue: String?
        )
        case failed(message: String, retryable: Bool)
    }

    @Published private(set) var state: State = .idle

    private let teamID: Int
    private let client: VLRAPIClient

    init(teamID: Int, client: VLRAPIClient = .init()) {
        self.teamID = teamID
        self.client = client
    }

    /// Loads the profile once; later calls (e.g. when the view reappears) keep what is
    /// on screen. `forceRefresh` reloads in place and keeps loaded content if it fails.
    func load(forceRefresh: Bool = false) async {
        let hasContent: Bool
        if case .loaded = state { hasContent = true } else { hasContent = false }
        guard forceRefresh || !hasContent else { return }
        if !hasContent {
            state = .loading
        }
        let client = client
        let teamID = teamID
        async let profileResult = capturedProfileRequest { try await client.fetchTeamProfile(id: teamID) }
        async let matchResult = capturedProfileRequest { try await client.fetchTeamMatches(id: teamID) }
        let (profile, matches) = await (profileResult, matchResult)
        guard !Task.isCancelled else { return }
        if let error = profile.failure ?? matches.failure {
            Analytics.track(
                .loadFailed(
                    surface: "team_profile",
                    category: AnalyticsErrorCategory(error),
                    retryable: error.isRetryable
                )
            )
        }
        let resolved = Self.resolve(profile: profile, matches: matches)
        if hasContent, case .failed = resolved {
            // A failed refresh keeps the profile that is already on screen.
            return
        }
        state = resolved
    }

    private static func resolve(
        profile: Result<V2TeamProfile?, VLRAPIError>,
        matches: Result<[V2ProfileMatch], VLRAPIError>
    ) -> State {
        let value = try? profile.get()
        let matchValues = (try? matches.get()) ?? []
        let profileError = profile.failure
        let matchError = matches.failure
        let resolvedProfile = value ?? nil

        if (profileError != nil || resolvedProfile == nil), matchError != nil {
            return .failed(
                message: profileError?.errorDescription ?? matchError?.errorDescription ?? "Team data is unavailable.",
                retryable: profileError?.isRetryable == true || matchError?.isRetryable == true
            )
        }
        return .loaded(
            profile: resolvedProfile,
            matches: matchValues,
            profileIssue: profileError?.errorDescription ?? (resolvedProfile == nil ? "No profile details were returned." : nil),
            matchIssue: matchError?.errorDescription
        )
    }
}

@MainActor
final class PlayerProfileViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(
            profile: V2PlayerProfile?,
            matches: [V2ProfileMatch],
            profileIssue: String?,
            matchIssue: String?
        )
        case failed(message: String, retryable: Bool)
    }

    @Published private(set) var state: State = .idle

    private let playerID: Int
    private let client: VLRAPIClient

    init(playerID: Int, client: VLRAPIClient = .init()) {
        self.playerID = playerID
        self.client = client
    }

    /// Loads the profile once; later calls (e.g. when the view reappears) keep what is
    /// on screen. `forceRefresh` reloads in place and keeps loaded content if it fails.
    func load(forceRefresh: Bool = false) async {
        let hasContent: Bool
        if case .loaded = state { hasContent = true } else { hasContent = false }
        guard forceRefresh || !hasContent else { return }
        if !hasContent {
            state = .loading
        }
        let client = client
        let playerID = playerID
        async let profileResult = capturedProfileRequest { try await client.fetchPlayerProfile(id: playerID) }
        async let matchResult = capturedProfileRequest { try await client.fetchPlayerMatches(id: playerID) }
        let (profile, matches) = await (profileResult, matchResult)
        guard !Task.isCancelled else { return }
        if let error = profile.failure ?? matches.failure {
            Analytics.track(
                .loadFailed(
                    surface: "player_profile",
                    category: AnalyticsErrorCategory(error),
                    retryable: error.isRetryable
                )
            )
        }
        let resolved = Self.resolve(profile: profile, matches: matches)
        if hasContent, case .failed = resolved {
            // A failed refresh keeps the profile that is already on screen.
            return
        }
        state = resolved
    }

    private static func resolve(
        profile: Result<V2PlayerProfile?, VLRAPIError>,
        matches: Result<[V2ProfileMatch], VLRAPIError>
    ) -> State {
        let value = try? profile.get()
        let matchValues = (try? matches.get()) ?? []
        let profileError = profile.failure
        let matchError = matches.failure
        let resolvedProfile = value ?? nil

        if (profileError != nil || resolvedProfile == nil), matchError != nil {
            return .failed(
                message: profileError?.errorDescription ?? matchError?.errorDescription ?? "Player data is unavailable.",
                retryable: profileError?.isRetryable == true || matchError?.isRetryable == true
            )
        }
        return .loaded(
            profile: resolvedProfile,
            matches: matchValues,
            profileIssue: profileError?.errorDescription ?? (resolvedProfile == nil ? "No profile details were returned." : nil),
            matchIssue: matchError?.errorDescription
        )
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

struct TeamProfileView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel: TeamProfileViewModel
    @StateObject private var sectionsViewModel: TeamSectionsViewModel
    @State private var selectedSection: TeamProfileSection = .overview
    @State private var reloadToken = 0
    @State private var hasTrackedOpen = false

    private let teamID: Int
    private let fallbackName: String
    private let fallbackLogo: String?
    private let analyticsSource: String

    init(
        teamID: Int,
        name: String,
        logo: String? = nil,
        source: String = "direct",
        client: VLRAPIClient = .init()
    ) {
        self.teamID = teamID
        fallbackName = name
        fallbackLogo = logo
        analyticsSource = source
        _viewModel = StateObject(wrappedValue: TeamProfileViewModel(teamID: teamID, client: client))
        _sectionsViewModel = StateObject(wrappedValue: TeamSectionsViewModel(teamID: teamID, client: client))
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            content
        }
        .navigationTitle(fallbackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FavoriteTeamButton(teamID: teamID, name: displayName, logo: displayLogo)
            }
            externalLink(
                path: "/team/\(teamID)",
                label: "View team on VLR.GG",
                type: .team,
                id: String(teamID),
                source: "team_profile"
            )
        }
        .task(id: reloadToken) { await viewModel.load() }
        .onChange(of: displayName, initial: true) { _, name in
            FavoriteTeamsStore.shared.refreshDetails(teamID: teamID, name: name, logo: displayLogo)
        }
        .onAppear {
            guard !hasTrackedOpen else { return }
            hasTrackedOpen = true
            Analytics.track(
                .contentOpened(
                    type: .team,
                    id: String(teamID),
                    source: analyticsSource
                )
            )
        }
    }

    private var loadedProfile: V2TeamProfile? {
        if case .loaded(let profile, _, _, _) = viewModel.state { return profile }
        return nil
    }

    private var displayName: String {
        (loadedProfile?.name).nilIfBlank ?? fallbackName
    }

    /// The logo saved with a favourite. Match lists show logos on a dark card, so this
    /// prefers the dark variant like they do.
    private var displayLogo: String? {
        VLRAPI.preferredLogo(
            fallback: loadedProfile?.logo ?? fallbackLogo,
            light: loadedProfile?.logoLight,
            dark: loadedProfile?.logoDark,
            for: .dark
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading team profile…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message, let retryable):
            ProfileFailureView(title: "Team unavailable", message: message, retryable: retryable) {
                Analytics.track(.retryTapped(surface: "team_profile"))
                reloadToken += 1
            }
        case .loaded(let profile, let matches, let profileIssue, let matchIssue):
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    TeamProfileHeader(
                        name: profile?.name ?? fallbackName,
                        tag: profile?.tag,
                        country: profile?.countryName ?? profile?.country,
                        logo: VLRAPI.preferredLogo(
                            fallback: profile?.logo ?? fallbackLogo,
                            light: profile?.logoLight,
                            dark: profile?.logoDark,
                            for: colorScheme
                        ),
                        description: profile?.description
                    )
                    .padding([.horizontal, .top])

                    Section {
                        VStack(spacing: 16) {
                            switch selectedSection {
                            case .overview:
                                overview(
                                    profile: profile,
                                    matches: matches,
                                    profileIssue: profileIssue,
                                    matchIssue: matchIssue
                                )
                            case .schedule, .maps, .roster, .transfers:
                                TeamSectionContent(
                                    section: selectedSection,
                                    teamName: displayName,
                                    viewModel: sectionsViewModel
                                )
                            }
                        }
                        .id(selectedSection)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    } header: {
                        TeamSectionPicker(selection: $selectedSection)
                    }
                }
            }
            .refreshable {
                if selectedSection == .overview {
                    await viewModel.load(forceRefresh: true)
                } else {
                    await sectionsViewModel.refresh(selectedSection)
                }
            }
        }
    }

    @ViewBuilder
    private func overview(
        profile: V2TeamProfile?,
        matches: [V2ProfileMatch],
        profileIssue: String?,
        matchIssue: String?
    ) -> some View {
        if let profileIssue { ProfileIssueBanner(text: "Profile details unavailable: \(profileIssue)") }
        if let matchIssue { ProfileIssueBanner(text: "Match history unavailable: \(matchIssue)") }

        if let profile {
            if profile.hasSnapshot { TeamSnapshotCard(profile: profile) }
            TeamRosterCard(members: profile.roster ?? [])
            PlacementCard(placements: profile.eventPlacements ?? [])
        }
        if matchIssue == nil {
            ProfileMatchesCard(matches: matches, emptyTitle: "No recent team matches")
        }
    }
}

struct PlayerProfileView: View {
    @StateObject private var viewModel: PlayerProfileViewModel
    @State private var reloadToken = 0
    @State private var hasTrackedOpen = false

    private let playerID: Int
    private let fallbackName: String
    private let analyticsSource: String

    init(
        playerID: Int,
        name: String,
        source: String = "direct",
        client: VLRAPIClient = .init()
    ) {
        self.playerID = playerID
        fallbackName = name
        analyticsSource = source
        _viewModel = StateObject(wrappedValue: PlayerProfileViewModel(playerID: playerID, client: client))
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            content
        }
        .navigationTitle(fallbackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            externalLink(
                path: "/player/\(playerID)",
                label: "View player on VLR.GG",
                type: .player,
                id: String(playerID),
                source: "player_profile"
            )
        }
        .task(id: reloadToken) { await viewModel.load() }
        .onAppear {
            guard !hasTrackedOpen else { return }
            hasTrackedOpen = true
            Analytics.track(
                .contentOpened(
                    type: .player,
                    id: String(playerID),
                    source: analyticsSource
                )
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading player profile…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message, let retryable):
            ProfileFailureView(title: "Player unavailable", message: message, retryable: retryable) {
                Analytics.track(.retryTapped(surface: "player_profile"))
                reloadToken += 1
            }
        case .loaded(let profile, let matches, let profileIssue, let matchIssue):
            ScrollView {
                LazyVStack(spacing: 16) {
                    PlayerProfileHeader(profile: profile, fallbackName: fallbackName)

                    if let profileIssue { ProfileIssueBanner(text: "Profile details unavailable: \(profileIssue)") }
                    if let matchIssue { ProfileIssueBanner(text: "Match history unavailable: \(matchIssue)") }

                    if let profile {
                        PlayerAgentCard(stats: profile.agentStats ?? [])
                        PlacementCard(placements: profile.eventPlacements ?? [])
                    }
                    if matchIssue == nil {
                        ProfileMatchesCard(matches: matches, emptyTitle: "No recent player matches")
                    }
                }
                .padding()
            }
            .refreshable { await viewModel.load(forceRefresh: true) }
        }
    }
}

private struct TeamProfileHeader: View {
    let name: String
    let tag: String?
    let country: String?
    let logo: String?
    let description: String?

    var body: some View {
        VStack(spacing: 12) {
            ProfileImage(url: logo, symbol: "person.2.fill", size: 92)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.title.bold())
                if let tag = tag.nilIfBlank { Text(tag).font(.headline).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            if let country = country.nilIfBlank { Text(country).foregroundStyle(.secondary) }
            if let description = description.nilIfBlank {
                Text(description).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .profileSurface(cornerRadius: 24)
        .accessibilityElement(children: .combine)
    }
}

private struct PlayerProfileHeader: View {
    let profile: V2PlayerProfile?
    let fallbackName: String

    var body: some View {
        VStack(spacing: 12) {
            ProfileImage(url: profile?.avatar, symbol: "person.crop.circle.fill", size: 96)
            Text(profile?.name ?? fallbackName).font(.title.bold()).italic()
            if let realName = profile?.realName.nilIfBlank {
                Text(realName).font(.headline).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let country = profile?.country.nilIfBlank {
                    Label(country.uppercased(), systemImage: "globe")
                }
                if let team = profile?.currentTeam?.name.nilIfBlank {
                    Label(team, systemImage: "person.2.fill")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if let joined = profile?.currentTeam?.joined.nilIfBlank {
                Text(joined).font(.caption).foregroundStyle(.secondary)
            }
            if let winnings = profile?.totalWinnings.nilIfBlank {
                Label("Career winnings \(winnings)", systemImage: "trophy.fill")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .profileSurface(cornerRadius: 24)
        .accessibilityElement(children: .combine)
    }
}

private struct TeamSnapshotCard: View {
    let profile: V2TeamProfile

    var body: some View {
        ProfileCard(title: "At a glance", symbol: "chart.line.uptrend.xyaxis") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { metrics }
                VStack(spacing: 10) { metrics }
            }
        }
    }

    @ViewBuilder private var metrics: some View {
        if let rank = profile.rating?.rank.nilIfBlank { ProfileMetric(label: "Rank", value: rank) }
        if let rating = profile.rating?.rating.nilIfBlank { ProfileMetric(label: "Rating", value: rating) }
        if let peak = profile.rating?.peakRating.nilIfBlank { ProfileMetric(label: "Peak", value: peak) }
        if let streak = profile.rating?.streak.nilIfBlank { ProfileMetric(label: "Form", value: streak) }
        if let winnings = profile.totalWinnings.nilIfBlank { ProfileMetric(label: "Winnings", value: winnings) }
    }
}

private struct TeamRosterCard: View {
    let members: [V2TeamRosterMember]

    var body: some View {
        ProfileCard(title: "Current roster", symbol: "person.3.fill") {
            if members.isEmpty {
                ProfileEmptyState(title: "Roster unavailable", symbol: "person.3")
            } else {
                ForEach(members, id: \.identityKey) { member in
                    TeamRosterMemberLink(member: member)
                }
            }
        }
    }
}

struct RosterRow: View {
    let member: V2TeamRosterMember
    let showsDisclosure: Bool
    /// An extra caption line, e.g. when a former player joined and left.
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            ProfileImage(url: member.avatar, symbol: "person.crop.circle.fill", size: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(member.alias).font(.body.weight(.semibold))
                    if member.isCaptain == true {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Captain")
                    }
                }
                Text([member.realName.nilIfBlank, member.role.nilIfBlank, member.isStaff == true ? "Staff" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = detail.nilIfBlank {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let country = member.country.nilIfBlank { Text(country.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary) }
            if showsDisclosure { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct PlayerAgentCard: View {
    let stats: [V2PlayerAgentStat]

    var body: some View {
        ProfileCard(title: "Recent agent performance", symbol: "scope") {
            if stats.isEmpty {
                ProfileEmptyState(title: "Performance unavailable", symbol: "chart.bar")
            } else {
                ForEach(stats.prefix(5), id: \.agent) { stat in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(stat.agent).font(.headline)
                            Spacer()
                            if let usage = stat.usagePercent.nilIfBlank { Text(usage).foregroundStyle(.secondary) }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { metrics(for: stat) }
                            VStack(spacing: 8) { metrics(for: stat) }
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func metrics(for stat: V2PlayerAgentStat) -> some View {
        if let rating = stat.rating.nilIfBlank { ProfileMetric(label: "Rating", value: rating) }
        if let acs = stat.averageCombatScore.nilIfBlank { ProfileMetric(label: "ACS", value: acs) }
        if let kd = stat.killDeathRatio.nilIfBlank { ProfileMetric(label: "K/D", value: kd) }
        if let adr = stat.averageDamagePerRound.nilIfBlank { ProfileMetric(label: "ADR", value: adr) }
    }
}

private struct PlacementCard: View {
    let placements: [V2EventPlacement]

    var body: some View {
        ProfileCard(title: "Recent event results", symbol: "trophy.fill") {
            if placements.isEmpty {
                ProfileEmptyState(title: "Event results unavailable", symbol: "trophy")
            } else {
                ForEach(placements.prefix(4), id: \.identityKey) { placement in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(placement.event).font(.subheadline.weight(.semibold))
                            Text([placement.series.nilIfBlank, placement.team.nilIfBlank, placement.date.nilIfBlank]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(placement.placement.nilIfBlank ?? "–").font(.headline)
                            if let prize = placement.prize.nilIfBlank {
                                Text(prize).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct ProfileMatchesCard: View {
    let matches: [V2ProfileMatch]
    let emptyTitle: String

    var body: some View {
        ProfileCard(title: "Recent matches", symbol: "clock.arrow.circlepath") {
            if matches.isEmpty {
                ProfileEmptyState(title: emptyTitle, symbol: "calendar.badge.minus")
            } else {
                ForEach(matches.prefix(6), id: \.identityKey) { match in
                    if let matchID = match.numericID {
                        NavigationLink {
                            MatchDetailView(matchID: matchID, fallbackURL: match.url)
                        } label: {
                            ProfileMatchRow(match: match, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens match details")
                    } else {
                        ProfileMatchRow(match: match, showsDisclosure: false)
                    }
                }
            }
        }
    }
}

private struct ProfileMatchRow: View {
    let match: V2ProfileMatch
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(match.team1.name) vs \(match.team2.name)").font(.subheadline.weight(.semibold))
                Text([match.event.nilIfBlank, match.date.nilIfBlank, match.time.nilIfBlank]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(match.score.nilIfBlank ?? "–").font(.headline.monospacedDigit())
                if let result = match.result.nilIfBlank {
                    Text(result.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(result.lowercased() == "win" ? Color.green : Color.primary.opacity(0.6))
                }
            }
            if showsDisclosure { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct ProfileCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .profileSurface(cornerRadius: 20)
    }
}

struct ProfileMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.horizontal, 8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct ProfileImage: View {
    let url: String?
    let symbol: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: VLRAPI.imageURL(from: url)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.secondary).padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ProfileIssueBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel(text)
    }
}

struct ProfileEmptyState: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
    }
}

struct ProfileFailureView: View {
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
            if retryable { Button("Try Again", action: retry).buttonStyle(.borderedProminent) }
        }
    }
}

@ToolbarContentBuilder
@MainActor
private func externalLink(
    path: String,
    label: String,
    type: AnalyticsContentType,
    id: String,
    source: String
) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        if let url = VLRAPI.pageURL(from: path) {
            Link(destination: url) { Label(label, systemImage: "arrow.up.right.square") }
                .simultaneousGesture(TapGesture().onEnded {
                    Analytics.track(
                        .externalLinkOpened(
                            destination: "vlr",
                            type: type,
                            id: id,
                            source: source
                        )
                    )
                })
                .accessibilityHint("Opens VLR.GG")
        }
    }
}

extension View {
    func profileSurface(cornerRadius: CGFloat) -> some View {
        background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.1), lineWidth: 1)
            }
    }
}

private extension V2TeamProfile {
    var hasSnapshot: Bool {
        rating?.rank.nilIfBlank != nil
            || rating?.rating.nilIfBlank != nil
            || rating?.peakRating.nilIfBlank != nil
            || rating?.streak.nilIfBlank != nil
            || totalWinnings.nilIfBlank != nil
    }
}
