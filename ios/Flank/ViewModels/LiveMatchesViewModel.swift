//
//  LiveMatchesViewModel.swift
//  Flank
//

import Foundation

@MainActor
final class ShowLive: V3MatchListStore {
    init(client: VLRAPIClient = .init(), cache: ListCache = .shared) {
        super.init(query: .liveScore, client: client, cache: cache)
    }
}
