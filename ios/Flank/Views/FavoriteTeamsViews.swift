//
//  FavoriteTeamsViews.swift
//  Flank
//

import SwiftUI

/// Star toggle for a team's favourite state.
struct FavoriteTeamButton: View {
    let teamID: Int
    let name: String
    let logo: String?

    private var store: FavoriteTeamsStore { .shared }

    var body: some View {
        let isFavorite = store.isFavorite(teamID)
        Button {
            store.toggle(teamID: teamID, name: name, logo: logo)
            Analytics.track(.favoriteTeamChanged(id: String(teamID), isFavorite: !isFavorite))
        } label: {
            Label(
                isFavorite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: isFavorite ? "star.fill" : "star"
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .tint(isFavorite ? .yellow : nil)
        .sensoryFeedback(.selection, trigger: isFavorite)
        .accessibilityLabel(isFavorite ? "Remove \(name) from favourites" : "Add \(name) to favourites")
    }
}

/// Settings section listing favourite teams, with a note on where they're stored.
struct FavoriteTeamsSection: View {
    private var store: FavoriteTeamsStore { .shared }

    var body: some View {
        Section {
            if store.teams.isEmpty {
                Label("Tap the star on a team's page to follow it.", systemImage: "star")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.teams) { team in
                    NavigationLink {
                        TeamProfileView(teamID: team.id, name: team.name, logo: team.logo, source: "settings_favorites")
                    } label: {
                        FavoriteTeamRow(team: team)
                    }
                }
                .onDelete { offsets in
                    for team in offsets.map({ store.teams[$0] }) {
                        store.setFavorite(false, teamID: team.id, name: team.name, logo: team.logo)
                        Analytics.track(.favoriteTeamChanged(id: String(team.id), isFavorite: false))
                    }
                }
            }
        } header: {
            Text("Favourite Teams")
        } footer: {
            Text(
                store.isSyncingWithiCloud
                    ? "Synced across your devices with iCloud. No account needed."
                    : "Saved on this device. Sign in to iCloud to sync favourites across your devices."
            )
        }
    }
}

private struct FavoriteTeamRow: View {
    let team: FavoriteTeam

    var body: some View {
        HStack(spacing: 12) {
            // Saved logos are the dark-background variant, so they sit on a dark tile.
            AsyncImage(url: VLRAPI.imageURL(from: team.logo)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "person.2.fill").foregroundStyle(.white.opacity(0.6))
            }
            .padding(5)
            .frame(width: 32, height: 32)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)

            Text(team.name)
        }
    }
}
