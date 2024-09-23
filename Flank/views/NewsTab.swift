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
                            .foregroundColor(.white)
                        Spacer()
                    }
                    HStack {
                        Text(news.description)
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.80))
                        Spacer()
                    }
                    .padding(.bottom, 1)
                    HStack {
                        Text(news.author)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(news.date)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(red: 0.18, green: 0.18, blue: 0.18))
                .cornerRadius(10)
            }
            .sheet(isPresented: $presentingSafariView) {
                SafariView(
                    url: URL(string: news.url_path)!,
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
