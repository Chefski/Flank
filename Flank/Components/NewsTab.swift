//
//  NewsTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation
import SwiftUI

struct NewsTab: View {
    let news: V3NewsSummary

    var body: some View {
        NavigationLink {
            NewsArticleView(summary: news)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(news.title)
                    .multilineTextAlignment(.leading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let description = news.description, !description.isEmpty {
                    Text(description)
                        .multilineTextAlignment(.leading)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if news.authorHandle != nil || news.formattedPublishedDate != nil {
                    HStack(spacing: 6) {
                        if let author = news.authorHandle, !author.isEmpty {
                            Text(author)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                        if let date = news.formattedPublishedDate {
                            Text(date)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the article in Flank")
    }
}

struct NewsArticleView: View {
    let summary: V3NewsSummary

    private let client: VLRAPIClient
    @State private var loadState: NewsArticleLoadState = .loading
    @State private var articleSections: [NativeArticleSection] = []
    @State private var retryToken = 0

    init(summary: V3NewsSummary, client: VLRAPIClient = .init()) {
        self.summary = summary
        self.client = client
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                NewsArticleLoadingView(summary: summary)
            case .loaded(let article):
                NewsArticleContentView(
                    article: article,
                    articleSections: articleSections,
                    fallbackURL: summary.url
                )
            case .failed(let message, let retryable):
                articleError(message: message, retryable: retryable)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(summary.id)-\(retryToken)") {
            await loadArticle()
        }
    }

    @MainActor
    private func loadArticle() async {
        loadState = .loading
        articleSections = []
        do {
            let article = try await client.fetchNewsArticle(id: summary.id)
            try Task.checkCancellation()
            let sections = NativeArticleBody.makeSections(from: article.content)
            try Task.checkCancellation()
            articleSections = sections
            loadState = .loaded(article)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                retryable: (error as? VLRAPIError)?.isRetryable ?? true
            )
        }
    }

    private func articleError(message: String, retryable: Bool) -> some View {
        ContentUnavailableView {
            Label("Article Unavailable", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(message)
        } actions: {
            if retryable {
                Button("Try Again") {
                    retryToken += 1
                }
                .buttonStyle(.borderedProminent)
            }

            if let url = VLRAPI.pageURL(from: summary.url) {
                Link("Open on VLR.GG", destination: url)
            }
        }
    }
}

private struct NewsArticleContentView: View {
    let article: V3NewsArticle
    let articleSections: [NativeArticleSection]
    let fallbackURL: String

    private var externalURL: URL? {
        VLRAPI.pageURL(from: article.url) ?? VLRAPI.pageURL(from: fallbackURL)
    }

    private var imageMedia: [V3ContentMedia] {
        article.content.media.filter {
            $0.type == "image" && VLRAPI.imageURL(from: $0.url) != nil
        }
    }

    private var embedMedia: [V3ContentMedia] {
        article.content.media.filter {
            $0.type == "embed" && VLRAPI.pageURL(from: $0.url) != nil
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let hero = imageMedia.first {
                    NativeArticleImage(media: hero, isHero: true)
                }

                articleHeader

                if article.content.hasReadableBody, !articleSections.isEmpty {
                    NativeArticleBody(sections: articleSections)
                } else {
                    ContentUnavailableView(
                        "Article Text Unavailable",
                        systemImage: "doc.text",
                        description: Text("This story does not currently include readable article content.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                ForEach(Array(imageMedia.dropFirst())) { media in
                    NativeArticleImage(media: media, isHero: false)
                }

                if !embedMedia.isEmpty {
                    ArticleEmbedsView(media: embedMedia)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background {
            LinearGradient(
                colors: [.primary.opacity(0.06), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Article")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let externalURL {
                    ShareLink(item: externalURL, subject: Text(article.title)) {
                        Label("Share Article", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityHint("Opens the share sheet")

                    Link(destination: externalURL) {
                        Label("Open on VLR.GG", systemImage: "safari")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityHint("Opens the original article in your browser")
                }
            }
        }
    }

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(article.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            if let description = article.description, !description.isEmpty {
                Text(description)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("VLR.GG")
                    .fontWeight(.semibold)

                if article.author.name != "Unknown", !article.author.name.isEmpty {
                    Text("By \(article.author.name)")
                } else if let handle = article.author.handle, !handle.isEmpty {
                    Text("By \(handle)")
                }

                if let publishedAt = article.publishedAt {
                    Text(publishedAt.formatted(date: .long, time: .shortened))
                } else if let relativeTime = article.relativeTime, !relativeTime.isEmpty {
                    Text(relativeTime)
                }

                if let event = article.event, !event.name.isEmpty {
                    if let eventURL = VLRAPI.pageURL(from: event.url) {
                        Link(event.name, destination: eventURL)
                    } else {
                        Text(event.name)
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct NativeArticleImage: View {
    let media: V3ContentMedia
    let isHero: Bool

    var body: some View {
        AsyncImage(url: VLRAPI.imageURL(from: media.url)) { phase in
            switch phase {
            case .empty:
                ZStack {
                    Color.secondary.opacity(0.08)
                    ProgressView()
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                ZStack {
                    Color.secondary.opacity(0.08)
                    Label("Image unavailable", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(isHero ? 16.0 / 9.0 : nil, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityLabel(media.alt?.nilIfBlank ?? "Article image")
    }
}

private struct ArticleEmbedsView: View {
    let media: [V3ContentMedia]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(media) { item in
                if let destination = VLRAPI.pageURL(from: item.url) {
                    Link(destination: destination) {
                        Label(item.alt?.nilIfBlank ?? "Open embedded media", systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial, in: .rect(cornerRadius: 10))
                    }
                }
            }
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
