//
//  NewsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI

struct NewsView: View {
    @StateObject var news = ShowNews()
    @State private var isLoading = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    Spacer()
                }
                .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(news.news, id: \.self) { news in
                            NewsTab(news: news)
                        }
                    }
                }
                .padding(.horizontal)
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.4))
                }
            }
            .navigationBarTitle("News")
        }
        .refreshable {
            await fetchNews()
        }
        .onAppear {
            Task {
                await fetchNews()
            }
        }
    }
    
    func fetchNews() async {
        isLoading = true
        await news.fetch()
        isLoading = false
    }
}

#Preview {
    NewsView()
}
