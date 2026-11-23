//
//  MatchResultsViewModel.swift
//  Flank
//

import Foundation

@MainActor
final class ShowResults: V3MatchListStore {
    init(client: VLRAPIClient = .init(), cache: ListCache = .shared) {
        super.init(query: .results, client: client, cache: cache)
    }
}
