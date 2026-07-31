//
//  NewsTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import SafariServices
import BetterSafariView

struct NewsTab: View {
    let news: News
    
    @State private var presentingSafariView = false
    
    init(news: News) {
        self.news = news
    }
    
    var body: some View {
        VStack {
            Button(action: {
                self.presentingSafariView = true
            }) {
                VStack {
                    HStack {
                        Text(news.title)
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    HStack {
                        Text(news.description)
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 1)
                    HStack {
                        Text(news.author)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(news.date)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $presentingSafariView) {
                SafariView(
                    url: VLRAPI.pageURL(from: news.url_path) ?? VLRAPI.websiteURL,
                    configuration: SafariView.Configuration(
                        entersReaderIfAvailable: false,
                        barCollapsingEnabled: true
                    )
                )
                .preferredBarAccentColor(.clear)
                .preferredControlAccentColor(.accentColor)
                .dismissButtonStyle(.done)
            }
        }
    }
}

struct NewsTab_Previews: PreviewProvider {
    static var previews: some View {
        NewsTab(news: News(title: "Sample Title", description: "Sample Description", date: "21 April, 2024", author: "thothgow", url_path: "https://google.com"))
    }
}
