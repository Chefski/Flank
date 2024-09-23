//
//  News.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation

struct NewsAPIResponse: Codable {
    let data: NewsDataModel
}

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

class ShowNews: ObservableObject {
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
        guard let url = URL(string: "https://vlrggapi.vercel.app/news") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(NewsAPIResponse.self, from: data)
            DispatchQueue.main.async {
                self.news = response.data.segments
                self.cacheNews()
            }
        } catch {
            print("Error fetching news: \(error)")
        }
    }
}