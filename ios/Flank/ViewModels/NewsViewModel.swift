//
//  NewsViewModel.swift
//  Flank
//

import Foundation

struct V3PageMeta: Codable, Hashable, Sendable {
    let source: String?
    let page: Int
    let totalPages: Int?
    let hasPrevious: Bool?
    let hasNext: Bool?

    enum CodingKeys: String, CodingKey {
        case source, page
        case totalPages = "total_pages"
        case hasPrevious = "has_previous"
        case hasNext = "has_next"
    }
}

struct V3NewsSummary: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let slug: String
    let title: String
    let description: String?
    let publishedDate: String?
    let authorHandle: String?
    let regionCode: String?
    let url: String

    enum CodingKeys: String, CodingKey {
        case id, slug, title, description, url
        case publishedDate = "published_date"
        case authorHandle = "author_handle"
        case regionCode = "region_code"
    }

    var formattedPublishedDate: String? {
        guard let publishedDate else { return nil }
        let parts = publishedDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
              ) else {
            return publishedDate
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct V3NewsAuthor: Codable, Hashable, Sendable {
    let name: String
    let handle: String?
    let url: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case name, handle, url
        case avatarURL = "avatar_url"
    }
}

struct V3ContentLink: Codable, Hashable, Identifiable, Sendable {
    let text: String?
    let url: String

    var id: String { "\(url)|\(text ?? "")" }
}

struct V3ContentMedia: Codable, Hashable, Identifiable, Sendable {
    let type: String
    let url: String
    let alt: String?

    var id: String { "\(type)|\(url)" }
}

struct V3ArticleContent: Codable, Hashable, Sendable {
    let html: String
    let text: String
    @DefaultEmpty var links: [V3ContentLink]
    @DefaultEmpty var media: [V3ContentMedia]

    var hasReadableBody: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct V3NewsArticle: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let slug: String
    let url: String
    let title: String
    let description: String?
    let publishedAt: Date?
    let relativeTime: String?
    let author: V3NewsAuthor
    let event: V3EventRef?
    let content: V3ArticleContent
    let commentsURL: String

    enum CodingKeys: String, CodingKey {
        case id, slug, url, title, description, author, event, content
        case publishedAt = "published_at"
        case relativeTime = "relative_time"
        case commentsURL = "comments_url"
    }
}

@MainActor
final class ShowNews: ObservableObject {
    @Published private(set) var articles: [V3NewsSummary] = []
    @Published private(set) var state: ListLoadState = .idle

    private let client: VLRAPIClient
    private let cache: ListCache
    private let cacheKey = "v3.news.page.1"

    init(client: VLRAPIClient = .init(), cache: ListCache = .shared) {
        self.client = client
        self.cache = cache
        loadCache()
    }

    func fetch() async {
        if articles.isEmpty {
            state = .loading
        }

        do {
            let response = try await client.fetchNews(page: 1)
            try Task.checkCancellation()
            articles = response.articles
            state = response.articles.isEmpty ? .empty : .loaded
            saveCache()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .afterFailure(error, hasContent: !articles.isEmpty, surface: "news")
        }
    }

    private func loadCache() {
        guard let cached = cache.load([V3NewsSummary].self, forKey: cacheKey) else { return }
        articles = cached
        state = cached.isEmpty ? .empty : .loaded
    }

    private func saveCache() {
        cache.save(articles, forKey: cacheKey)
    }
}

enum NewsArticleLoadState {
    case loading
    case loaded(V3NewsArticle)
    case failed(message: String, retryable: Bool)
}
