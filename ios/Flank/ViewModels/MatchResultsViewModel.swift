//
//  MatchResultsViewModel.swift
//  Flank
//

import Foundation

@MainActor
final class ShowResults: V3MatchListStore {
    init(client: VLRAPIClient = .init(), defaults: UserDefaults = .standard) {
        super.init(query: .results, client: client, defaults: defaults)
    }
}
