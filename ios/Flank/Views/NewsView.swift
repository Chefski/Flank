//
//  NewsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import Foundation
import SwiftUI

struct NewsView: View {
    @StateObject private var news = ShowNews()

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    LinearGradient(
                        colors: [.primary.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    Spacer()
                }
                .ignoresSafeArea()

                content
            }
            .navigationTitle("News")
        }
        .task {
            await news.fetch()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch news.state {
        case .idle, .loading:
            ProgressView("Loading news…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message, let retryable):
            ContentUnavailableView {
                Label("News Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                if retryable {
                    Button("Try Again") {
                        Analytics.track(.retryTapped(surface: "news"))
                        Task { await news.fetch() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .empty:
            ContentUnavailableView(
                "No News Yet",
                systemImage: "newspaper",
                description: Text("VLR.GG did not return any articles.")
            )

        default:
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if case .showingSaved(_, let isOffline) = news.state {
                        cachedNewsNotice(isOffline: isOffline)
                    }

                    ForEach(news.articles) { article in
                        NewsTab(news: article)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .refreshable {
                await news.fetch()
            }
        }
    }

    private func cachedNewsNotice(isOffline: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isOffline ? "wifi.slash" : "exclamationmark.icloud")
            (isOffline ? Text("Offline — showing saved news") : Text("Couldn’t refresh — showing saved news"))
                .font(.subheadline)
            Spacer()
            Button("Retry") {
                Analytics.track(.retryTapped(surface: "news"))
                Task { await news.fetch() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

enum NativeArticleSectionKind {
    case paragraph
    case heading
}

struct NativeArticleSection: Identifiable {
    let id: Int
    let kind: NativeArticleSectionKind
    let text: AttributedString
}

struct NativeArticleBody: View {
    let sections: [NativeArticleSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                switch section.kind {
                case .paragraph:
                    Text(section.text)
                        .font(.body)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .heading:
                    Text(section.text)
                        .font(.title2.bold())
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func makeSections(from content: V3ArticleContent) -> [NativeArticleSection] {
        let expression = try? NSRegularExpression(
            pattern: #"<(p|h[1-6]|blockquote)\b[^>]*>.*?</\1>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let html = content.html as NSString
        let matches = expression?.matches(
            in: content.html,
            range: NSRange(location: 0, length: html.length)
        ) ?? []

        let descriptors = matches.enumerated().compactMap { index, match -> SectionDescriptor? in
            guard match.numberOfRanges > 1 else { return nil }
            let tag = html.substring(with: match.range(at: 1)).lowercased()
            let kind: NativeArticleSectionKind = tag.hasPrefix("h") ? .heading : .paragraph
            let block = html.substring(with: match.range)
            return SectionDescriptor(id: index, kind: kind, html: block)
        }

        if let imported = importMarkedDocument(descriptors) {
            let importedText = imported.string as NSString
            let sections = descriptors.compactMap { descriptor -> NativeArticleSection? in
                let start = importedText.range(of: descriptor.startMarker)
                let end = importedText.range(of: descriptor.endMarker)
                guard start.location != NSNotFound,
                      end.location != NSNotFound else {
                    return nil
                }

                let contentStart = NSMaxRange(start)
                guard end.location >= contentStart else { return nil }
                let range = NSRange(location: contentStart, length: end.location - contentStart)
                let block = imported.attributedSubstring(from: range)
                guard let text = format(block, as: descriptor.kind) else { return nil }
                return NativeArticleSection(id: descriptor.id, kind: descriptor.kind, text: text)
            }
            if !sections.isEmpty {
                return sections
            }
        }

        let fallback = content.text
            .split(whereSeparator: \Character.isNewline)
            .joined(separator: " ")
        guard !fallback.isEmpty else { return [] }
        return [
            NativeArticleSection(
                id: 0,
                kind: .paragraph,
                text: makeLinkedFallback(fallback, links: content.links)
            )
        ]
    }

    private static func importMarkedDocument(
        _ descriptors: [SectionDescriptor]
    ) -> NSAttributedString? {
        guard !descriptors.isEmpty else { return nil }
        let style = """
        <style>
        .article-ref-card, img, iframe, video, source { display: none !important; }
        body { font-family: -apple-system; font-size: 17px; line-height: 1.55; }
        </style>
        """
        let markedBody = descriptors.map { descriptor in
            "<div>\(descriptor.startMarker)</div>\(descriptor.html)<div>\(descriptor.endMarker)</div>"
        }.joined()
        let document = "<html><head>\(style)</head><body>\(markedBody)</body></html>"
        return try? NSAttributedString(
            data: Data(document.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    private static func format(
        _ block: NSAttributedString,
        as kind: NativeArticleSectionKind
    ) -> AttributedString? {
        guard let trimmed = normalizeWhitespace(in: block) else { return nil }
        var attributed = AttributedString(trimmed)
        switch kind {
        case .paragraph:
            attributed.font = .body
        case .heading:
            attributed.font = .title2.bold()
        }
        attributed.foregroundColor = .primary
        let linkRanges = attributed.runs.compactMap { run in
            run.link == nil ? nil : run.range
        }
        for range in linkRanges {
            attributed[range].foregroundColor = .accentColor
            attributed[range].underlineStyle = .single
        }
        return attributed
    }

    private struct SectionDescriptor {
        let id: Int
        let kind: NativeArticleSectionKind
        let html: String

        var startMarker: String { "FLANK_SECTION_\(id)_START_7A3F" }
        var endMarker: String { "FLANK_SECTION_\(id)_END_7A3F" }
    }

    private static func normalizeWhitespace(
        in attributed: NSAttributedString
    ) -> NSAttributedString? {
        let normalized = NSMutableAttributedString(attributedString: attributed)
        let whitespace = try? NSRegularExpression(pattern: #"\s+"#)
        let whitespaceMatches = whitespace?.matches(
            in: normalized.string,
            range: NSRange(location: 0, length: normalized.length)
        ) ?? []
        for match in whitespaceMatches.reversed() {
            normalized.replaceCharacters(in: match.range, with: " ")
        }

        let beforePunctuation = try? NSRegularExpression(pattern: #"\s+(?=[,.;:!?])"#)
        let punctuationMatches = beforePunctuation?.matches(
            in: normalized.string,
            range: NSRange(location: 0, length: normalized.length)
        ) ?? []
        for match in punctuationMatches.reversed() {
            normalized.replaceCharacters(in: match.range, with: "")
        }

        let text = normalized.string
        let visibleCharacters = CharacterSet.whitespacesAndNewlines.inverted
        guard let start = text.rangeOfCharacter(from: visibleCharacters),
              let end = text.rangeOfCharacter(from: visibleCharacters, options: .backwards) else {
            return nil
        }
        return normalized.attributedSubstring(from: NSRange(start.lowerBound..<end.upperBound, in: text))
    }

    private static func makeLinkedFallback(
        _ fallback: String,
        links: [V3ContentLink]
    ) -> AttributedString {
        var attributed = AttributedString(fallback)
        for link in links {
            guard let label = link.text?.nilIfBlank,
                  let destination = VLRAPI.pageURL(from: link.url),
                  let range = attributed.range(of: label) else {
                continue
            }
            attributed[range].link = destination
            attributed[range].foregroundColor = .accentColor
            attributed[range].underlineStyle = .single
        }
        return attributed
    }
}

struct NewsArticleLoadingView: View {
    let summary: V3NewsSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(summary.title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                if let description = summary.description, !description.isEmpty {
                    Text(description)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                ProgressView("Loading article…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

#Preview {
    NewsView()
}
