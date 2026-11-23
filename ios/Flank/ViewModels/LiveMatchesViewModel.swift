//
//  LiveMatchesViewModel.swift
//  Flank
//

import Foundation

@MainActor
final class ShowLive: V3MatchListStore {
    init(client: VLRAPIClient = .init(), defaults: UserDefaults = .standard) {
        super.init(query: .liveScore, client: client, defaults: defaults)
    }
}
