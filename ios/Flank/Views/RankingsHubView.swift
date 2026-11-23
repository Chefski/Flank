//
//  RankingsHubView.swift
//  Flank
//
//  The Rankings tab: team rankings and player stats under one navigation stack,
//  switched with a Teams / Players control at the top.
//

import SwiftUI

enum RankingsBoard: String, CaseIterable, Identifiable {
    case teams
    case players

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .teams: "Teams"
        case .players: "Players"
        }
    }
}

struct RankingsHubView: View {
    /// Bumped when the Rankings tab is reselected; scrolls the visible board to the top.
    let scrollToTopTrigger: Int

    @State private var board: RankingsBoard = .teams
    /// The Players board is built the first time it's picked, then kept alive with the
    /// Teams board, so switching back and forth keeps filters and scroll positions and
    /// doesn't reload (each load scrapes VLR.GG).
    @State private var hasShownPlayers = false
    @State private var teamsScrollTrigger = 0
    @State private var playersScrollTrigger = 0

    init(scrollToTopTrigger: Int = 0) {
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Rankings", selection: $board) {
                    ForEach(RankingsBoard.allCases) { board in
                        Text(board.title).tag(board)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                ZStack {
                    boardView(.teams) {
                        RankingsView(scrollToTopTrigger: teamsScrollTrigger)
                    }
                    if hasShownPlayers {
                        boardView(.players) {
                            StatsView(scrollToTopTrigger: playersScrollTrigger)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle("Rankings")
        }
        .onChange(of: board) { _, newBoard in
            if newBoard == .players {
                hasShownPlayers = true
            }
            Analytics.track(.filterChanged(surface: "rankings", filter: "board", value: newBoard.rawValue))
        }
        .onChange(of: scrollToTopTrigger) {
            switch board {
            case .teams: teamsScrollTrigger += 1
            case .players: playersScrollTrigger += 1
            }
        }
    }

    /// Keeps a board in the hierarchy while hidden, out of sight and out of VoiceOver.
    private func boardView<Content: View>(
        _ kind: RankingsBoard,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isVisible = board == kind
        return content()
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

#Preview {
    RankingsHubView()
}
