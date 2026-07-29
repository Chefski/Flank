//
//  News.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct NewsDataModel: Hashable, Codable {
    let status: Int
    let segments: [News]
}

struct News: Hashable, Codable {
    var title: String
    var description: String
    var date: String
    var author: String
    var url_path: String
}

@MainActor
final class ShowNews: ObservableObject {
    @Published var news: [News] = []
    private let cacheKey = "cachedNews"
    
    init() {
        loadCachedNews()
    }
    
    private func loadCachedNews() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedNews = try? JSONDecoder().decode([News].self, from: data) {
            self.news = cachedNews
        }
    }
    
    private func cacheNews() {
        if let encodedData = try? JSONEncoder().encode(news) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey)
        }
    }
    
    func fetch() async {
        do {
            let response = try await VLRAPI.fetch(NewsDataModel.self, path: "news")
            news = response.segments
            cacheNews()
        } catch {
            print("Error fetching news: \(error)")
        }
    }
}
